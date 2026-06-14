module Katari.Data.Id where

import Data.Aeson (FromJSON, ToJSON)
import Katari.Data.QualifiedName (QualifiedName)

newtype GenericId = GenericId Int
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype LocalVariableId = LocalVariableId Int
  deriving stock (Eq, Ord, Show)

data VariableResolution where
  VariableResolutionLocalVariable :: LocalVariableId -> VariableResolution
  VariableResolutionQualifiedName :: QualifiedName -> VariableResolution
  deriving stock (Eq, Ord, Show)

-- | Shared type for type, effect, and attribute resolution
data TypeResolution where
  TypeResolutionQualifiedName :: QualifiedName -> TypeResolution
  TypeResolutionGenericType :: GenericId -> TypeResolution -- [T]
  TypeResolutionGenericEffect :: GenericId -> TypeResolution -- [effect T]
  TypeResolutionGenericAttribute :: GenericId -> TypeResolution -- [attribute T]
  deriving stock (Eq, Ord, Show)
