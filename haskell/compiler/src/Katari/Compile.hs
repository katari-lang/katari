-- | The compile driver: wires every phase over a set of source modules and collects the artifacts
-- and diagnostics. The leaf phases are stubbed; this module fixes the orchestration and the I/O
-- between phases so it need not be reshuffled once the internals land.
--
-- No import-graph topological sort is needed: 'scanExports' is import-independent, so every module's
-- interface is available before any module is identified, and parse / scanExports / identify / lower
-- run per module. The two global steps are 'buildEnvironment' (variance is a cross-module fixed point)
-- and 'checkProgram' (an agent may infer its return / effect from agents it calls, across modules and
-- through mutual recursion, so the checker walks the whole program in value-dependency order).
--
-- > parse* -> scanExports* -> identify* -> [global] buildEnvironment -> [global] check -> lower*
--
-- The runtime uploads modules individually, so lowering produces an 'IRModule' per module and there
-- is no whole-program link step. Each callable's schema travels inside its 'IRModule'
-- ('Katari.Data.IR.schemas', keyed by 'Katari.Data.IR.BlockId'), so there is no separate schema phase.
module Katari.Compile where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Data.AST (Module, Phase (Identified, Parsed, Typed))
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName, renderModuleName)
import Katari.Data.SourceSpan (Position (..), SourceSpan (..))
import Katari.Diagnostics (Diagnostics, diagnosticAt, hasErrors)
import Katari.Error (CompilerError (..), IdentifierError (..), ReservedModuleNameErrorInfo (..))
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..), ModuleInterface, SymbolTable)
import Katari.Lowering (lowerModule)
import Katari.Parser (parseModule)
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker (checkProgram)
import Katari.Typechecker.Environment (buildEnvironment)
import Katari.Typechecker.ValueGraph (valueSCCs)

-- | What to compile: the user's module sources. The wired-in stdlib is added automatically by
-- 'compile'.
newtype CompileInput = CompileInput
  { sources :: Map ModuleName Text
  }

-- | The product of a compile: each module's lowered IR (uploaded individually; schemas travel inside
-- it), the LSP symbol table and typed AST per module (for query / hover), and every diagnostic
-- emitted along the way. These maps are keyed by the /user's/ modules only — the spliced-in stdlib is
-- an implementation detail of resolution / typing and is not handed back.
data CompileResult = CompileResult
  { loweredModules :: Map ModuleName IRModule,
    symbolTables :: Map ModuleName SymbolTable,
    typedModules :: Map ModuleName (Module Typed),
    diagnostics :: Diagnostics
  }

-- | The wired-in stdlib, parsed and interface-scanned once. No argument, so GHC evaluates these once
-- and shares them across every 'compile' call: the stdlib sources are a build-time constant, so
-- re-parsing them per compile would be pure waste. (Later phases — identify / check / lower — still
-- run per call, since they fold the stdlib together with the user's modules; they can be memoized the
-- same way once they are no longer stubs and the cost matters.)
stdlibParsed :: Map ModuleName (Module Parsed, Diagnostics)
stdlibParsed = Map.mapWithKey parseModule Stdlib.stdlibSources

stdlibInterfaces :: Map ModuleName ModuleInterface
stdlibInterfaces = Map.mapWithKey scanExports (fst <$> stdlibParsed)

-- | Compile the user's modules. The wired-in stdlib is spliced in and the @primitive@ root is
-- default-imported automatically — there is one entry point and no caller chooses what is in scope. A
-- user module on a compiler-reserved name (an exact stdlib name, or anything under the @primitive.*@
-- namespace) is rejected with K2008 and excluded, rather than silently shadowing the stdlib or being
-- globally default-imported (see 'Katari.Stdlib.isReservedModuleName').
compile :: CompileInput -> CompileResult
compile input =
  CompileResult
    { -- Lowering is gated on the program being error-free: never emit IR for code that failed to
      -- parse / resolve / type-check (a warning does not block it).
      loweredModules =
        if lowerable
          then Map.restrictKeys (fst <$> lowered) userKeys
          else mempty,
      symbolTables = Map.restrictKeys ((\identifiedModule -> identifiedModule.symbolTable) <$> identifiedModules) userKeys,
      typedModules = Map.restrictKeys typedModules userKeys,
      diagnostics = preLoweringDiagnostics <> lowerDiagnostics
    }
  where
    -- Split off user modules whose name is compiler-reserved: report each (K2008) and keep only the
    -- admissible ones. Reserved names never reach the pipeline, so they neither shadow the stdlib nor
    -- pollute the default-import namespace.
    (reservedUserSources, admissibleUserSources) =
      Map.partitionWithKey (\moduleName _ -> Stdlib.isReservedModuleName moduleName) input.sources
    userKeys = Map.keysSet admissibleUserSources
    -- Anchored at the module's file start, not a parsed span: a reserved module is excluded from the
    -- pipeline (never parsed), and its name comes from the file path, not source, so there is no
    -- narrower span to point at.
    reservedDiagnostics = Map.foldMapWithKey reservedDiagnostic reservedUserSources
    reservedDiagnostic moduleName _source =
      diagnosticAt
        (moduleStartSpan moduleName)
        (CompilerErrorIdentifier (IdentifierErrorReservedModuleName ReservedModuleNameErrorInfo {moduleName = moduleName}))

    -- Parse: the stdlib parse is the shared 'stdlibParsed' CAF; only the user modules are parsed here.
    userParsed :: Map ModuleName (Module Parsed, Diagnostics)
    userParsed = Map.mapWithKey parseModule admissibleUserSources
    parsedModules = (fst <$> stdlibParsed) <> (fst <$> userParsed)
    parseDiagnostics = foldMap snd stdlibParsed <> foldMap snd userParsed

    -- Scan exports (import-independent) and assemble the import context every module resolves against.
    interfaces :: Map ModuleName ModuleInterface
    interfaces = stdlibInterfaces <> Map.mapWithKey scanExports (fst <$> userParsed)
    importContext =
      ImportContext
        { moduleInterfaces = interfaces,
          defaultImports = Stdlib.defaultImports
        }

    -- Identify (per module; no dependency ordering needed — all interfaces are already available).
    identified :: Map ModuleName (IdentifiedModule, Diagnostics)
    identified = Map.mapWithKey (identifyModule importContext) parsedModules
    identifiedModules = fst <$> identified
    identifyDiagnostics = foldMap snd identified
    identifiedAsts :: Map ModuleName (Module Identified)
    identifiedAsts = (\identified' -> identified'.identifiedAst) <$> identifiedModules

    -- Build the global type environment from every identified module (keyed by module name, so each
    -- declaration's qualified name is the key joined with the declaration name).
    (typeEnvironment, environmentDiagnostics) = buildEnvironment identifiedAsts

    -- Check (whole-program, in value-dependency order). An agent may infer its return / effect from
    -- agents it calls — across modules and through mutual recursion — so the checker walks the value
    -- SCCs ('valueSCCs') to grow the value environment dependency-first; it cannot run per module.
    (typedModules, checkDiagnostics) = checkProgram typeEnvironment (valueSCCs identifiedAsts) identifiedAsts

    -- Everything emitted before lowering; lowering (and its diagnostics) is skipped when this has any
    -- error, so a failed compile yields no IR rather than IR built from an ill-typed AST.
    preLoweringDiagnostics =
      reservedDiagnostics <> parseDiagnostics <> identifyDiagnostics <> environmentDiagnostics <> checkDiagnostics
    lowerable = not (hasErrors preLoweringDiagnostics)

    -- Lower (per module). No link step — modules are uploaded individually; schemas travel in the IR.
    lowered :: Map ModuleName (IRModule, Diagnostics)
    lowered = Map.mapWithKey lowerModule typedModules
    lowerDiagnostics = if lowerable then foldMap snd lowered else mempty

-- | An empty span at the start of a module's file (line 1, column 1). The file path matches the one
-- 'Katari.Parser.parseModule' stamps on a module's spans, so a driver-level diagnostic about a module
-- as a whole (which has no narrower source location) renders against the same file.
moduleStartSpan :: ModuleName -> SourceSpan
moduleStartSpan moduleName =
  SourceSpan {filePath = Text.unpack (renderModuleName moduleName), start = fileStart, end = fileStart}
  where
    fileStart = Position {line = 1, column = 1}
