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
--     'NormalizedTypeLayered' 'emptyLayered' (every layer empty). Avoiding redundant
--     representations keeps equality decidable by structural comparison.
--   * Each layer uses an empty 'Set' / 'Map' / dedicated @Absent@
--     constructor to express "no values here", rather than wrapping in
--     'Maybe'. This too is for canonicality.
--
-- @'NormalizedTypeUnknown'@ is the lattice top. Although it could in principle be
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
    FunctionSlot (..),
    FunctionShape (..),

    -- * Helpers
    emptyLayered,
    isNeverNT,
    isUnknownNT,

    -- * Conversion to SemanticType
    denormalise,

    -- * Conversion from SemanticType
    normaliseSemantic,

    -- * Lattice operations
    unionNT,
    intersectNT,
    subtypeNT,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.SemanticType (Resolved, SemanticRequest (..), SemanticType (..))
import Katari.Typechecker.Identifier (RequestId, TypeId)

-- ---------------------------------------------------------------------------
-- NormalizedType
-- ---------------------------------------------------------------------------

-- | The canonical normal form of a Katari type. Equality is structural.
--
-- @NormalizedTypeLayered 'emptyLayered'@ is the canonical "never" / bottom type.
data NormalizedType where
  NormalizedTypeUnknown :: NormalizedType
  NormalizedTypeLayered :: !LayeredType -> NormalizedType
  deriving (Eq, Show)

-- | One slot per "type family". A @NormalizedType@ is the sum (union) of
-- the contributions from every populated layer.
data LayeredType = LayeredType
  { -- | Numeric layer. Empty 'NumberSlotLiterals' if no number values inhabit
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
    -- | Function layer. 'FunctionSlotAbsent' means no function values inhabit
    -- this type; 'FunctionSlotOf' carries a single function shape (with named
    -- parameters). Per Katari's product-normalisation rule, multiple
    -- function shapes in a union collapse into one shape: union → label
    -- union with each common label's type intersected; intersection →
    -- label intersection with each common label's type unioned.
    functionLayer :: !FunctionSlot,
    -- | Array layer. 'ArraySlotAbsent' distinguishes "no array values" from
    -- @ArraySlotOf (NormalizedTypeLayered emptyLayered)@ (which permits the empty-array
    -- value @[]@).
    arrayLayer :: !ArraySlot,
    -- | Tuple layer keyed by arity. Absence from the map means no tuples
    -- of that arity inhabit this type. Per arity the per-position types
    -- are stored as a list.
    tupleLayer :: !(Map Int [NormalizedType]),
    -- | Set of @data@ type ids that inhabit this type. Empty means no
    -- @data@ values.
    dataLayer :: !(Set TypeId),
    -- | Structural object layer. 'ObjectSlotAbsent' means "no object values"
    -- (distinguishable from "object with all-empty fields"). Per Katari's
    -- product-normalisation rule, all object shapes in a union collapse
    -- into a single shape: union → common fields, each field type unioned;
    -- intersection → all fields, common field types intersected.
    objectLayer :: !ObjectSlot
  }
  deriving (Eq, Show)

-- | Numeric slot. Canonical invariants:
--
--   * 'NumberSlotLiterals' may be empty (= no number values) or may hold any
--     finite set of integer literals. It is never used to represent the
--     full 'integer' type — that is 'NumberSlotInteger'.
--   * 'NumberSlotInteger' is the entire @integer@ primitive (all integers).
--   * 'NumberSlotNumber' is the entire @number@ primitive (subsumes
--     'NumberSlotInteger' and floats / non-integer numbers).
data NumberSlot where
  NumberSlotLiterals :: !(Set Integer) -> NumberSlot
  NumberSlotInteger :: NumberSlot
  NumberSlotNumber :: NumberSlot
  deriving (Eq, Show)

-- | String slot.
--
--   * @'StringSlotLiterals' s@ — exactly the strings in @s@; @s@ may be empty
--     to indicate "no string values".
--   * 'StringSlotAny' — the full 'string' primitive.
data StringSlot where
  StringSlotLiterals :: !(Set Text) -> StringSlot
  StringSlotAny :: StringSlot
  deriving (Eq, Show)

-- | Array slot.
--
--   * 'ArraySlotAbsent' — no array values inhabit this type.
--   * @'ArraySlotOf' t@ — arrays whose element type is @t@. Note that
--     @'ArraySlotOf' (NormalizedTypeLayered emptyLayered)@ is *not* equivalent to
--     'ArraySlotAbsent': it admits the empty array value @[]@.
data ArraySlot where
  ArraySlotAbsent :: ArraySlot
  ArraySlotOf :: !NormalizedType -> ArraySlot
  deriving (Eq, Show)

-- | Object slot.
--
--   * 'ObjectSlotAbsent' — no object values inhabit this type.
--   * @'ObjectSlotOf' fs@ — values that have at least the fields in @fs@.
--     Unspecified fields are conceptually filled with 'NormalizedTypeUnknown', so
--     'ObjectSlotAbsent' is *not* the same as @'ObjectSlotOf' Map.empty@.
data ObjectSlot where
  ObjectSlotAbsent :: ObjectSlot
  ObjectSlotOf :: !(Map Text NormalizedType) -> ObjectSlot
  deriving (Eq, Show)

-- | Function layer.
--
--   * 'FunctionSlotAbsent' — no function values inhabit this type.
--   * @'FunctionSlotOf' shape@ — function values matching @shape@.
--
-- Multiple function shapes in a union are collapsed into a single shape via
-- the product-normalisation rule (label-set union with per-common-label
-- intersection of types).
data FunctionSlot where
  FunctionSlotAbsent :: FunctionSlot
  FunctionSlotOf :: !FunctionShape -> FunctionSlot
  deriving (Eq, Show)

-- | Concrete function shape. Parameters are keyed by their label (order is
-- not represented at this level).
data FunctionShape = FunctionShape
  { parameters :: !(Map Text NormalizedType),
    returnType :: !NormalizedType,
    requests :: !(Set RequestId)
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | The "all empty" 'LayeredType'. @'NormalizedTypeLayered' 'emptyLayered'@ is the
-- canonical bottom (never) type.
emptyLayered :: LayeredType
emptyLayered =
  LayeredType
    { numberLayer = NumberSlotLiterals Set.empty,
      stringLayer = StringSlotLiterals Set.empty,
      booleanLayer = Set.empty,
      nullLayer = False,
      functionLayer = FunctionSlotAbsent,
      arrayLayer = ArraySlotAbsent,
      tupleLayer = Map.empty,
      dataLayer = Set.empty,
      objectLayer = ObjectSlotAbsent
    }

-- ---------------------------------------------------------------------------
-- Denormalisation: NormalizedType -> SemanticType Resolved
-- ---------------------------------------------------------------------------

-- | Convert a 'NormalizedType' back into a 'SemanticType' 'Resolved' for
-- display / consumption by the AST. The output is canonical (it reflects the
-- product-normalisation rule applied in 'NormalizedType' — e.g. cross-component
-- correlation in tuple unions is not recovered).
--
-- Empty layered types collapse to 'SemanticTypeNever'; single-branch unions
-- collapse to the inner type; multi-branch unions are wrapped in
-- 'SemanticTypeUnion'.
denormalise :: NormalizedType -> SemanticType Resolved
denormalise = \case
  NormalizedTypeUnknown -> SemanticTypeUnknown
  NormalizedTypeLayered layered -> case denormaliseBranches layered of
    [] -> SemanticTypeNever
    [single] -> single
    branches -> SemanticTypeUnion branches

denormaliseBranches :: LayeredType -> [SemanticType Resolved]
denormaliseBranches LayeredType {..} =
  concat
    [ numberBranches numberLayer,
      stringBranches stringLayer,
      booleanBranches booleanLayer,
      nullBranches nullLayer,
      functionBranches functionLayer,
      arrayBranches arrayLayer,
      tupleBranches tupleLayer,
      dataBranches dataLayer,
      objectBranches objectLayer
    ]

numberBranches :: NumberSlot -> [SemanticType Resolved]
numberBranches = \case
  NumberSlotLiterals literals -> SemanticTypeLiteralInteger <$> Set.toList literals
  NumberSlotInteger -> [SemanticTypeInteger]
  NumberSlotNumber -> [SemanticTypeNumber]

stringBranches :: StringSlot -> [SemanticType Resolved]
stringBranches = \case
  StringSlotLiterals literals -> SemanticTypeLiteralString <$> Set.toList literals
  StringSlotAny -> [SemanticTypeString]

booleanBranches :: Set Bool -> [SemanticType Resolved]
booleanBranches values
  | values == Set.fromList [True, False] = [SemanticTypeBoolean]
  | otherwise = SemanticTypeLiteralBoolean <$> Set.toList values

nullBranches :: Bool -> [SemanticType Resolved]
nullBranches True = [SemanticTypeNull]
nullBranches False = []

functionBranches :: FunctionSlot -> [SemanticType Resolved]
functionBranches = \case
  FunctionSlotAbsent -> []
  FunctionSlotOf shape -> [makeFunction shape]
  where
    makeFunction FunctionShape {parameters, returnType, requests} =
      SemanticTypeFunction
        (Map.map denormalise parameters)
        (denormalise returnType)
        (SemanticRequest Set.empty requests)

arrayBranches :: ArraySlot -> [SemanticType Resolved]
arrayBranches = \case
  ArraySlotAbsent -> []
  ArraySlotOf elementType -> [SemanticTypeArray (denormalise elementType)]

tupleBranches :: Map Int [NormalizedType] -> [SemanticType Resolved]
tupleBranches = fmap (SemanticTypeTuple . fmap denormalise . snd) . Map.toList

dataBranches :: Set TypeId -> [SemanticType Resolved]
dataBranches = fmap SemanticTypeData . Set.toList

objectBranches :: ObjectSlot -> [SemanticType Resolved]
objectBranches = \case
  ObjectSlotAbsent -> []
  ObjectSlotOf fields -> [SemanticTypeObject (Map.map denormalise fields)]

-- ---------------------------------------------------------------------------
-- isNeverNT / isUnknownNT
-- ---------------------------------------------------------------------------

-- | Is this the bottom type? Equivalent to @NormalizedTypeLayered emptyLayered@.
isNeverNT :: NormalizedType -> Bool
isNeverNT = \case
  NormalizedTypeLayered layered -> isEmptyLayered layered
  _ -> False

-- | Is this the top type?
isUnknownNT :: NormalizedType -> Bool
isUnknownNT = \case
  NormalizedTypeUnknown -> True
  _ -> False

isEmptyLayered :: LayeredType -> Bool
isEmptyLayered LayeredType {..} =
  isEmptyNumber numberLayer
    && isEmptyString stringLayer
    && Set.null booleanLayer
    && not nullLayer
    && isEmptyFunction functionLayer
    && isEmptyArray arrayLayer
    && Map.null tupleLayer
    && Set.null dataLayer
    && isEmptyObject objectLayer

isEmptyNumber :: NumberSlot -> Bool
isEmptyNumber = \case
  NumberSlotLiterals s -> Set.null s
  _ -> False

isEmptyString :: StringSlot -> Bool
isEmptyString = \case
  StringSlotLiterals s -> Set.null s
  _ -> False

isEmptyArray :: ArraySlot -> Bool
isEmptyArray = \case
  ArraySlotAbsent -> True
  _ -> False

isEmptyFunction :: FunctionSlot -> Bool
isEmptyFunction = \case
  FunctionSlotAbsent -> True
  _ -> False

isEmptyObject :: ObjectSlot -> Bool
isEmptyObject = \case
  ObjectSlotAbsent -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Normalisation: SemanticType Resolved -> NormalizedType
-- ---------------------------------------------------------------------------

-- | Convert a fully-resolved 'SemanticType' (no unification variables) into
-- the canonical 'NormalizedType'. Inverse direction of 'denormalise', though
-- the round-trip is not the identity (the product-normalisation rule
-- collapses cross-component correlation in tuple unions).
normaliseSemantic :: SemanticType Resolved -> NormalizedType
normaliseSemantic = \case
  SemanticTypeUnknown -> NormalizedTypeUnknown
  SemanticTypeNever -> NormalizedTypeLayered emptyLayered
  SemanticTypeNull -> NormalizedTypeLayered emptyLayered {nullLayer = True}
  SemanticTypeBoolean ->
    NormalizedTypeLayered emptyLayered {booleanLayer = Set.fromList [True, False]}
  SemanticTypeInteger ->
    NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger}
  SemanticTypeNumber ->
    NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotNumber}
  SemanticTypeString ->
    NormalizedTypeLayered emptyLayered {stringLayer = StringSlotAny}
  SemanticTypeLiteralInteger value ->
    NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotLiterals (Set.singleton value)}
  SemanticTypeLiteralString value ->
    NormalizedTypeLayered emptyLayered {stringLayer = StringSlotLiterals (Set.singleton value)}
  SemanticTypeLiteralBoolean value ->
    NormalizedTypeLayered emptyLayered {booleanLayer = Set.singleton value}
  SemanticTypeArray element ->
    NormalizedTypeLayered emptyLayered {arrayLayer = ArraySlotOf (normaliseSemantic element)}
  SemanticTypeTuple elements ->
    NormalizedTypeLayered
      emptyLayered
        { tupleLayer = Map.singleton (length elements) (normaliseSemantic <$> elements)
        }
  SemanticTypeData typeId ->
    NormalizedTypeLayered emptyLayered {dataLayer = Set.singleton typeId}
  SemanticTypeObject fields ->
    NormalizedTypeLayered
      emptyLayered
        { objectLayer = ObjectSlotOf (Map.map normaliseSemantic fields)
        }
  SemanticTypeFunction parameterTypes returnType requests ->
    let shape =
          FunctionShape
            { parameters = Map.map normaliseSemantic parameterTypes,
              returnType = normaliseSemantic returnType,
              requests = requests.requestReqs
              -- requestVars must be empty in Resolved phase by Zonker invariant.
            }
     in NormalizedTypeLayered emptyLayered {functionLayer = FunctionSlotOf shape}
  SemanticTypeUnion branches ->
    foldr (unionNT . normaliseSemantic) (NormalizedTypeLayered emptyLayered) branches

-- ---------------------------------------------------------------------------
-- Union (least upper bound)
-- ---------------------------------------------------------------------------

-- | Pointwise union of two normalized types.
unionNT :: NormalizedType -> NormalizedType -> NormalizedType
unionNT leftType rightType = case (leftType, rightType) of
  (NormalizedTypeUnknown, _) -> NormalizedTypeUnknown
  (_, NormalizedTypeUnknown) -> NormalizedTypeUnknown
  (NormalizedTypeLayered leftLayered, NormalizedTypeLayered rightLayered) ->
    NormalizedTypeLayered (unionLayered leftLayered rightLayered)

unionLayered :: LayeredType -> LayeredType -> LayeredType
unionLayered leftLayered rightLayered =
  LayeredType
    { numberLayer = unionNumberSlot leftLayered.numberLayer rightLayered.numberLayer,
      stringLayer = unionStringSlot leftLayered.stringLayer rightLayered.stringLayer,
      booleanLayer = Set.union leftLayered.booleanLayer rightLayered.booleanLayer,
      nullLayer = leftLayered.nullLayer || rightLayered.nullLayer,
      functionLayer = unionFunctionLayer leftLayered.functionLayer rightLayered.functionLayer,
      arrayLayer = unionArraySlot leftLayered.arrayLayer rightLayered.arrayLayer,
      tupleLayer = unionTupleLayer leftLayered.tupleLayer rightLayered.tupleLayer,
      dataLayer = Set.union leftLayered.dataLayer rightLayered.dataLayer,
      objectLayer = unionObjectSlot leftLayered.objectLayer rightLayered.objectLayer
    }

unionNumberSlot :: NumberSlot -> NumberSlot -> NumberSlot
unionNumberSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (NumberSlotNumber, _) -> NumberSlotNumber
  (_, NumberSlotNumber) -> NumberSlotNumber
  (NumberSlotInteger, NumberSlotInteger) -> NumberSlotInteger
  (NumberSlotInteger, NumberSlotLiterals _) -> NumberSlotInteger
  (NumberSlotLiterals _, NumberSlotInteger) -> NumberSlotInteger
  (NumberSlotLiterals leftLiterals, NumberSlotLiterals rightLiterals) ->
    NumberSlotLiterals (Set.union leftLiterals rightLiterals)

unionStringSlot :: StringSlot -> StringSlot -> StringSlot
unionStringSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (StringSlotAny, _) -> StringSlotAny
  (_, StringSlotAny) -> StringSlotAny
  (StringSlotLiterals leftLiterals, StringSlotLiterals rightLiterals) ->
    StringSlotLiterals (Set.union leftLiterals rightLiterals)

unionArraySlot :: ArraySlot -> ArraySlot -> ArraySlot
unionArraySlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ArraySlotAbsent, other) -> other
  (other, ArraySlotAbsent) -> other
  (ArraySlotOf leftElement, ArraySlotOf rightElement) ->
    ArraySlotOf (unionNT leftElement rightElement)

-- | Union of function slots.
--
-- Per the user-specified rule: take the **union** of label sets, with each
-- common label's type **intersected** (contravariant in args). Labels only
-- in one side are kept as-is. Requests are unioned.
unionFunctionLayer :: FunctionSlot -> FunctionSlot -> FunctionSlot
unionFunctionLayer leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, other) -> other
  (other, FunctionSlotAbsent) -> other
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    FunctionSlotOf (unionFunctionShape leftShape rightShape)

unionFunctionShape :: FunctionShape -> FunctionShape -> FunctionShape
unionFunctionShape leftShape rightShape =
  FunctionShape
    { -- contravariant in args: union of function types intersects per-label
      -- types, and uses the union of label sets.
      parameters =
        Map.unionWith intersectNT leftShape.parameters rightShape.parameters,
      returnType = unionNT leftShape.returnType rightShape.returnType,
      requests = Set.union leftShape.requests rightShape.requests
    }

unionTupleLayer ::
  Map Int [NormalizedType] ->
  Map Int [NormalizedType] ->
  Map Int [NormalizedType]
unionTupleLayer = Map.unionWith (zipWith unionNT)

unionObjectSlot :: ObjectSlot -> ObjectSlot -> ObjectSlot
unionObjectSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ObjectSlotAbsent, other) -> other
  (other, ObjectSlotAbsent) -> other
  (ObjectSlotOf leftFields, ObjectSlotOf rightFields) ->
    -- Width subtyping: union keeps only common fields with widened types.
    ObjectSlotOf (Map.intersectionWith unionNT leftFields rightFields)

-- ---------------------------------------------------------------------------
-- Intersection (greatest lower bound)
-- ---------------------------------------------------------------------------

-- | Pointwise intersection of two normalized types.
intersectNT :: NormalizedType -> NormalizedType -> NormalizedType
intersectNT leftType rightType = case (leftType, rightType) of
  (NormalizedTypeUnknown, other) -> other
  (other, NormalizedTypeUnknown) -> other
  (NormalizedTypeLayered leftLayered, NormalizedTypeLayered rightLayered) ->
    NormalizedTypeLayered (intersectLayered leftLayered rightLayered)

intersectLayered :: LayeredType -> LayeredType -> LayeredType
intersectLayered leftLayered rightLayered =
  LayeredType
    { numberLayer = intersectNumberSlot leftLayered.numberLayer rightLayered.numberLayer,
      stringLayer = intersectStringSlot leftLayered.stringLayer rightLayered.stringLayer,
      booleanLayer = Set.intersection leftLayered.booleanLayer rightLayered.booleanLayer,
      nullLayer = leftLayered.nullLayer && rightLayered.nullLayer,
      functionLayer = intersectFunctionLayer leftLayered.functionLayer rightLayered.functionLayer,
      arrayLayer = intersectArraySlot leftLayered.arrayLayer rightLayered.arrayLayer,
      tupleLayer = intersectTupleLayer leftLayered.tupleLayer rightLayered.tupleLayer,
      dataLayer = Set.intersection leftLayered.dataLayer rightLayered.dataLayer,
      objectLayer = intersectObjectSlot leftLayered.objectLayer rightLayered.objectLayer
    }

intersectNumberSlot :: NumberSlot -> NumberSlot -> NumberSlot
intersectNumberSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (NumberSlotNumber, other) -> other
  (other, NumberSlotNumber) -> other
  (NumberSlotInteger, other) -> other
  (other, NumberSlotInteger) -> other
  (NumberSlotLiterals leftLiterals, NumberSlotLiterals rightLiterals) ->
    NumberSlotLiterals (Set.intersection leftLiterals rightLiterals)

intersectStringSlot :: StringSlot -> StringSlot -> StringSlot
intersectStringSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (StringSlotAny, other) -> other
  (other, StringSlotAny) -> other
  (StringSlotLiterals leftLiterals, StringSlotLiterals rightLiterals) ->
    StringSlotLiterals (Set.intersection leftLiterals rightLiterals)

intersectArraySlot :: ArraySlot -> ArraySlot -> ArraySlot
intersectArraySlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ArraySlotAbsent, _) -> ArraySlotAbsent
  (_, ArraySlotAbsent) -> ArraySlotAbsent
  (ArraySlotOf leftElement, ArraySlotOf rightElement) ->
    ArraySlotOf (intersectNT leftElement rightElement)

-- | Intersection of function slots.
--
-- Per the user-specified rule: take the **intersection** of label sets,
-- with each common label's type **unioned** (contravariant in args).
-- Requests are unioned (合併) per the spec.
intersectFunctionLayer :: FunctionSlot -> FunctionSlot -> FunctionSlot
intersectFunctionLayer leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, _) -> FunctionSlotAbsent
  (_, FunctionSlotAbsent) -> FunctionSlotAbsent
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    FunctionSlotOf (intersectFunctionShape leftShape rightShape)

intersectFunctionShape :: FunctionShape -> FunctionShape -> FunctionShape
intersectFunctionShape leftShape rightShape =
  FunctionShape
    { -- contravariant in args: intersection of function types unions per-label
      -- types, and uses the intersection of label sets.
      parameters =
        Map.intersectionWith unionNT leftShape.parameters rightShape.parameters,
      returnType = intersectNT leftShape.returnType rightShape.returnType,
      requests = Set.union leftShape.requests rightShape.requests
    }

intersectTupleLayer ::
  Map Int [NormalizedType] ->
  Map Int [NormalizedType] ->
  Map Int [NormalizedType]
intersectTupleLayer = Map.intersectionWith (zipWith intersectNT)

intersectObjectSlot :: ObjectSlot -> ObjectSlot -> ObjectSlot
intersectObjectSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ObjectSlotAbsent, _) -> ObjectSlotAbsent
  (_, ObjectSlotAbsent) -> ObjectSlotAbsent
  (ObjectSlotOf leftFields, ObjectSlotOf rightFields) ->
    -- Intersection: all fields, common ones intersected.
    let commonFields = Map.intersectionWith intersectNT leftFields rightFields
        leftOnlyFields = Map.difference leftFields rightFields
        rightOnlyFields = Map.difference rightFields leftFields
     in ObjectSlotOf (Map.unions [commonFields, leftOnlyFields, rightOnlyFields])

-- ---------------------------------------------------------------------------
-- Subtype check
-- ---------------------------------------------------------------------------

-- | @subtypeNT leftType rightType@ holds when every value of @leftType@ is
-- also a value of @rightType@. Implemented as a per-layer check: each layer
-- slot of the left must be a subtype of the corresponding slot of the right.
subtypeNT :: NormalizedType -> NormalizedType -> Bool
subtypeNT leftType rightType = case (leftType, rightType) of
  (_, NormalizedTypeUnknown) -> True
  (NormalizedTypeUnknown, _) -> False
  (NormalizedTypeLayered leftLayered, NormalizedTypeLayered rightLayered) ->
    subtypeLayered leftLayered rightLayered

subtypeLayered :: LayeredType -> LayeredType -> Bool
subtypeLayered leftLayered rightLayered =
  subtypeNumberSlot leftLayered.numberLayer rightLayered.numberLayer
    && subtypeStringSlot leftLayered.stringLayer rightLayered.stringLayer
    && Set.isSubsetOf leftLayered.booleanLayer rightLayered.booleanLayer
    && (not leftLayered.nullLayer || rightLayered.nullLayer)
    && subtypeFunctionLayer leftLayered.functionLayer rightLayered.functionLayer
    && subtypeArraySlot leftLayered.arrayLayer rightLayered.arrayLayer
    && subtypeTupleLayer leftLayered.tupleLayer rightLayered.tupleLayer
    && Set.isSubsetOf leftLayered.dataLayer rightLayered.dataLayer
    && subtypeObjectSlot leftLayered.objectLayer rightLayered.objectLayer

subtypeNumberSlot :: NumberSlot -> NumberSlot -> Bool
subtypeNumberSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (NumberSlotLiterals literals, _) | Set.null literals -> True
  (_, NumberSlotNumber) -> True
  (NumberSlotNumber, _) -> False
  (NumberSlotInteger, NumberSlotInteger) -> True
  (NumberSlotInteger, _) -> False
  (NumberSlotLiterals _, NumberSlotInteger) -> True
  (NumberSlotLiterals leftLiterals, NumberSlotLiterals rightLiterals) ->
    Set.isSubsetOf leftLiterals rightLiterals

subtypeStringSlot :: StringSlot -> StringSlot -> Bool
subtypeStringSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (StringSlotLiterals literals, _) | Set.null literals -> True
  (_, StringSlotAny) -> True
  (StringSlotAny, _) -> False
  (StringSlotLiterals leftLiterals, StringSlotLiterals rightLiterals) ->
    Set.isSubsetOf leftLiterals rightLiterals

subtypeArraySlot :: ArraySlot -> ArraySlot -> Bool
subtypeArraySlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ArraySlotAbsent, _) -> True
  (_, ArraySlotAbsent) -> False
  (ArraySlotOf leftElement, ArraySlotOf rightElement) ->
    subtypeNT leftElement rightElement -- covariant

subtypeFunctionLayer :: FunctionSlot -> FunctionSlot -> Bool
subtypeFunctionLayer leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, _) -> True
  (_, FunctionSlotAbsent) -> False
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    subtypeFunctionShape leftShape rightShape

-- | @subtypeFunctionShape leftShape rightShape@ holds when every value of
-- @leftShape@ is also a value of @rightShape@.
--
-- Rule (matching the union/intersection semantics specified by Katari):
--
--   * Label set: @leftShape@'s labels must be a subset of @rightShape@'s.
--     (A function with fewer labels is "more general".)
--   * For each label common to both sides, the parameter type is
--     contravariant: @rightShape@'s parameter type must be a subtype of
--     @leftShape@'s.
--   * Return type is covariant.
--   * Request set is covariant (subset).
subtypeFunctionShape :: FunctionShape -> FunctionShape -> Bool
subtypeFunctionShape leftShape rightShape =
  Map.keysSet leftShape.parameters `Set.isSubsetOf` Map.keysSet rightShape.parameters
    && all checkParameter (Map.toList leftShape.parameters)
    && subtypeNT leftShape.returnType rightShape.returnType
    && Set.isSubsetOf leftShape.requests rightShape.requests
  where
    checkParameter (label, leftType) = case Map.lookup label rightShape.parameters of
      Just rightType -> subtypeNT rightType leftType -- contravariant
      Nothing -> True -- guarded by keysSet subset above

subtypeTupleLayer ::
  Map Int [NormalizedType] ->
  Map Int [NormalizedType] ->
  Bool
subtypeTupleLayer leftShapes rightShapes = all checkArity (Map.toList leftShapes)
  where
    checkArity (arity, leftElements) = case Map.lookup arity rightShapes of
      Just rightElements ->
        length leftElements == length rightElements
          && and (zipWith subtypeNT leftElements rightElements)
      Nothing -> False

subtypeObjectSlot :: ObjectSlot -> ObjectSlot -> Bool
subtypeObjectSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ObjectSlotAbsent, _) -> True
  (_, ObjectSlotAbsent) -> False
  (ObjectSlotOf leftFields, ObjectSlotOf rightFields) ->
    -- left <: right: every required field of right is in left with compatible
    -- type. (Width subtyping: left may have extra fields.)
    all (checkField leftFields) (Map.toList rightFields)
  where
    checkField leftFields (fieldName, rightFieldType) =
      case Map.lookup fieldName leftFields of
        Just leftFieldType -> subtypeNT leftFieldType rightFieldType
        Nothing -> False
