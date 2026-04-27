-- | Normalised type representation for the constraint solver.
--
-- 'NormalizedType' is the canonical form of a Katari type after eliminating
-- unions and applying the language's product-normalisation rule (see the
-- README): a tuple type @(0, string) | (1, integer)@ is *not* preserved as
-- a union of two distinct shapes. Instead it is normalised to
-- @(0 | 1, string | integer)@, accepting the loss of cross-component
-- correlation. This keeps subtyping decidable without dependent shapes.
--
-- Design constraints driving this representation:
--
--   * Unions never appear as a constructor here — they are decomposed into
--     contributions to each layer.
--   * @NTNever@ is *not* a separate constructor: the canonical empty type is
--     'NTLayered' 'emptyLayered' (every layer empty). Avoiding redundant
--     representations keeps equality decidable by structural comparison.
--   * Each layer uses an empty 'Set' / 'Map' / dedicated @Absent@
--     constructor to express "no values here", rather than wrapping in
--     'Maybe'. This too is for canonicality.
--
-- @'NTUnknown'@ is the lattice top. Although it could in principle be
-- expressed as a layered value populating every layer with its widest slot,
-- doing so would lose the polymorphism (e.g. @unknown@ accommodates @data@
-- types not yet in scope), so it is kept as a dedicated constructor.
module Katari.Typechecker.NormalizedType
  ( -- * Types
    NormalizedType (..),
    LayeredType (..),
    NumberSlot (..),
    StringSlot (..),
    ArraySlot (..),
    ObjectSlot (..),
    FunctionSignature (..),
    FunctionShape (..),

    -- * Helpers
    emptyLayered,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Typechecker.Identifier (TypeId, VariableId)

-- ---------------------------------------------------------------------------
-- NormalizedType
-- ---------------------------------------------------------------------------

-- | The canonical normal form of a Katari type. Equality is structural.
--
-- @NTLayered 'emptyLayered'@ is the canonical "never" / bottom type.
data NormalizedType
  = NTUnknown
  | NTLayered !LayeredType
  deriving (Eq, Show)

-- | One slot per "type family". A @NormalizedType@ is the sum (union) of
-- the contributions from every populated layer.
data LayeredType = LayeredType
  { -- | Numeric layer. Empty 'NumberLiterals' if no number values inhabit
    -- this type.
    numberLayer :: !NumberSlot,
    -- | String layer.
    stringLayer :: !StringSlot,
    -- | Boolean layer. Possible canonical states: @{}@, @{True}@, @{False}@,
    -- @{True, False}@. Note that @{True, False}@ is the same set as the
    -- full 'boolean' primitive — there is intentionally no separate
    -- @BooleanAny@ representation.
    booleanLayer :: !(Set Bool),
    -- | Whether @null@ is inhabited.
    nullLayer :: !Bool,
    -- | Function shapes keyed by signature (parameter labels). Empty map
    -- means no functions inhabit this type. Different label sets / arities
    -- coexist as separate entries.
    functionLayer :: !(Map FunctionSignature FunctionShape),
    -- | Array layer. 'ArrayAbsent' distinguishes "no array values" from
    -- @ArrayOf (NTLayered emptyLayered)@ (which permits the empty-array
    -- value @[]@).
    arrayLayer :: !ArraySlot,
    -- | Tuple layer keyed by arity. Absence from the map means no tuples
    -- of that arity inhabit this type. Per arity the per-position types
    -- are stored as a list.
    tupleLayer :: !(Map Int [NormalizedType]),
    -- | Set of @data@ type ids that inhabit this type. Empty means no
    -- @data@ values.
    dataLayer :: !(Set TypeId),
    -- | Structural object layer. 'ObjectAbsent' means "no object values"
    -- (distinguishable from "object with all-empty fields"). Per Katari's
    -- product-normalisation rule, all object shapes in a union collapse
    -- into a single shape: union → common fields, each field type unioned;
    -- intersection → all fields, common field types intersected.
    objectLayer :: !ObjectSlot
  }
  deriving (Eq, Show)

-- | Numeric slot. Canonical invariants:
--
--   * 'NumberLiterals' may be empty (= no number values) or may hold any
--     finite set of integer literals. It is never used to represent the
--     full 'integer' type — that is 'NumberInteger'.
--   * 'NumberInteger' is the entire @integer@ primitive (all integers).
--   * 'NumberNumber' is the entire @number@ primitive (subsumes
--     'NumberInteger' and floats / non-integer numbers).
data NumberSlot
  = NumberLiterals !(Set Integer)
  | NumberInteger
  | NumberNumber
  deriving (Eq, Show)

-- | String slot.
--
--   * @'StringLiterals' s@ — exactly the strings in @s@; @s@ may be empty
--     to indicate "no string values".
--   * 'StringAny' — the full 'string' primitive.
data StringSlot
  = StringLiterals !(Set Text)
  | StringAny
  deriving (Eq, Show)

-- | Array slot.
--
--   * 'ArrayAbsent' — no array values inhabit this type.
--   * @'ArrayOf' t@ — arrays whose element type is @t@. Note that
--     @'ArrayOf' (NTLayered emptyLayered)@ is *not* equivalent to
--     'ArrayAbsent': it admits the empty array value @[]@.
data ArraySlot
  = ArrayAbsent
  | ArrayOf !NormalizedType
  deriving (Eq, Show)

-- | Object slot.
--
--   * 'ObjectAbsent' — no object values inhabit this type.
--   * @'ObjectOf' fs@ — values that have at least the fields in @fs@.
--     Unspecified fields are conceptually filled with 'NTUnknown', so
--     'ObjectAbsent' is *not* the same as @'ObjectOf' Map.empty@.
data ObjectSlot
  = ObjectAbsent
  | ObjectOf !(Map Text NormalizedType)
  deriving (Eq, Show)

-- | Function signature key. Parameters are identified by their labels in
-- declaration order; two functions with different label sequences are
-- considered different shapes.
newtype FunctionSignature = FunctionSignature [Text]
  deriving (Eq, Ord, Show)

-- | Concrete function shape. The 'parameterTypes' list aligns positionally
-- with the labels of the corresponding 'FunctionSignature'.
data FunctionShape = FunctionShape
  { parameterTypes :: ![NormalizedType],
    returnType :: !NormalizedType,
    effects :: !(Set VariableId)
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | The "all empty" 'LayeredType'. @'NTLayered' 'emptyLayered'@ is the
-- canonical bottom (never) type.
emptyLayered :: LayeredType
emptyLayered =
  LayeredType
    { numberLayer = NumberLiterals Set.empty,
      stringLayer = StringLiterals Set.empty,
      booleanLayer = Set.empty,
      nullLayer = False,
      functionLayer = Map.empty,
      arrayLayer = ArrayAbsent,
      tupleLayer = Map.empty,
      dataLayer = Set.empty,
      objectLayer = ObjectAbsent
    }
