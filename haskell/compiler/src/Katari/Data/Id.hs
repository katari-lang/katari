module Katari.Data.Id where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Katari.Data.QualifiedName (QualifiedName)

newtype GenericId where
  GenericsId :: Int -> GenericId
  deriving (Eq, Ord, Show)

instance ToJSON GenericId where
  toJSON (GenericsId n) = toJSON n

instance FromJSON GenericId where
  parseJSON = fmap GenericsId . parseJSON

newtype LocalVarId where
  LocalVarId :: Int -> LocalVarId
  deriving (Eq, Ord, Show)

data VariableResolution where
  VariableResolutionLocalVar :: LocalVarId -> VariableResolution
  VariableResolutionQualifiedName :: QualifiedName -> VariableResolution
  deriving (Eq, Ord, Show)

-- | Shared type for type, effect, and attribute resolution
data TypeResolution where
  TypeResolutionData :: QualifiedName -> TypeResolution
  TypeResolutionRequest :: QualifiedName -> TypeResolution
  TypeResolutionGenericType :: GenericId -> TypeResolution -- [T]
  TypeResolutionGenericEffect :: GenericId -> TypeResolution -- [effect T]
  TypeResolutionGenericAttribute :: GenericId -> TypeResolution -- [attribute T]
  deriving (Eq, Ord, Show)
