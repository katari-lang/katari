-- | The Identifier pass resolves every name reference in a 'Katari.Data.AST.Parsed' module against
-- the names in scope, producing a 'Katari.Data.AST.Identified' module (each reference carries a
-- @Just@ resolution, or @Nothing@ when it could not be resolved). This module defines only the
-- monad it runs in — the environment, state, and capabilities (fresh-id supply, scope, diagnostics)
-- — not the resolution walk itself.
module Katari.Identifier where

import Control.Monad.RWS.CPS (RWS, evalRWS)
import Control.Monad.RWS.Class (MonadReader, MonadState, asks, local, state)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Katari.Data.Id (GenericId (..), LocalVariableId (..), TypeResolution, VariableResolution)
import Katari.Data.ModuleName (ModuleName)
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
