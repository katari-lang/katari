-- | Identifiers used throughout the Katari compiler.
--
-- Top-level declarations are identified by 'QualifiedName' (the inter-module
-- identifier). Local variables (let bindings, parameters, for variables) are
-- identified by 'LocalVarId', a module-local counter that starts at 0 for
-- each module.
--
-- The 'VariableResolution' type captures this distinction at the AST level:
-- a resolved variable reference is either a top-level 'QualifiedName' or a
-- local 'LocalVarId'.
--
-- 'QualifiedName' / 'renderQualifiedName' live in 'Katari.Common' so the
-- IR can share them; they are re-exported here for convenience.
module Katari.Id
  ( -- * Variable resolution
    VariableResolution (..),
    LocalVarId (..),

    -- * Legacy ID types (being phased out — use QualifiedName for top-level)
    VariableId (..),
    ModuleId (..),

    -- * Re-exports from Common
    QualifiedName (..),
    renderQualifiedName,
  )
where

import Katari.Common (QualifiedName (..), renderQualifiedName)

-- | How a variable reference was resolved by the Identifier phase.
--
-- Top-level declarations (agent, data constructor, request, external) are
-- identified by their 'QualifiedName'. Local variables (let, parameter, for)
-- are identified by a 'LocalVarId' scoped to the enclosing module.
data VariableResolution
  = ResolvedTopLevel QualifiedName
  | ResolvedLocal LocalVarId
  deriving (Eq, Ord, Show)

-- | Module-local variable identifier. Issued by the Identifier phase for
-- local bindings (let, parameters, for variables). The counter starts at 0
-- for each module independently — no global state is needed.
newtype LocalVarId = LocalVarId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the value namespace (legacy — being replaced by
-- 'VariableResolution'). Still used internally by some phases during the
-- transition.
newtype VariableId = VariableId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the module namespace (legacy — being replaced by
-- 'ModuleName' / 'Text').
newtype ModuleId = ModuleId Int
  deriving (Eq, Ord, Show)
