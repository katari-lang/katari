-- | Pure orchestration entry point for the Katari compiler.
--
-- Embedders (@katari-project@, @katari-lsp@, the playground, test
-- harnesses) call 'compile' with an in-memory map of source texts and
-- receive an 'IRModule' + @[SchemaEntry]@ + a unified 'Diagnostic' stream.
-- This module performs **no** I\/O: all file system / @katari.toml@
-- handling lives in @katari-project@.
--
-- Pipeline:
--
-- @
-- parseSources
--   → detectImportCycles  -- diagnostics only; pipeline continues
--   → detectMissingImports
--   → identify
--   → generateConstraints
--   → solve
--   → zonk
--   → lower            -- → IRModule (pure)
--   → buildSchemas     -- → [SchemaEntry] (independent of lower; reads ZonkResult)
-- @
--
-- 'compile' never aborts on errors: each phase produces diagnostics that
-- are merged into 'CompileResult.diagnostics'. If any error-severity
-- diagnostic is present, downstream artefacts ('irModule',
-- 'schemaEntries') are returned as 'Nothing' to make the failure mode
-- explicit at the type level.
module Katari.Compile
  ( -- * Inputs / outputs
    ModuleName,
    SourceEntry (..),
    CompileInput (..),
    CompileResult (..),

    -- * Entry
    compile,

    -- * Helpers (exposed for testing)
    parseSources,
    detectImportCycles,
    detectMissingImports,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.AST
  ( Declaration (..),
    ImportDeclaration (..),
    ImportKind (..),
    Module (..),
    Phase (Parsed),
  )
import Katari.Diagnostic (Diagnostic, diagnosticError, hasErrors)
import Katari.IR (IRModule)
import Katari.Lexer as Lexer
import Katari.Lowering (lowerProgram)
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Schema (SchemaEntry, buildSchemas)
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..))
import Katari.Typechecker.ConstraintGenerator (generateConstraints)
import Katari.Typechecker.ConstraintGenerator qualified as CG
import Katari.Typechecker.Exhaustive (checkExhaustive)
import Katari.Typechecker.Exhaustive qualified as Exhaustive
import Katari.Typechecker.Identifier (IdentifierResult, identify)
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.Solver (SolverResult (..), solve)
import Katari.Typechecker.Solver qualified as Solver
import Katari.Typechecker.Zonker (ZonkResult (..), zonk)
import Katari.Typechecker.Zonker qualified as Zonker

-- ===========================================================================
-- Input / output
-- ===========================================================================

-- | Dot-separated module path ("foo.bar.baz"). The compiler treats this
-- as an opaque key; the file-system mapping is the embedder's
-- responsibility.
type ModuleName = Text

-- | 1 ソースファイル分のエントリ。
-- コンパイラは 'filePath' と 'moduleName' の間に一切の関係を仮定しない。
-- 'filePath' は診断スパン・Query 層で使用される実ファイルパスを表す。
data SourceEntry = SourceEntry
  { filePath :: FilePath,
    sourceText :: Text
  }
  deriving (Show)

data CompileInput = CompileInput
  { -- | Module name → source entry. The map is treated as the complete
    -- world: any module not present here is "missing" from the
    -- compiler's point of view.
    sources :: Map ModuleName SourceEntry,
    -- | The module that drives the build. Used as the IR module name and
    -- as the root for missing-import detection.
    rootModule :: ModuleName
  }
  deriving (Show)

data CompileResult = CompileResult
  { -- | The lowered IR. 'Nothing' if any error-severity diagnostic was
    -- raised before lowering succeeded.
    irModule :: Maybe IRModule,
    -- | API-surface schema entries for AI tool calling and runtime validation.
    -- 'Nothing' under the same condition as 'irModule'.
    schemaEntries :: Maybe [SchemaEntry],
    -- | Unified diagnostic stream, ordered roughly by phase
    -- (parse → identify → constrain → solve → zonk → lower).
    diagnostics :: [Diagnostic],
    -- | Name resolution result. Always returned so LSP / CLI can list
    -- agents, detect unused declarations, and perform qualified-name
    -- lookup without re-running the compiler.
    identifierResult :: Maybe IdentifierResult,
    -- | Solver output for LSP type-on-hover. Always returned (even when
    -- diagnostics are present) so the editor can show partial results.
    solverResult :: Maybe SolverResult,
    -- | Zonker output for LSP type-on-hover. Always returned.
    zonkResult :: Maybe ZonkResult
  }

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

-- | Compile a set of in-memory sources to IR + schema. Pure (no I\/O).
--
-- The result's @diagnostics@ list is the single source of truth for
-- failure: callers should branch on @hasErrors diagnostics@ rather than
-- on the @Maybe@ payloads.
compile :: CompileInput -> CompileResult
compile input =
  let (parsed, parseDiags) = parseSources input.sources
      cycleDiags = detectImportCycles parsed
      missingDiags = detectMissingImports parsed
      (idResult, idErrors) = identify parsed
      idDiags = map Identifier.toDiagnostic idErrors
      (cgResult, cgErrors) = generateConstraints idResult
      cgDiags = map CG.toDiagnostic cgErrors
      solverResult_ = solve cgResult
      solverDiags = map Solver.toDiagnostic solverResult_.solverErrors
      zonkResult_ = zonk idResult cgResult solverResult_
      zonkDiags = map Zonker.toDiagnostic zonkResult_.zonkErrors
      exhaustiveDiags = map Exhaustive.toDiagnostic (checkExhaustive zonkResult_)
      preLowerDiags =
        parseDiags
          <> cycleDiags
          <> missingDiags
          <> idDiags
          <> cgDiags
          <> solverDiags
          <> zonkDiags
          <> exhaustiveDiags
      shouldLower = not (hasErrors preLowerDiags)
      (loweredIR, loweringDiags)
        | shouldLower =
            let (ir, errs) = lowerProgram input.rootModule zonkResult_
             in (Just ir, map Lowering.toDiagnostic errs)
        | otherwise = (Nothing, [])
      shouldEmitArtefacts =
        shouldLower && not (hasErrors loweringDiags)
      schema = if shouldEmitArtefacts then Just (buildSchemas zonkResult_) else Nothing
      finalIR = if shouldEmitArtefacts then loweredIR else Nothing
      allDiags = preLowerDiags <> loweringDiags
   in CompileResult
        { irModule = finalIR,
          schemaEntries = schema,
          diagnostics = allDiags,
          identifierResult = Just idResult,
          solverResult = Just solverResult_,
          zonkResult = Just zonkResult_
        }

-- ===========================================================================
-- Parse helper
-- ===========================================================================

-- | Parse every source in the input map. Each 'SourceEntry' carries the
-- real 'FilePath' that is embedded into error spans; the compiler makes
-- no assumption about the relationship between a 'ModuleName' and its
-- 'FilePath'.
parseSources :: Map ModuleName SourceEntry -> (Map ModuleName (Module Parsed), [Diagnostic])
parseSources sources =
  let parseEntry (modName, entry) =
        let (stream, lexErrors) = Lexer.lex entry.filePath entry.sourceText
            (m, errs) = Parser.parse entry.filePath stream
         in ((modName, m), map Parser.toDiagnostic errs <> map Lexer.toDiagnostic lexErrors)
      parsedEntries = map parseEntry (Map.toList sources)
      modules = Map.fromList (map fst parsedEntries)
      diags = concatMap snd parsedEntries
   in (modules, diags)

-- ===========================================================================
-- Import-cycle detection
-- ===========================================================================

-- | Detect any non-trivial strongly-connected component in the import
-- graph. Self-imports are also flagged.
detectImportCycles :: Map ModuleName (Module Parsed) -> [Diagnostic]
detectImportCycles modules =
  let graph = Map.map (importsOf modules) modules
      cycles = findCycles graph
   in concatMap (cycleDiagnostic modules) cycles

importsOf :: Map ModuleName (Module Parsed) -> Module Parsed -> Set ModuleName
importsOf _ m =
  Set.fromList
    [ importModuleName imp
      | DeclarationImport ImportDeclaration {kind = imp} <- m.declarations
    ]

importModuleName :: ImportKind -> ModuleName
importModuleName = \case
  ImportNames {moduleName} -> moduleName
  ImportModule {moduleName} -> moduleName

-- | Tarjan-style SCC over a 'Map'-encoded directed graph. Returns each
-- SCC of size >= 2 *and* every self-loop as a 1-element cycle.
findCycles :: Map ModuleName (Set ModuleName) -> [[ModuleName]]
findCycles graph =
  let nodes = Map.keys graph
      sccs = strongComponents graph nodes
      multi = filter (\xs -> length xs > 1) sccs
      selfLoops = [[n] | n <- nodes, n `Set.member` Map.findWithDefault Set.empty n graph]
   in multi <> selfLoops

-- | Minimal Tarjan implementation. Not optimised for large graphs (we
-- expect <1000 modules) but stable and dependency-free.
strongComponents :: Map ModuleName (Set ModuleName) -> [ModuleName] -> [[ModuleName]]
strongComponents graph allNodes =
  let go (visited, ordered) node
        | Set.member node visited = (visited, ordered)
        | otherwise =
            let (visited', subOrdered) = dfs visited node
             in (visited', subOrdered <> ordered)
      dfs visited node
        | Set.member node visited = (visited, [])
        | otherwise =
            let visited1 = Set.insert node visited
                successors = Set.toList (Map.findWithDefault Set.empty node graph)
                (visited2, sub) = foldl stepDfs (visited1, []) successors
             in (visited2, node : sub)
      stepDfs (vis, acc) n =
        let (vis', sub) = dfs vis n
         in (vis', sub <> acc)
      (_, postOrder) = foldl go (Set.empty, []) allNodes
      reversed = reverseGraph graph
      assignSccs (visited, sccs) node
        | Set.member node visited = (visited, sccs)
        | otherwise =
            let (visited', component) = collect reversed visited node
             in (visited', component : sccs)
      collect rev visited node
        | Set.member node visited = (visited, [])
        | otherwise =
            let visited1 = Set.insert node visited
                successors = Set.toList (Map.findWithDefault Set.empty node rev)
                (visited2, sub) = foldl (\(v, acc) n -> let (v', s) = collect rev v n in (v', s <> acc)) (visited1, []) successors
             in (visited2, node : sub)
      (_, components) = foldl assignSccs (Set.empty, []) postOrder
   in components

reverseGraph :: Map ModuleName (Set ModuleName) -> Map ModuleName (Set ModuleName)
reverseGraph graph =
  Map.fromListWith
    Set.union
    [ (target, Set.singleton source)
      | (source, targets) <- Map.toList graph,
        target <- Set.toList targets
    ]

cycleDiagnostic :: Map ModuleName (Module Parsed) -> [ModuleName] -> [Diagnostic]
cycleDiagnostic modules cycle_ =
  case cycle_ of
    [] -> []
    (m : _) ->
      let sourceSpan = case Map.lookup m modules of
            Just module_ -> module_.sourceSpan
            Nothing -> dummySpan
          rendered = Text.intercalate " → " (cycle_ <> [m])
       in [diagnosticError "K0110" ("import cycle: " <> rendered) sourceSpan]

-- ===========================================================================
-- Missing-import detection
-- ===========================================================================

-- | Flag imports that reference modules absent from the input map.
detectMissingImports :: Map ModuleName (Module Parsed) -> [Diagnostic]
detectMissingImports modules =
  [ missingDiagnostic decl name
    | (_, m) <- Map.toList modules,
      decl@(DeclarationImport ImportDeclaration {kind}) <- m.declarations,
      let name = importModuleName kind,
      not (Map.member name modules)
  ]

missingDiagnostic :: Declaration Parsed -> ModuleName -> Diagnostic
missingDiagnostic decl name =
  diagnosticError
    "K0107"
    ("imported module not found: '" <> name <> "'")
    (sourceSpanOf decl)

-- ===========================================================================
-- Internal helpers
-- ===========================================================================

dummySpan :: SourceSpan
dummySpan =
  SrcSpan
    { filePath = "<unknown>",
      start = Position {line = 1, column = 1},
      end = Position {line = 1, column = 1}
    }
