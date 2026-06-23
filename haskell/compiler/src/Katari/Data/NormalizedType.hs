-- | The normalized (internal) type representation and its pure constructors.
--
-- This module is intentionally passive: it holds only the data definitions and trivial
-- constructors (bottom/top/never). All the logic that operates on these types — normalization,
-- union/intersection, subtyping, substitution, attribute push-down and denormalization — lives in
-- "Katari.Typechecker.Normalizer", together with the 'Normalizer' monad and its environment.
module Katari.Data.NormalizedType where

import Data.Map (Map)
import Data.Map qualified as Map
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
    -- | The boolean values this type admits. @boolean@ is @{False, True}@; a boolean literal is a
    -- singleton, so @true@ / @false@ are distinguishable (their join is @boolean@). This is the only
    -- finitely-enumerable primitive, which is why a @true@ / @false@ pattern can contribute to match
    -- exhaustiveness while an @integer@ literal cannot.
    booleanLayer :: Set Bool,
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

-- | A sequence: a fixed positional prefix ('items') plus the type of every /further/ position
-- ('rest'). 'rest' reads as "if a position past the prefix exists it has this type; it may also be
-- absent" — absence is not null. A fixed-length tuple has @rest = never@ (no further positions); a
-- homogeneous @array[T]@ has @items = []@ and @rest = T@. The @never@ vs @T@ in the tail is what keeps
-- @array[T] </: [T]@ (an array cannot stand in for a fixed-length tuple) while allowing @[T] <:
-- array[T]@. Reading a position is the caller's concern: iteration yields @⋃items ∪ rest@ (no null),
-- while an out-of-range index would union @null@ in.
data NormalizedSequence = NormalizedSequence
  { items :: List NormalizedType,
    rest :: NormalizedType
  }
  deriving (Eq, Ord, Show)

-- | An object: named 'fields' plus the type of every other key ('rest'), with the same "present then
-- this type, possibly absent" reading as a sequence's 'rest'. A fixed object literal keeps @rest =
-- unknown@ (open — width subtyping ignores undeclared keys); a homogeneous @record[T]@ has @fields =
-- {}@ and @rest = T@. Reading an undeclared key unions @null@ in (it may be absent).
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

-- | An effect has two independent parts: its /request/ part ('requests' — the ordinary effects a value
-- may perform, possibly @all@) and its /escape/ channels ('exits' / 'continues' — the internal global
-- escapes @return@ / @break@ / @next@ ride on). The escape channels are kept orthogonal to the request
-- part /on purpose/: @all@ (top) absorbs requests but must never absorb an escape, because an escape's
-- value type has to survive (it is discharged and checked at the boundary it names — see 'BoundaryId').
data NormalizedEffect = NormalizedEffect
  { requests :: RequestEffect,
    -- | @EXIT(id, T)@ entries: a @return@ (target = agent), a @break@ (target = handler) or a @for@
    -- @break@ (target = for). The value type @T@ is covariant. Discharged (removed) at the boundary whose
    -- 'BoundaryId' it names; a concrete entry surviving an agent boundary is a misplaced / escaping jump.
    exits :: Map BoundaryId NormalizedType,
    -- | @CONTINUE(id, T)@ entries: a @next@ (target = handler resume) or a @for@ @next@ (target = for).
    -- Covariant @T@. Discharged at the boundary it names.
    continues :: Map BoundaryId NormalizedType
  }
  deriving (Eq, Ord, Show)

-- | The request part of an effect: either @all@ (the top effect) or a concrete row.
data RequestEffect where
  RequestEffectAny :: RequestEffect
  RequestEffectRow :: EffectRow -> RequestEffect
  deriving (Eq, Ord, Show)

-- | An effect's request part is the union of its concrete @request@s and its @tails@. Each tail maps an
-- effect-generic variable to the request names removed from it (its "lacks" set): @(E, lacks)@
-- denotes @E@ with every request in @lacks@ overridden, recording the @{...E, req}@ overrides.
data EffectRow = EffectRow
  { request :: Map QualifiedName (Map Text NormalizedKindedType),
    tails :: Map GenericId (Set QualifiedName)
  }
  deriving (Eq, Ord, Show)

-- | A fresh, per-walk opaque identifier for a control-flow boundary (an agent / @for@ / request
-- handler). The internal escape effects ('exits' / 'continues') are keyed by it, and the boundary
-- discharges the entries naming its own id. Never serialized: escapes are discharged before any public
-- scheme, so ids never cross a single agent's type-check walk.
newtype BoundaryId = BoundaryId Int
  deriving stock (Eq, Ord, Show)

-- | An effect with the given request part and no escapes.
fromRequestEffect :: RequestEffect -> NormalizedEffect
fromRequestEffect requestEffect = NormalizedEffect {requests = requestEffect, exits = mempty, continues = mempty}

-- | An effect that is exactly one concrete request row, with no escapes.
effectRow :: EffectRow -> NormalizedEffect
effectRow = fromRequestEffect . RequestEffectRow

-- | The @all@ effect with no escapes.
anyEffect :: NormalizedEffect
anyEffect = fromRequestEffect RequestEffectAny

-- | The empty request row (no requests, no tails).
emptyEffectRow :: EffectRow
emptyEffectRow = EffectRow {request = mempty, tails = mempty}

-- | An effect carrying a single @EXIT(id, T)@ escape (and nothing else).
exitEffect :: BoundaryId -> NormalizedType -> NormalizedEffect
exitEffect boundaryId valueType = (effectRow emptyEffectRow) {exits = Map.singleton boundaryId valueType}

-- | An effect carrying a single @CONTINUE(id, T)@ escape (and nothing else).
continueEffect :: BoundaryId -> NormalizedType -> NormalizedEffect
continueEffect boundaryId valueType = (effectRow emptyEffectRow) {continues = Map.singleton boundaryId valueType}

-- | Whether an effect carries any concrete escape entry. The leak check at an agent boundary: after the
-- agent discharges its own escapes, any survivor is a misplaced / escaping jump.
hasConcreteEscape :: NormalizedEffect -> Bool
hasConcreteEscape effect = not (Map.null effect.exits && Map.null effect.continues)

-- | Discharge a boundary's own @EXIT(id)@: its value type (bottom if it never fired) and the effect with
-- that entry removed. Pure because each channel holds at most one entry per id.
splitExit :: BoundaryId -> NormalizedEffect -> (NormalizedType, NormalizedEffect)
splitExit boundaryId effect =
  (Map.findWithDefault bottomType boundaryId effect.exits, effect {exits = Map.delete boundaryId effect.exits})

-- | Discharge a boundary's own @CONTINUE(id)@, as 'splitExit'.
splitContinue :: BoundaryId -> NormalizedEffect -> (NormalizedType, NormalizedEffect)
splitContinue boundaryId effect =
  (Map.findWithDefault bottomType boundaryId effect.continues, effect {continues = Map.delete boundaryId effect.continues})

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
      booleanLayer = Set.empty,
      fileLayer = False,
      functionLayer = Nothing,
      sequenceLayer = Nothing,
      objectLayer = Nothing,
      dataLayer = mempty
    }

bottomType :: NormalizedType
bottomType = NormalizedType {baseType = NormalizedBaseTypeLayered neverLayer, generics = Set.empty, attribute = bottomAttribute}

-- | A placeholder constructor object (no fields), for a 'DataInformation' built before its real
-- constructor is known — the env-build's intermediate environment, which consults only arity.
placeholderConstructor :: NormalizedObject
placeholderConstructor = NormalizedObject {fields = mempty, rest = bottomType}

bottomAttribute :: NormalizedAttribute
bottomAttribute = NormalizedAttribute {private = False, generic = Set.empty}

bottomEffect :: NormalizedEffect
bottomEffect = effectRow emptyEffectRow

topType :: NormalizedType
topType = NormalizedType {baseType = NormalizedBaseTypeUnknown, generics = Set.empty, attribute = topAttribute}

topAttribute :: NormalizedAttribute
topAttribute = NormalizedAttribute {private = True, generic = Set.empty}

topEffect :: NormalizedEffect
topEffect = anyEffect

-- | Union @null@ into a type (set its null layer). On @unknown@ (already the top, which subsumes
-- null) this is the identity. Used where a read may be absent — an undeclared object key, a future
-- out-of-range index — so the surface @null@ is added at the read site, not baked into a container's
-- element type.
orNull :: NormalizedType -> NormalizedType
orNull normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeUnknown -> normalizedType
  NormalizedBaseTypeLayered layer -> normalizedType {baseType = NormalizedBaseTypeLayered layer {nullLayer = True}}
