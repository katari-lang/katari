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
--   → identify         -- emits import-cycle (K0110) and missing-import (K0107)
--                      --   diagnostics in addition to name-resolution errors
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
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.AST (Module, Phase (Parsed))
import Katari.Diagnostic (Diagnostic, hasErrors)
import Katari.IR (IRModule)
import Katari.Lexer as Lexer
import Katari.Lowering (lowerProgram)
import Katari.Lowering qualified as Lowering
import Katari.Parser qualified as Parser
import Katari.Schema (SchemaEntry, buildSchemas)
import Katari.Stdlib qualified as Stdlib
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
    identifierResult :: IdentifierResult,
    -- | Solver output for LSP type-on-hover. Always returned (even when
    -- diagnostics are present) so the editor can show partial results.
    solverResult :: SolverResult,
    -- | Zonker output for LSP type-on-hover. Always returned.
    zonkResult :: ZonkResult
  }

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

-- | Compile a set of in-memory sources to IR + schema. Pure (no I\/O).
--
-- The result's @diagnostics@ list is the single source of truth for
-- failure: callers should branch on @hasErrors diagnostics@ rather than
-- on the @Maybe@ payloads.
--
-- Example:
--
-- @
-- import Data.Map.Strict qualified as Map
--
-- let src    = "agent hello() -> string { return \\"hello\\" }"
--     input  = CompileInput
--                { sources    = Map.singleton "main" (SourceEntry "main.ktr" src)
--                , rootModule = "main" }
--     result = compile input
-- null (diagnostics result)  -- True  (no errors)
-- isJust (irModule result)   -- True  (IR was emitted)
-- @
compile :: CompileInput -> CompileResult
compile input =
  let stdlibEntries =
        Map.mapWithKey
          (\moduleName src -> SourceEntry ("<stdlib:" <> show moduleName <> ">") src)
          Stdlib.stdlibSources
      -- User sources win on overlap so that a user-facing error
      -- (K0113 reserved-name conflict) still surfaces if someone
      -- defines a module called @prim@ themselves.
      mergedSources = Map.union input.sources stdlibEntries
      (parsed, parseDiags) = parseSources mergedSources
      (idResult, idErrors) = identify Stdlib.stdlibModuleNames parsed
      idDiags = map Identifier.toDiagnostic idErrors
      (cgResult, cgErrors) = generateConstraints idResult
      cgDiags = map CG.toDiagnostic cgErrors
      (solverResult_, solverErrors) = solve cgResult
      solverDiags = map Solver.toDiagnostic solverErrors
      (zonkResult_, zonkErrors) = zonk idResult cgResult solverResult_
      zonkDiags = map Zonker.toDiagnostic zonkErrors
      exhaustiveDiags = map Exhaustive.toDiagnostic (checkExhaustive idResult zonkResult_)
      preLowerDiags =
        parseDiags
          <> idDiags
          <> cgDiags
          <> solverDiags
          <> zonkDiags
          <> exhaustiveDiags
      shouldLower = not (hasErrors preLowerDiags)
      (loweredIR, loweringDiags)
        | shouldLower =
            let (eitherIR, errs) = lowerProgram input.rootModule idResult zonkResult_
                structuralDiags = map Lowering.toDiagnostic errs
             in case eitherIR of
                  Right ir -> (Just ir, structuralDiags)
                  Left internalDiag -> (Nothing, structuralDiags <> [internalDiag])
        | otherwise = (Nothing, [])
      shouldEmitArtefacts =
        shouldLower && not (hasErrors loweringDiags)
      schema = if shouldEmitArtefacts then Just (buildSchemas idResult zonkResult_) else Nothing
      finalIR = if shouldEmitArtefacts then loweredIR else Nothing
      allDiags = preLowerDiags <> loweringDiags
   in CompileResult
        { irModule = finalIR,
          schemaEntries = schema,
          diagnostics = allDiags,
          identifierResult = idResult,
          solverResult = solverResult_,
          zonkResult = zonkResult_
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
