-- | The normalized (internal) type representation and its pure constructors.
--
-- This module is intentionally passive: it holds only the data definitions and trivial
-- constructors (bottom/top/never). All the logic that operates on these types — normalization,
-- union/intersection, subtyping, substitution, attribute push-down and denormalization — lives in
-- "Katari.Typechecker.Normalizer", together with the 'Normalizer' monad and its environment.
module Katari.Data.NormalizedType where

import Data.Map (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)

-- | NOTE: Bottom & Top types
-- Bottom ... never of public
-- Top ... unknown of private  <--  unknown of public is not top
data NormalizedType where
  NormalizedType :: {baseType :: NormalizedBaseType, generics :: Set GenericId, attribute :: NormalizedAttribute} -> NormalizedType
  deriving (Eq, Ord, Show)

data NormalizedBaseType where
  NormalizedBaseTypeUnknown :: NormalizedBaseType
  NormalizedBaseTypeLayered :: LayeredType -> NormalizedBaseType
  deriving (Eq, Ord, Show)

-- | An absent layer ('Nothing') is the bottom of that layer's own lattice: the identity of the
-- join and absorbing for the meet.
data LayeredType where
  LayeredType ::
    { nullLayer :: Bool,
      numberLayer :: NumberSlot,
      stringLayer :: Bool,
      booleanLayer :: Bool,
      fileLayer :: Bool,
      functionLayer :: Maybe NormalizedFunction,
      -- tuple, array
      sequenceLayer :: Maybe NormalizedSequence,
      -- object, record
      objectLayer :: Maybe NormalizedObject,
      dataLayer :: Map QualifiedName (Map Text NormalizedGenericArgument)
    } ->
    LayeredType
  deriving (Eq, Ord, Show)

data NumberSlot where
  NumberSlotAbsent :: NumberSlot
  NumberSlotInteger :: NumberSlot
  NumberSlotNumber :: NumberSlot
  deriving (Eq, Ord, Show)

data NormalizedFunction where
  NormalizedFunction ::
    { argumentType :: NormalizedType,
      returnType :: NormalizedType,
      effect :: NormalizedEffect
    } ->
    NormalizedFunction
  deriving (Eq, Ord, Show)

data NormalizedSequence where
  NormalizedSequence ::
    { items :: List NormalizedType,
      -- NOTE: Type of ANY further elements (the array tail).
      rest :: NormalizedType
    } ->
    NormalizedSequence
  deriving (Eq, Ord, Show)

data NormalizedObject where
  NormalizedObject ::
    { fields :: Map Text NormalizedFieldInformation,
      rest :: NormalizedType -- NOTE: Type of ANY other fields
    } ->
    NormalizedObject
  deriving (Eq, Ord, Show)

data NormalizedFieldInformation where
  NormalizedFieldInformation ::
    { normalizedType :: NormalizedType,
      optional :: Bool
    } ->
    NormalizedFieldInformation
  deriving (Eq, Ord, Show)

data NormalizedGenericArgument where
  NormalizedGenericArgumentType :: NormalizedType -> NormalizedGenericArgument
  NormalizedGenericArgumentEffect :: NormalizedEffect -> NormalizedGenericArgument
  NormalizedGenericArgumentAttribute :: NormalizedAttribute -> NormalizedGenericArgument
  deriving (Eq, Ord, Show)

data NormalizedEffect where
  NormalizedEffectAny :: NormalizedEffect
  NormalizedEffectRow :: EffectRow -> NormalizedEffect
  deriving (Eq, Ord, Show)

data EffectRow where
  EffectRow ::
    { request :: Map QualifiedName (Map Text NormalizedGenericArgument),
      generic :: Set GenericId,
      shadowed :: Set QualifiedName
    } ->
    EffectRow
  deriving (Eq, Ord, Show)

data NormalizedAttribute where
  NormalizedAttribute ::
    { private :: Bool,
      generic :: Set GenericId
    } ->
    NormalizedAttribute
  deriving (Eq, Ord, Show)

kindOf :: NormalizedGenericArgument -> Text
kindOf genericArgument = case genericArgument of
  NormalizedGenericArgumentType _ -> "type"
  NormalizedGenericArgumentEffect _ -> "effect"
  NormalizedGenericArgumentAttribute _ -> "attribute"

neverLayer :: LayeredType
neverLayer =
  LayeredType
    { nullLayer = False,
      numberLayer = NumberSlotAbsent,
      stringLayer = False,
      booleanLayer = False,
      fileLayer = False,
      functionLayer = Nothing,
      sequenceLayer = Nothing,
      objectLayer = Nothing,
      dataLayer = mempty
    }

bottomType :: NormalizedType
bottomType = NormalizedType {baseType = NormalizedBaseTypeLayered neverLayer, generics = Set.empty, attribute = bottomAttribute}

bottomAttribute :: NormalizedAttribute
bottomAttribute = NormalizedAttribute {private = False, generic = Set.empty}

bottomEffect :: NormalizedEffect
bottomEffect = NormalizedEffectRow $ EffectRow {request = mempty, generic = mempty, shadowed = mempty}

topType :: NormalizedType
topType = NormalizedType {baseType = NormalizedBaseTypeUnknown, generics = Set.empty, attribute = topAttribute}

topAttribute :: NormalizedAttribute
topAttribute = NormalizedAttribute {private = True, generic = Set.empty}

topEffect :: NormalizedEffect
topEffect = NormalizedEffectAny
