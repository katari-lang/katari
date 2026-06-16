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
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)

-- | NOTE: Bottom & Top types
-- Bottom ... never of public
-- Top ... unknown of private  <--  unknown of public is not top
data NormalizedType = NormalizedType
  { baseType :: NormalizedBaseType,
    generics :: Set GenericId,
    attribute :: NormalizedAttribute
  }
  deriving (Eq, Ord, Show)

data NormalizedBaseType where
  NormalizedBaseTypeUnknown :: NormalizedBaseType
  NormalizedBaseTypeLayered :: LayeredType -> NormalizedBaseType
  deriving (Eq, Ord, Show)

-- | An absent layer ('Nothing') is the bottom of that layer's own lattice: the identity of the
-- join and absorbing for the meet.
data LayeredType = LayeredType
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
    dataLayer :: Map QualifiedName (Map Text NormalizedKindedType)
  }
  deriving (Eq, Ord, Show)

data NumberSlot where
  NumberSlotAbsent :: NumberSlot
  NumberSlotInteger :: NumberSlot
  NumberSlotNumber :: NumberSlot
  deriving (Eq, Ord, Show)

data NormalizedFunction = NormalizedFunction
  { argumentType :: NormalizedType,
    returnType :: NormalizedType,
    effect :: NormalizedEffect
  }
  deriving (Eq, Ord, Show)

-- | A sequence: a fixed positional prefix ('items') plus the type of every further position
-- ('rest'). A read past the prefix yields 'rest', and an out-of-range read is null, so a fixed-length
-- tuple has @rest = null@ while a homogeneous @array[T]@ has @items = []@ and @rest = T | null@. The
-- null in the array tail is what keeps @array[T] </: [T]@ (an array cannot be a fixed-length tuple)
-- while allowing @[T] <: array[T]@.
data NormalizedSequence = NormalizedSequence
  { items :: List NormalizedType,
    rest :: NormalizedType
  }
  deriving (Eq, Ord, Show)

-- | An object: named 'fields' plus the type of every other key ('rest'). A fixed object literal keeps
-- @rest = unknown@ (open — width subtyping ignores undeclared keys); a homogeneous @record[T]@ has
-- @fields = {}@ and @rest = T | null@ (an absent key reads as null).
data NormalizedObject = NormalizedObject
  { fields :: Map Text NormalizedFieldInformation,
    rest :: NormalizedType
  }
  deriving (Eq, Ord, Show)

data NormalizedFieldInformation = NormalizedFieldInformation
  { normalizedType :: NormalizedType,
    optional :: Bool
  }
  deriving (Eq, Ord, Show)

data NormalizedKindedType where
  NormalizedKindedTypeType :: NormalizedType -> NormalizedKindedType
  NormalizedKindedTypeEffect :: NormalizedEffect -> NormalizedKindedType
  NormalizedKindedTypeAttribute :: NormalizedAttribute -> NormalizedKindedType
  deriving (Eq, Ord, Show)

data NormalizedEffect where
  NormalizedEffectAny :: NormalizedEffect
  NormalizedEffectRow :: EffectRow -> NormalizedEffect
  deriving (Eq, Ord, Show)

-- | An effect is the union of its concrete @request@s and its @tails@. Each tail maps an
-- effect-generic variable to the request names removed from it (its "lacks" set): @(E, lacks)@
-- denotes @E@ with every request in @lacks@ overridden, recording the @{...E, req}@ overrides.
data EffectRow = EffectRow
  { request :: Map QualifiedName (Map Text NormalizedKindedType),
    tails :: Map GenericId (Set QualifiedName)
  }
  deriving (Eq, Ord, Show)

data NormalizedAttribute = NormalizedAttribute
  { private :: Bool,
    generic :: Set GenericId
  }
  deriving (Eq, Ord, Show)

kindOf :: NormalizedKindedType -> GenericKind
kindOf genericArgument = case genericArgument of
  NormalizedKindedTypeType _ -> GenericKindType
  NormalizedKindedTypeEffect _ -> GenericKindEffect
  NormalizedKindedTypeAttribute _ -> GenericKindAttribute

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
bottomEffect = NormalizedEffectRow $ EffectRow {request = mempty, tails = mempty}

topType :: NormalizedType
topType = NormalizedType {baseType = NormalizedBaseTypeUnknown, generics = Set.empty, attribute = topAttribute}

topAttribute :: NormalizedAttribute
topAttribute = NormalizedAttribute {private = True, generic = Set.empty}

topEffect :: NormalizedEffect
topEffect = NormalizedEffectAny
