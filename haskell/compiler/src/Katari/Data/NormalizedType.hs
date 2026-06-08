module Katari.Data.NormalizedType where

import Data.Map (Map)
import Data.Set (Set)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.SemanticType (SemanticCoeffect, SemanticEffect, SemanticType, SemanticTypeBase (..))

data NormalizedType where
  NormalizedType :: NormalizedTypeBase -> NormalizedCoeffect -> NormalizedType
  deriving (Eq, Ord, Show)

data NormalizedTypeBase where
  NormalizedTypeUnknown :: NormalizedTypeBase
  NormalizedTypeLayerd :: LayeredType -> NormalizedTypeBase
  deriving (Eq, Ord, Show)

data LayeredType where
  LayeredType ::
    { nullLayer :: Bool,
      numberLayer :: NumberSlot,
      stringLayer :: Bool,
      booleanLayer :: Bool,
      fileLayer :: Bool,
      functionLayer :: FunctionSlot,
      -- tuple, array
      sequenceLayer :: SequenceSlot,
      -- object, record
      mapLayer :: MapSlot,
      dataLayer :: Map QualifiedName (Map GenericId NormalizedGenericArg),
      genericLayer :: Set GenericId
    } ->
    LayeredType
  deriving (Eq, Ord, Show)

data NumberSlot where
  NumberSlotAbsent :: NumberSlot
  NumberSlotInteger :: NumberSlot
  NumberSlotNumber :: NumberSlot
  deriving (Eq, Ord, Show)

data FunctionSlot where
  FunctionSlotAbsent :: FunctionSlot
  FunctionSlotOf :: NormalizedType -> NormalizedType -> NormalizedEffect -> FunctionSlot
  deriving (Eq, Ord, Show)

data SequenceSlot where
  SequenceSlotAbsent :: SequenceSlot
  SequenceSlotTuple :: (List NormalizedType) -> SequenceSlot
  SequenceSlotArray :: NormalizedType -> SequenceSlot
  deriving (Eq, Ord, Show)

data MapSlot where
  MapSlotAbsent :: MapSlot
  MapSlotObject :: Map Text NormalizedFieldInformation -> MapSlot
  MapSlotRecord :: NormalizedType -> MapSlot
  deriving (Eq, Ord, Show)

data NormalizedFieldInformation where
  NormalizedFieldInformation ::
    { name :: Text,
      optional :: Bool
    } ->
    NormalizedFieldInformation
  deriving (Eq, Ord, Show)

data NormalizedGenericArg where
  NormalizedGenericArgType :: NormalizedType -> NormalizedGenericArg
  NormalizedGenericArgEffect :: NormalizedEffect -> NormalizedGenericArg
  NormalizedGenericArgCoeffect :: NormalizedCoeffect -> NormalizedGenericArg
  deriving (Eq, Ord, Show)

data NormalizedEffect where
  NormalizedEffectAny :: NormalizedEffect
  NormalizedEffectRow :: EffectRow -> NormalizedEffect
  deriving (Eq, Ord, Show)

data EffectRow where
  EffectRow ::
    { request :: Map QualifiedName (Map GenericId NormalizedGenericArg),
      generic :: Set GenericId,
      -- Excluded effects from the generic effects
      shadowed :: Set QualifiedName
    } ->
    EffectRow
  deriving (Eq, Ord, Show)

data NormalizedCoeffect where
  NormalizedCoeffect ::
    { private :: Bool,
      generic :: Set GenericId
    } ->
    NormalizedCoeffect
  deriving (Eq, Ord, Show)

normalizedNeverTypeBase :: NormalizedTypeBase
normalizedNeverTypeBase =
  NormalizedTypeLayerd $
    LayeredType
      { nullLayer = False,
        numberLayer = NumberSlotAbsent,
        stringLayer = False,
        booleanLayer = False,
        fileLayer = False,
        functionLayer = FunctionSlotAbsent,
        sequenceLayer = SequenceSlotAbsent,
        mapLayer = MapSlotAbsent,
        dataLayer = mempty,
        genericLayer = mempty
      }

normalizeType :: SemanticType -> NormalizedType
normalizeType = undefined

normalizeTypeBase :: SemanticTypeBase -> NormalizedTypeBase
normalizeTypeBase semanticTypeBase = undefined

normalizeCoeffect :: SemanticCoeffect -> NormalizedCoeffect
normalizeCoeffect = undefined

normalizeEffect :: SemanticEffect -> NormalizedEffect
normalizeEffect = undefined
