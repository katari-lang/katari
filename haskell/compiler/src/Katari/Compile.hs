-- | The compile driver: wires every phase over a set of source modules and collects the artifacts
-- and diagnostics. The leaf phases are stubbed; this module fixes the orchestration and the I/O
-- between phases so it need not be reshuffled once the internals land.
--
-- No import-graph topological sort is needed: 'scanExports' is import-independent, so every module's
-- interface is available before any module is identified, and identify / check run per module. The
-- one global step is 'buildEnvironment' (variance is a cross-module fixed point).
--
-- > parse* -> scanExports* -> identify* -> [global] buildEnvironment -> check* -> lower* / schema*
--
-- The runtime uploads modules individually, so lowering produces a 'LoweredModule' per module and
-- there is no whole-program link step.
module Katari.Compile where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST (Module, Phase (Parsed, Typed))
import Katari.Data.IR (LoweredModule)
import Katari.Data.Id (TypeResolution, VariableResolution)
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (Diagnostics)
import Katari.Identifier (IdentifiedModule (..), ImportContext (..), ModuleInterface, ScopeIndex, identifyModule, scanExports)
import Katari.Lowering (lowerModule)
import Katari.Parser (parseModule)
import Katari.Schema (SchemaEntry, buildSchema)
import Katari.Typechecker.Check (checkModule)
import Katari.Typechecker.Environment (buildEnvironment)

-- | What to compile: the source of every module, plus the ambient names injected into every module
-- (primitive / stdlib seeds — supplied by the driver, see 'ImportContext').
data CompileInput = CompileInput
  { sources :: Map ModuleName Text,
    ambientVariables :: Map Text VariableResolution,
    ambientTypes :: Map Text TypeResolution
  }

-- | The product of a compile: each module's lowered output (uploaded individually) and schema, the
-- LSP scope index and typed AST per module (for query / hover), and every diagnostic emitted along
-- the way.
data CompileResult = CompileResult
  { loweredModules :: Map ModuleName LoweredModule,
    schemas :: Map ModuleName (List SchemaEntry),
    scopeIndexes :: Map ModuleName ScopeIndex,
    typedModules :: Map ModuleName (Module Typed),
    diagnostics :: Diagnostics
  }

compile :: CompileInput -> CompileResult
compile input =
  CompileResult
    { loweredModules = loweredModules,
      schemas = moduleSchemas,
      scopeIndexes = (\identifiedModule -> identifiedModule.scopeIndex) <$> identifiedModules,
      typedModules = typedModules,
      diagnostics =
        parseDiagnostics
          <> identifyDiagnostics
          <> environmentDiagnostics
          <> checkDiagnostics
          <> lowerDiagnostics
    }
  where
    -- Parse (per module).
    parsed :: Map ModuleName (Module Parsed, Diagnostics)
    parsed = Map.mapWithKey parseModule input.sources
    parsedModules = fst <$> parsed
    parseDiagnostics = foldMap snd parsed

    -- Scan exports (import-independent) and assemble the import context every module resolves against.
    interfaces :: Map ModuleName ModuleInterface
    interfaces = Map.mapWithKey scanExports parsedModules
    importContext =
      ImportContext
        { moduleInterfaces = interfaces,
          ambientVariables = input.ambientVariables,
          ambientTypes = input.ambientTypes
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
    -- TODO: gate lowering / schema on the absence of errors once diagnostics carry severity here.
    checked :: Map ModuleName (Module Typed, Diagnostics)
    checked = (\identified' -> checkModule typeEnvironment identified'.identifiedAst) <$> identifiedModules
    typedModules = fst <$> checked
    checkDiagnostics = foldMap snd checked

    -- Lower + schema (per module). No link step — modules are uploaded individually.
    lowered :: Map ModuleName (LoweredModule, Diagnostics)
    lowered = Map.mapWithKey lowerModule typedModules
    loweredModules = fst <$> lowered
    lowerDiagnostics = foldMap snd lowered
    moduleSchemas = Map.mapWithKey buildSchema typedModules
