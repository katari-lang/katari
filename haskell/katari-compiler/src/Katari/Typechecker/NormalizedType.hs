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
import Katari.Typechecker.Identifier (TypeId, VariableId)
import Katari.Typechecker.SemanticType (Resolved, SemanticEffect (..), SemanticType (..))

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
    -- | Function layer. 'FunctionAbsent' means no function values inhabit
    -- this type; 'FunctionOf' carries a single function shape (with named
    -- parameters). Per Katari's product-normalisation rule, multiple
    -- function shapes in a union collapse into one shape: union → label
    -- union with each common label's type intersected; intersection →
    -- label intersection with each common label's type unioned.
    functionLayer :: !FunctionSlot,
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
  NTUnknown -> SemanticTypeUnknown
  NTLayered layered -> case denormaliseBranches layered of
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
  NumberLiterals literals -> SemanticTypeLiteralInteger <$> Set.toList literals
  NumberInteger -> [SemanticTypeInteger]
  NumberNumber -> [SemanticTypeNumber]

stringBranches :: StringSlot -> [SemanticType Resolved]
stringBranches = \case
  StringLiterals literals -> SemanticTypeLiteralString <$> Set.toList literals
  StringAny -> [SemanticTypeString]

booleanBranches :: Set Bool -> [SemanticType Resolved]
booleanBranches values
  | values == Set.fromList [True, False] = [SemanticTypeBoolean]
  | otherwise = SemanticTypeLiteralBoolean <$> Set.toList values

nullBranches :: Bool -> [SemanticType Resolved]
nullBranches True = [SemanticTypeNull]
nullBranches False = []

functionBranches :: Map FunctionSignature FunctionShape -> [SemanticType Resolved]
functionBranches = fmap (uncurry makeFunction) . Map.toList
  where
    makeFunction
      (FunctionSignature labels)
      FunctionShape {parameterTypes, returnType, effects} =
        SemanticTypeFunction
          (zip labels (denormalise <$> parameterTypes))
          (denormalise returnType)
          (SemanticEffect Set.empty effects)

arrayBranches :: ArraySlot -> [SemanticType Resolved]
arrayBranches = \case
  ArrayAbsent -> []
  ArrayOf elementType -> [SemanticTypeArray (denormalise elementType)]

tupleBranches :: Map Int [NormalizedType] -> [SemanticType Resolved]
tupleBranches = fmap (SemanticTypeTuple . fmap denormalise . snd) . Map.toList

dataBranches :: Set TypeId -> [SemanticType Resolved]
dataBranches = fmap SemanticTypeData . Set.toList

objectBranches :: ObjectSlot -> [SemanticType Resolved]
objectBranches = \case
  ObjectAbsent -> []
  ObjectOf fields -> [SemanticTypeObject (Map.map denormalise fields)]

-- ---------------------------------------------------------------------------
-- isNeverNT / isUnknownNT
-- ---------------------------------------------------------------------------

-- | Is this the bottom type? Equivalent to @NTLayered emptyLayered@.
isNeverNT :: NormalizedType -> Bool
isNeverNT = \case
  NTLayered layered -> isEmptyLayered layered
  _ -> False

-- | Is this the top type?
isUnknownNT :: NormalizedType -> Bool
isUnknownNT = \case
  NTUnknown -> True
  _ -> False

isEmptyLayered :: LayeredType -> Bool
isEmptyLayered LayeredType {..} =
  isEmptyNumber numberLayer
    && isEmptyString stringLayer
    && Set.null booleanLayer
    && not nullLayer
    && Map.null functionLayer
    && isEmptyArray arrayLayer
    && Map.null tupleLayer
    && Set.null dataLayer
    && isEmptyObject objectLayer

isEmptyNumber :: NumberSlot -> Bool
isEmptyNumber = \case
  NumberLiterals s -> Set.null s
  _ -> False

isEmptyString :: StringSlot -> Bool
isEmptyString = \case
  StringLiterals s -> Set.null s
  _ -> False

isEmptyArray :: ArraySlot -> Bool
isEmptyArray = \case
  ArrayAbsent -> True
  _ -> False

isEmptyObject :: ObjectSlot -> Bool
isEmptyObject = \case
  ObjectAbsent -> True
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
  SemanticTypeUnknown -> NTUnknown
  SemanticTypeNever -> NTLayered emptyLayered
  SemanticTypeNull -> NTLayered emptyLayered {nullLayer = True}
  SemanticTypeBoolean ->
    NTLayered emptyLayered {booleanLayer = Set.fromList [True, False]}
  SemanticTypeInteger ->
    NTLayered emptyLayered {numberLayer = NumberInteger}
  SemanticTypeNumber ->
    NTLayered emptyLayered {numberLayer = NumberNumber}
  SemanticTypeString ->
    NTLayered emptyLayered {stringLayer = StringAny}
  SemanticTypeLiteralInteger value ->
    NTLayered emptyLayered {numberLayer = NumberLiterals (Set.singleton value)}
  SemanticTypeLiteralString value ->
    NTLayered emptyLayered {stringLayer = StringLiterals (Set.singleton value)}
  SemanticTypeLiteralBoolean value ->
    NTLayered emptyLayered {booleanLayer = Set.singleton value}
  SemanticTypeArray element ->
    NTLayered emptyLayered {arrayLayer = ArrayOf (normaliseSemantic element)}
  SemanticTypeTuple elements ->
    NTLayered
      emptyLayered
        { tupleLayer = Map.singleton (length elements) (normaliseSemantic <$> elements)
        }
  SemanticTypeData typeId ->
    NTLayered emptyLayered {dataLayer = Set.singleton typeId}
  SemanticTypeObject fields ->
    NTLayered
      emptyLayered
        { objectLayer = ObjectOf (Map.map normaliseSemantic fields)
        }
  SemanticTypeFunction parameterTypes returnType effects ->
    let parameterLabels = fst <$> parameterTypes
        normalizedParameterTypes = normaliseSemantic . snd <$> parameterTypes
        shape =
          FunctionShape
            { parameterTypes = normalizedParameterTypes,
              returnType = normaliseSemantic returnType,
              effects = effects.effectReqs
              -- effectVars must be empty in Resolved phase by Zonker invariant.
            }
     in NTLayered
          emptyLayered
            { functionLayer = Map.singleton (FunctionSignature parameterLabels) shape
            }
  SemanticTypeUnion branches ->
    foldr (unionNT . normaliseSemantic) (NTLayered emptyLayered) branches

-- ---------------------------------------------------------------------------
-- Union (least upper bound)
-- ---------------------------------------------------------------------------

-- | Pointwise union of two normalized types.
unionNT :: NormalizedType -> NormalizedType -> NormalizedType
unionNT leftType rightType = case (leftType, rightType) of
  (NTUnknown, _) -> NTUnknown
  (_, NTUnknown) -> NTUnknown
  (NTLayered leftLayered, NTLayered rightLayered) ->
    NTLayered (unionLayered leftLayered rightLayered)

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
  (NumberNumber, _) -> NumberNumber
  (_, NumberNumber) -> NumberNumber
  (NumberInteger, NumberInteger) -> NumberInteger
  (NumberInteger, NumberLiterals _) -> NumberInteger
  (NumberLiterals _, NumberInteger) -> NumberInteger
  (NumberLiterals leftLiterals, NumberLiterals rightLiterals) ->
    NumberLiterals (Set.union leftLiterals rightLiterals)

unionStringSlot :: StringSlot -> StringSlot -> StringSlot
unionStringSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (StringAny, _) -> StringAny
  (_, StringAny) -> StringAny
  (StringLiterals leftLiterals, StringLiterals rightLiterals) ->
    StringLiterals (Set.union leftLiterals rightLiterals)

unionArraySlot :: ArraySlot -> ArraySlot -> ArraySlot
unionArraySlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ArrayAbsent, other) -> other
  (other, ArrayAbsent) -> other
  (ArrayOf leftElement, ArrayOf rightElement) ->
    ArrayOf (unionNT leftElement rightElement)

unionFunctionLayer ::
  Map FunctionSignature FunctionShape ->
  Map FunctionSignature FunctionShape ->
  Map FunctionSignature FunctionShape
unionFunctionLayer = Map.unionWith unionFunctionShape

unionFunctionShape :: FunctionShape -> FunctionShape -> FunctionShape
unionFunctionShape leftShape rightShape =
  FunctionShape
    { parameterTypes =
        zipWith intersectNT leftShape.parameterTypes rightShape.parameterTypes,
      -- contravariant in args: union shrinks param domain
      returnType = unionNT leftShape.returnType rightShape.returnType,
      effects = Set.union leftShape.effects rightShape.effects
    }

unionTupleLayer ::
  Map Int [NormalizedType] ->
  Map Int [NormalizedType] ->
  Map Int [NormalizedType]
unionTupleLayer = Map.unionWith (zipWith unionNT)

unionObjectSlot :: ObjectSlot -> ObjectSlot -> ObjectSlot
unionObjectSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ObjectAbsent, other) -> other
  (other, ObjectAbsent) -> other
  (ObjectOf leftFields, ObjectOf rightFields) ->
    -- Width subtyping: union keeps only common fields with widened types.
    ObjectOf (Map.intersectionWith unionNT leftFields rightFields)

-- ---------------------------------------------------------------------------
-- Intersection (greatest lower bound)
-- ---------------------------------------------------------------------------

-- | Pointwise intersection of two normalized types.
intersectNT :: NormalizedType -> NormalizedType -> NormalizedType
intersectNT leftType rightType = case (leftType, rightType) of
  (NTUnknown, other) -> other
  (other, NTUnknown) -> other
  (NTLayered leftLayered, NTLayered rightLayered) ->
    NTLayered (intersectLayered leftLayered rightLayered)

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
  (NumberNumber, other) -> other
  (other, NumberNumber) -> other
  (NumberInteger, other) -> other
  (other, NumberInteger) -> other
  (NumberLiterals leftLiterals, NumberLiterals rightLiterals) ->
    NumberLiterals (Set.intersection leftLiterals rightLiterals)

intersectStringSlot :: StringSlot -> StringSlot -> StringSlot
intersectStringSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (StringAny, other) -> other
  (other, StringAny) -> other
  (StringLiterals leftLiterals, StringLiterals rightLiterals) ->
    StringLiterals (Set.intersection leftLiterals rightLiterals)

intersectArraySlot :: ArraySlot -> ArraySlot -> ArraySlot
intersectArraySlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ArrayAbsent, _) -> ArrayAbsent
  (_, ArrayAbsent) -> ArrayAbsent
  (ArrayOf leftElement, ArrayOf rightElement) ->
    ArrayOf (intersectNT leftElement rightElement)

intersectFunctionLayer ::
  Map FunctionSignature FunctionShape ->
  Map FunctionSignature FunctionShape ->
  Map FunctionSignature FunctionShape
intersectFunctionLayer = Map.intersectionWith intersectFunctionShape

intersectFunctionShape :: FunctionShape -> FunctionShape -> FunctionShape
intersectFunctionShape leftShape rightShape =
  FunctionShape
    { parameterTypes =
        zipWith unionNT leftShape.parameterTypes rightShape.parameterTypes,
      -- contravariant in args: intersection widens param domain
      returnType = intersectNT leftShape.returnType rightShape.returnType,
      effects = Set.intersection leftShape.effects rightShape.effects
    }

intersectTupleLayer ::
  Map Int [NormalizedType] ->
  Map Int [NormalizedType] ->
  Map Int [NormalizedType]
intersectTupleLayer = Map.intersectionWith (zipWith intersectNT)

intersectObjectSlot :: ObjectSlot -> ObjectSlot -> ObjectSlot
intersectObjectSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ObjectAbsent, _) -> ObjectAbsent
  (_, ObjectAbsent) -> ObjectAbsent
  (ObjectOf leftFields, ObjectOf rightFields) ->
    -- Intersection: all fields, common ones intersected.
    let commonFields = Map.intersectionWith intersectNT leftFields rightFields
        leftOnlyFields = Map.difference leftFields rightFields
        rightOnlyFields = Map.difference rightFields leftFields
     in ObjectOf (Map.unions [commonFields, leftOnlyFields, rightOnlyFields])

-- ---------------------------------------------------------------------------
-- Subtype check
-- ---------------------------------------------------------------------------

-- | @subtypeNT leftType rightType@ holds when every value of @leftType@ is
-- also a value of @rightType@. Implemented as a per-layer check: each layer
-- slot of the left must be a subtype of the corresponding slot of the right.
subtypeNT :: NormalizedType -> NormalizedType -> Bool
subtypeNT leftType rightType = case (leftType, rightType) of
  (_, NTUnknown) -> True
  (NTUnknown, _) -> False
  (NTLayered leftLayered, NTLayered rightLayered) ->
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
  (NumberLiterals literals, _) | Set.null literals -> True
  (_, NumberNumber) -> True
  (NumberNumber, _) -> False
  (NumberInteger, NumberInteger) -> True
  (NumberInteger, _) -> False
  (NumberLiterals _, NumberInteger) -> True
  (NumberLiterals leftLiterals, NumberLiterals rightLiterals) ->
    Set.isSubsetOf leftLiterals rightLiterals

subtypeStringSlot :: StringSlot -> StringSlot -> Bool
subtypeStringSlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (StringLiterals literals, _) | Set.null literals -> True
  (_, StringAny) -> True
  (StringAny, _) -> False
  (StringLiterals leftLiterals, StringLiterals rightLiterals) ->
    Set.isSubsetOf leftLiterals rightLiterals

subtypeArraySlot :: ArraySlot -> ArraySlot -> Bool
subtypeArraySlot leftSlot rightSlot = case (leftSlot, rightSlot) of
  (ArrayAbsent, _) -> True
  (_, ArrayAbsent) -> False
  (ArrayOf leftElement, ArrayOf rightElement) ->
    subtypeNT leftElement rightElement -- covariant

subtypeFunctionLayer ::
  Map FunctionSignature FunctionShape ->
  Map FunctionSignature FunctionShape ->
  Bool
subtypeFunctionLayer leftShapes rightShapes =
  -- Every shape in left must have a compatible shape in right with same signature.
  all checkShape (Map.toList leftShapes)
  where
    checkShape (signature, leftShape) = case Map.lookup signature rightShapes of
      Just rightShape -> subtypeFunctionShape leftShape rightShape
      Nothing -> False

subtypeFunctionShape :: FunctionShape -> FunctionShape -> Bool
subtypeFunctionShape leftShape rightShape =
  -- contravariant in args, covariant in return, covariant in effects (subset).
  length leftShape.parameterTypes == length rightShape.parameterTypes
    && and (zipWith subtypeNT rightShape.parameterTypes leftShape.parameterTypes)
    && subtypeNT leftShape.returnType rightShape.returnType
    && Set.isSubsetOf leftShape.effects rightShape.effects

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
  (ObjectAbsent, _) -> True
  (_, ObjectAbsent) -> False
  (ObjectOf leftFields, ObjectOf rightFields) ->
    -- left <: right: every required field of right is in left with compatible
    -- type. (Width subtyping: left may have extra fields.)
    all (checkField leftFields) (Map.toList rightFields)
  where
    checkField leftFields (fieldName, rightFieldType) =
      case Map.lookup fieldName leftFields of
        Just leftFieldType -> subtypeNT leftFieldType rightFieldType
        Nothing -> False
