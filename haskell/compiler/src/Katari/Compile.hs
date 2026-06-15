-- | The compile driver: wires every phase over a set of source modules and collects the artifacts
-- and diagnostics. The leaf phases are stubbed; this module fixes the orchestration and the I/O
-- between phases so it need not be reshuffled once the internals land.
--
-- No import-graph topological sort is needed: 'scanExports' is import-independent, so every module's
-- interface is available before any module is identified, and identify / check run per module. The
-- one global step is 'buildEnvironment' (variance is a cross-module fixed point).
--
-- > parse* -> scanExports* -> identify* -> [global] buildEnvironment -> check* -> lower*
--
-- The runtime uploads modules individually, so lowering produces an 'IRModule' per module and there
-- is no whole-program link step. Each callable's schema travels inside its 'IRModule'
-- ('Katari.Data.IR.schemas', keyed by 'Katari.Data.IR.BlockId'), so there is no separate schema phase.
module Katari.Compile where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Katari.Data.AST (Module, Phase (Parsed, Typed))
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.SourceSpan (Located (..), sourceSpanOf)
import Katari.Diagnostics (Diagnostics)
import Katari.Error (CompilerError (..), IdentifierError (..), ReservedModuleNameErrorInfo (..))
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..), ModuleInterface, SymbolTable)
import Katari.Lowering (lowerModule)
import Katari.Parser (parseModule)
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker (checkModule)
import Katari.Typechecker.Environment (buildEnvironment)

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
    { loweredModules = Map.restrictKeys (fst <$> lowered) userKeys,
      symbolTables = Map.restrictKeys ((\identifiedModule -> identifiedModule.symbolTable) <$> identifiedModules) userKeys,
      typedModules = Map.restrictKeys typedModules userKeys,
      diagnostics =
        reservedDiagnostics
          <> parseDiagnostics
          <> identifyDiagnostics
          <> environmentDiagnostics
          <> checkDiagnostics
          <> lowerDiagnostics
    }
  where
    -- Split off user modules whose name is compiler-reserved: report each (K2008, anchored at the
    -- offending module's span) and keep only the admissible ones. Reserved names never reach the
    -- pipeline, so they neither shadow the stdlib nor pollute the default-import namespace.
    (reservedUserSources, admissibleUserSources) =
      Map.partitionWithKey (\moduleName _ -> Stdlib.isReservedModuleName moduleName) input.sources
    userKeys = Map.keysSet admissibleUserSources
    reservedDiagnostics = Map.foldMapWithKey reservedDiagnostic reservedUserSources
    reservedDiagnostic moduleName source =
      Seq.singleton
        Located
          { value = CompilerErrorIdentifier (IdentifierErrorReservedModuleName ReservedModuleNameErrorInfo {moduleName = moduleName}),
            sourceSpan = sourceSpanOf (fst (parseModule moduleName source))
          }

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

    -- Build the global type environment from every identified module.
    (typeEnvironment, environmentDiagnostics) =
      buildEnvironment ((\identified' -> identified'.identifiedAst) <$> Map.elems identifiedModules)

    -- Check (per module, against the read-only global environment).
    -- TODO: gate lowering on the absence of errors once diagnostics carry severity here.
    checked :: Map ModuleName (Module Typed, Diagnostics)
    checked = (\identified' -> checkModule typeEnvironment identified'.identifiedAst) <$> identifiedModules
    typedModules = fst <$> checked
    checkDiagnostics = foldMap snd checked

    -- Lower (per module). No link step — modules are uploaded individually; schemas travel in the IR.
    lowered :: Map ModuleName (IRModule, Diagnostics)
    lowered = Map.mapWithKey lowerModule typedModules
    lowerDiagnostics = foldMap snd lowered
