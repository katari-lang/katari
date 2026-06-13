-- | The Identifier pass resolves every name reference in a 'Katari.Data.AST.Parsed' module against
-- the names in scope, producing a 'Katari.Data.AST.Identified' module (each reference carries a
-- @Just@ resolution, or @Nothing@ when it could not be resolved). This module defines the monad it
-- runs in (the environment, state, and capabilities — fresh-id supply, scope, diagnostics), the I/O
-- of the pass (its entry points and the cross-module interface they exchange), and stubbed bodies
-- for the resolution walk itself, which is filled in incrementally.
module Katari.Identifier where

import Control.Monad.RWS.CPS (RWS, evalRWS)
import Control.Monad.RWS.Class (MonadReader, MonadState, asks, local, state)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST (Module, Phase (..))
import Katari.Data.Id (GenericId (..), LocalVariableId (..), TypeResolution, VariableResolution)
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Diagnostics (Diagnostics)

-- | The names visible at a point in the source, one map per namespace the Identifier resolves.
-- Top-level and imported names seed it; local bindings (parameters, generics, @let@) extend it
-- through 'MonadReader''s 'local'. Labels are resolved type-directed by the checker, not here, so
-- there is no label namespace.
data Scope = Scope
  { variableBindings :: Map Text VariableResolution,
    typeBindings :: Map Text TypeResolution,
    moduleBindings :: Map Text ModuleName
  }
  deriving stock (Eq, Show)

emptyScope :: Scope
emptyScope = Scope {variableBindings = Map.empty, typeBindings = Map.empty, moduleBindings = Map.empty}

-- | Read-only context of the pass: the module being identified (to qualify its own declarations)
-- and the names currently in scope.
data IdentifierEnvironment = IdentifierEnvironment
  { moduleName :: ModuleName,
    scope :: Scope
  }

-- | The fresh-id supply, threaded as state across the whole pass (counters only ever increase).
data IdentifierState = IdentifierState
  { nextGenericId :: Int,
    nextLocalVariableId :: Int
  }

initialIdentifierState :: IdentifierState
initialIdentifierState = IdentifierState {nextGenericId = 0, nextLocalVariableId = 0}

-- | The Identifier monad: read the scope, accumulate diagnostics, supply fresh ids. A plain RWS
-- alias (like the Normalizer); emission, supply, and scope are free functions over the mtl classes.
type Identifier a = RWS IdentifierEnvironment Diagnostics IdentifierState a

runIdentifier :: IdentifierEnvironment -> Identifier a -> (a, Diagnostics)
runIdentifier environment action = evalRWS action environment initialIdentifierState

-- Fresh-id supply ---------------------------------------------------------------------------------

freshGenericId :: (MonadState IdentifierState m) => m GenericId
freshGenericId = state (\current -> (GenericId current.nextGenericId, current {nextGenericId = current.nextGenericId + 1}))

freshLocalVariableId :: (MonadState IdentifierState m) => m LocalVariableId
freshLocalVariableId = state (\current -> (LocalVariableId current.nextLocalVariableId, current {nextLocalVariableId = current.nextLocalVariableId + 1}))

-- Scope -------------------------------------------------------------------------------------------

lookupVariable :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe VariableResolution)
lookupVariable name = asks (\environment -> Map.lookup name environment.scope.variableBindings)

lookupType :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe TypeResolution)
lookupType name = asks (\environment -> Map.lookup name environment.scope.typeBindings)

lookupModule :: (MonadReader IdentifierEnvironment m) => Text -> m (Maybe ModuleName)
lookupModule name = asks (\environment -> Map.lookup name environment.scope.moduleBindings)

-- | Run an action with one more variable binding in scope (restored on exit).
withVariable :: (MonadReader IdentifierEnvironment m) => Text -> VariableResolution -> m a -> m a
withVariable name resolution =
  local (overScope (\scope -> scope {variableBindings = Map.insert name resolution scope.variableBindings}))

-- | Run an action with one more type binding in scope (restored on exit).
withType :: (MonadReader IdentifierEnvironment m) => Text -> TypeResolution -> m a -> m a
withType name resolution =
  local (overScope (\scope -> scope {typeBindings = Map.insert name resolution scope.typeBindings}))

overScope :: (Scope -> Scope) -> IdentifierEnvironment -> IdentifierEnvironment
overScope f environment = environment {scope = f environment.scope}

-- Module interface (cross-module name-resolution surface) -----------------------------------------

-- | One exported name's name-resolution surface: the namespaces it populates and what each resolves
-- to. Minimal by design — only what an importing module needs to resolve the name. Type shapes,
-- generic arity and variance are not here; the global env-build pass derives those from the
-- identified declarations for the checker.
data ExportedSymbol = ExportedSymbol
  { variable :: Maybe VariableResolution,
    typeLevel :: Maybe TypeResolution
  }
  deriving stock (Eq, Show)

-- | What a module exposes to importers, keyed by exported name. Produced by 'scanExports' from the
-- parsed module alone (the export surface does not depend on imports), so every module's interface
-- is available before any module is resolved — letting 'identifyModule' run per-module and tolerate
-- import cycles.
newtype ModuleInterface = ModuleInterface
  { exports :: Map Text ExportedSymbol
  }
  deriving stock (Eq, Show)

-- | The context an 'identifyModule' run resolves against: the interfaces of every importable module
-- and the ambient names injected into every module (primitive / stdlib seeds). The driver builds
-- this from the 'scanExports' results before resolving bodies.
data ImportContext = ImportContext
  { moduleInterfaces :: Map ModuleName ModuleInterface,
    ambientVariables :: Map Text VariableResolution,
    ambientTypes :: Map Text TypeResolution
  }
  deriving stock (Eq, Show)

-- Scope-frame index (LSP) -------------------------------------------------------------------------

-- | The names visible across one lexical region, captured as the region is left. The LSP layer
-- answers "what is in scope at this position?" by finding the innermost frame whose span contains
-- it.
data ScopeFrame = ScopeFrame
  { sourceSpan :: SourceSpan,
    visibleScope :: Scope
  }
  deriving stock (Eq, Show)

-- | Every scope frame captured while resolving a module, for offline visibility queries.
newtype ScopeIndex = ScopeIndex
  { frames :: List ScopeFrame
  }
  deriving stock (Eq, Show)

emptyScopeIndex :: ScopeIndex
emptyScopeIndex = ScopeIndex {frames = []}

-- Identifier output -------------------------------------------------------------------------------

-- | The product of resolving one module: the identified AST (every reference carries its
-- resolution) and the scope-frame index for LSP. The cross-module data is recovered elsewhere — this
-- module's 'ModuleInterface' from 'scanExports', and the declarations the global env-build consumes
-- by filtering 'identifiedAst' — so neither is duplicated here.
data IdentifiedModule = IdentifiedModule
  { identifiedAst :: Module Identified,
    scopeIndex :: ScopeIndex
  }
  deriving stock (Eq, Show)

-- Entry points ------------------------------------------------------------------------------------

-- | Project a parsed module's public surface. Import-independent and side-effect-free: a name is
-- exported by virtue of being a top-level declaration, so neither imports nor bodies are consulted.
--
-- TODO: walk the top-level declarations and populate the export map. Currently a stub returning the
-- empty interface.
scanExports :: ModuleName -> Module Parsed -> ModuleInterface
scanExports _moduleName _parsedModule = ModuleInterface {exports = Map.empty}

-- | Resolve every name reference in a parsed module against the names in scope, producing the
-- identified module (AST + scope-frame index) and the diagnostics emitted along the way.
--
-- TODO: 'resolveModule' (the walk) and 'initialScope' (import / ambient seeding) are stubs; the body
-- is filled in incrementally.
identifyModule :: ImportContext -> ModuleName -> Module Parsed -> (IdentifiedModule, Diagnostics)
identifyModule importContext moduleName parsedModule =
  runIdentifier environment (resolveModule parsedModule)
  where
    environment =
      IdentifierEnvironment
        { moduleName = moduleName,
          scope = initialScope importContext
        }

-- | Seed a module's top-level scope from the ambient names and the interfaces of its imports.
--
-- TODO: resolve the module's import declarations against 'moduleInterfaces' and layer them over the
-- ambient names and this module's own top-level declarations. Currently the empty scope.
initialScope :: ImportContext -> Scope
initialScope _importContext = emptyScope

-- | The resolution walk: 'Module' 'Parsed' to 'Module' 'Identified', capturing scope frames as it
-- descends.
--
-- TODO: not yet implemented.
resolveModule :: Module Parsed -> Identifier IdentifiedModule
resolveModule _parsedModule = error "Katari.Identifier.resolveModule: not yet implemented"
