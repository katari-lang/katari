module Katari.Data.Id where

import Data.Aeson (ToJSON (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName)

-- | A generic parameter's identity. The raw index is supplied per module (the identifier runs once
-- per module, resetting the counter), so it is paired with the declaring 'ModuleName' to be globally
-- unique: the type-level environment and a cross-module SCC check both hold generics from several
-- modules at once, and a bare per-module index would conflate two modules' parameters that share one.
data GenericId = GenericId ModuleName Int
  deriving stock (Eq, Ord, Show)

-- | The reserved (synthetic) module name under which the type checker mints fresh /inference/
-- variables (metavariables) during generic-argument inference. It can never collide with a real
-- declaration's 'GenericId' because no user module may be named this (the angle brackets are not a
-- legal module-name character), and metavariables are always substituted away before a type leaves
-- the inference site, so this name never reaches the IR.
inferenceModuleName :: ModuleName
inferenceModuleName = ModuleName "<infer>"

-- | On the IR wire a generic is identified by its raw index only. Every schema belongs to a single
-- declaration, so within one callable the index is already unambiguous; the declaring module is
-- compiler-internal disambiguation the runtime never needs. The @{"$generic": id}@ sentinel and a
-- callable's @genericBindings@ both serialize through this, so they always agree.
instance ToJSON GenericId where
  toJSON (GenericId _ index) = toJSON index

newtype LocalVariableId = LocalVariableId Int
  deriving stock (Eq, Ord, Show)

data VariableResolution where
  VariableResolutionLocalVariable :: LocalVariableId -> VariableResolution
  VariableResolutionQualifiedName :: QualifiedName -> VariableResolution
  deriving stock (Eq, Ord, Show)

data TypeResolution where
  TypeResolutionGeneric :: GenericId -> TypeResolution
  TypeResolutionQualifiedName :: QualifiedName -> TypeResolution
  deriving stock (Eq, Ord, Show)
