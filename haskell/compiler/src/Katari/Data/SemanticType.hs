module Katari.Data.SemanticType where

import Data.Map (Map)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)

data FieldInfomation where
  FieldInfomation ::
    { name :: Text,
      optional :: Bool
    } ->
    FieldInfomation
  deriving (Eq, Ord, Show)

data SemanticTypeBase where
  SemanticTypeBaseNever :: SemanticTypeBase
  SemanticTypeBaseUnknown :: SemanticTypeBase
  SemanticTypeBaseNull :: SemanticTypeBase
  SemanticTypeBaseInteger :: SemanticTypeBase
  SemanticTypeBaseNumber :: SemanticTypeBase
  SemanticTypeBaseString :: SemanticTypeBase
  SemanticTypeBaseBoolean :: SemanticTypeBase
  SemanticTypeBaseFile :: SemanticTypeBase
  SemanticTypeBaseAgent :: SemanticTypeBase
  SemanticTypeBaseArray :: SemanticType -> SemanticTypeBase
  SemanticTypeBaseTuple :: List SemanticType -> SemanticTypeBase
  SemanticTypeBaseData :: QualifiedName -> Map GenericId SemanticGenericArgument -> SemanticTypeBase
  SemanticTypeBaseObject :: Map Text FieldInfomation -> SemanticTypeBase
  SemanticTypeBaseRecord :: SemanticType -> SemanticTypeBase
  SemanticTypeBaseGeneric :: GenericId -> SemanticTypeBase
  deriving (Eq, Ord, Show)

-- | Coeffect: Public (default) <: Private
--   Public values cannot assign to agent parameters with private coeffects.
--   let x : number of public = secret -- Error
--   let y : number of private = non_secret -- OK
data SemanticCoeffect where
  SemanticCoeffectPublic :: SemanticCoeffect -- Public Value (default)
  SemanticCoeffectPrivate :: SemanticCoeffect -- Private Value
  SemanticCoeffectUnion :: SemanticCoeffect -> SemanticCoeffect -> SemanticCoeffect -- Union of coeffects
  SemanticCoeffectGeneric :: GenericId -> SemanticCoeffect -- Generic coeffect
  deriving (Eq, Ord, Show)

data SemanticEffect where
  SemanticEffectPure :: SemanticEffect
  SemanticEffectAny :: SemanticEffect
  SemanticEffectRequest :: QualifiedName -> Map GenericId SemanticGenericArgument -> SemanticEffect
  SemanticEffectUnion :: SemanticEffect -> SemanticEffect -> SemanticEffect
  SemanticEffectGeneric :: GenericId -> SemanticEffect
  deriving (Eq, Ord, Show)

-- | Expected syntax : type of coeffect
data SemanticType where
  SemanticType :: SemanticTypeBase -> SemanticCoeffect -> SemanticType
  deriving (Eq, Ord, Show)

data SemanticGenericArgument where
  SemanticGenericArgumentType :: SemanticType -> SemanticGenericArgument
  SemanticGenericArgumentEffect :: SemanticEffect -> SemanticGenericArgument
  SemanticGenericArgumentCoeffect :: SemanticCoeffect -> SemanticGenericArgument
  deriving (Eq, Ord, Show)
