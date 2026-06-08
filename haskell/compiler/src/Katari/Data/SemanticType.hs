module Katari.Data.SemanticType where

import Data.Map (Map)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)

data FieldInfomation where
  FieldInfomation ::
    { semanticType :: SemanticType,
      optional :: Bool
    } ->
    FieldInfomation
  deriving (Eq, Ord, Show)

data SemanticType where
  SemanticTypeNever :: SemanticType
  SemanticTypeUnknown :: SemanticType
  SemanticTypeNull :: SemanticType
  SemanticTypeInteger :: SemanticType
  SemanticTypeNumber :: SemanticType
  SemanticTypeString :: SemanticType
  SemanticTypeBoolean :: SemanticType
  SemanticTypeFile :: SemanticType
  SemanticTypeAgent :: SemanticType -> SemanticType -> SemanticEffect -> SemanticType
  SemanticTypeArray :: SemanticType -> SemanticType
  SemanticTypeTuple :: List SemanticType -> SemanticType
  SemanticTypeData :: QualifiedName -> Map Text SemanticGenericArgument -> SemanticType
  SemanticTypeObject :: Map Text FieldInfomation -> SemanticType
  SemanticTypeRecord :: SemanticType -> SemanticType
  SemanticTypeUnion :: List SemanticType -> SemanticType
  SemanticTypeGeneric :: GenericId -> SemanticType
  SemanticTypeAttribute :: SemanticType -> SemanticAttribute -> SemanticType
  deriving (Eq, Ord, Show)

-- | Attribute: Public (default) <: Private
--   Public values cannot assign to agent parameters with private attributes.
--   let x : number of public = secret -- Error
--   let y : number of private = non_secret -- OK
data SemanticAttribute where
  SemanticAttributePublic :: SemanticAttribute -- Public Value (default)
  SemanticAttributePrivate :: SemanticAttribute -- Private Value
  SemanticAttributeUnion :: List SemanticAttribute -> SemanticAttribute -- Union of attributes
  SemanticAttributeGeneric :: GenericId -> SemanticAttribute -- Generic attribute
  deriving (Eq, Ord, Show)

data SemanticEffect where
  SemanticEffectPure :: SemanticEffect
  SemanticEffectAny :: SemanticEffect
  SemanticEffectRequest :: QualifiedName -> Map Text SemanticGenericArgument -> SemanticEffect
  SemanticEffectUnion :: List SemanticEffect -> SemanticEffect
  -- | {...(eff expr), req1[generics], req2[generics]}
  -- Union:  req1[int] | req1[string] ~> req1[int | string]  (if covariant)
  -- Overwrite: {...req1[int], req1[string]} ~> req1[string]
  SemanticEffectOverwrite :: SemanticEffect -> List (QualifiedName, Map Text SemanticGenericArgument) -> SemanticEffect
  SemanticEffectGeneric :: GenericId -> SemanticEffect
  deriving (Eq, Ord, Show)

data SemanticGenericArgument where
  SemanticGenericArgumentType :: SemanticType -> SemanticGenericArgument
  SemanticGenericArgumentEffect :: SemanticEffect -> SemanticGenericArgument
  SemanticGenericArgumentAttribute :: SemanticAttribute -> SemanticGenericArgument
  deriving (Eq, Ord, Show)
