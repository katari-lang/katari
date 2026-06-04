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
    BareSeq (..),
    BareObj (..),
    MapSlot (..),
    FunctionSlot (..),
    FunctionShape (..),
    NormalizedParameter (..),
    NormalizedEffect (..),
    emptyNormalizedEffect,
    unionNormalizedEffect,
    subtractConcrete,
    differenceNormalizedEffect,
    nullNormalizedEffect,
    normaliseEffect,
    denormaliseEffect,
    subtypeEffect,
    DataFieldEnv,
    buildDataFieldEnv,
    BoundEnv,

    -- * Helpers
    emptyLayered,
    emptyMapSlot,
    isNeverNT,
    isUnknownNT,

    -- * Conversion to SemanticType
    denormalise,

    -- * Conversion from SemanticType
    normaliseSemantic,

    -- * Lattice operations
    unionNT,
    intersectNT,
    subtypeNormalizedType,
    expandGenerics,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Common (QualifiedName)
import Katari.Id (GenericsId)
import Katari.SemanticType (Parameter (..), Resolved, SemanticEffect (..), SemanticType (..), functionParameters, unionEffects)

-- ---------------------------------------------------------------------------
-- NormalizedType
-- ---------------------------------------------------------------------------

-- | The canonical normal form of a Katari type. Equality is structural.
--
-- @NormalizedTypeLayered 'emptyLayered'@ is the canonical "never" / bottom type.
data NormalizedType where
  NormalizedTypeUnknown :: NormalizedType
  NormalizedTypeLayered :: LayeredType -> NormalizedType
  deriving (Eq, Show)

-- | One slot per "type family". A @NormalizedType@ is the sum (union) of
-- the contributions from every populated layer.
data LayeredType = LayeredType
  { -- | Numeric layer. Empty 'NumberSlotLiterals' if no number values inhabit
    -- this type.
    numberLayer :: NumberSlot,
    -- | String layer.
    stringLayer :: StringSlot,
    -- | Boolean layer. Possible canonical states: @{}@, @{True}@, @{False}@,
    -- @{True, False}@. Note that @{True, False}@ is the same set as the
    -- full 'boolean' primitive — there is intentionally no separate
    -- @BooleanAny@ representation.
    booleanLayer :: Set Bool,
    -- | Whether @null@ is inhabited.
    nullLayer :: Bool,
    -- | Whether @secret@ is inhabited. The @secret@ type is opaque and
    -- carries no internal structure (no literals, no subdivision), so a
    -- single Bool slot suffices. Disjoint from 'stringLayer' — there
    -- is no subtype relation between @secret@ and @string@.
    secretLayer :: Bool,
    -- | Whether @file@ is inhabited. Opaque (no literals / subdivision),
    -- so a single Bool slot suffices. Disjoint from 'stringLayer'.
    fileLayer :: Bool,
    -- | Function layer. 'FunctionSlotAbsent' means no function values inhabit
    -- this type; 'FunctionSlotOf' carries a single function shape (with named
    -- parameters). Per Katari's product-normalisation rule, multiple
    -- function shapes in a union collapse into one shape: union → label
    -- union with each common label's type intersected; intersection →
    -- label intersection with each common label's type unioned.
    functionLayer :: FunctionSlot,
    -- | Sequence layer — tuple and array merged (@tuple <: array@). See
    -- 'BareSeq'.
    seqLayer :: BareSeq,
    -- | Map layer — object, record and @data@ merged (@data <: object <:
    -- record@). See 'MapSlot'.
    mapLayer :: MapSlot,
    -- | Generics layer — the set of in-scope generic parameters this type
    -- includes (each an abstract 'SemanticTypeGeneric'). Union is set union;
    -- intersection is set intersection (incomplete but sound: narrowing
    -- @T & int@ to @never@ only shrinks the meet). Subtyping expands each
    -- generic to its declared upper bound (see 'subtypeNormalizedType').
    genericsLayer :: Set GenericsId
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
  NumberSlotLiterals :: (Set Integer) -> NumberSlot
  NumberSlotInteger :: NumberSlot
  NumberSlotNumber :: NumberSlot
  deriving (Eq, Show)

-- | String slot.
--
--   * @'StringSlotLiterals' s@ — exactly the strings in @s@; @s@ may be empty
--     to indicate "no string values".
--   * 'StringSlotAny' — the full 'string' primitive.
data StringSlot where
  StringSlotLiterals :: (Set Text) -> StringSlot
  StringSlotAny :: StringSlot
  deriving (Eq, Show)

-- | Sequence layer — tuple and array merged into one layer (tuples are the
-- precise positional refinement of the homogeneous @array@: @tuple[T…] <:
-- array[⋃T]@).
--
--   * 'NoSeq' — no sequence values inhabit this type.
--   * @'Tuple' ts@ — a single canonical tuple of per-position element types.
--     Tuples are structural (like objects, with positions as labels), so a
--     union collapses to the common prefix (the shorter length, positions
--     unioned) and an intersection extends to all positions (the longer
--     length, common positions intersected). Width subtyping: a longer tuple
--     is a subtype of a shorter prefix.
--   * @'Array' t@ — homogeneous arrays of element type @t@; the top of the
--     layer (absorbs all tuples on union). @'Array' (NormalizedTypeLayered
--     emptyLayered)@ still admits the empty array value @[]@.
data BareSeq
  = NoSeq
  | Tuple [NormalizedType]
  | Array NormalizedType
  deriving (Eq, Show)

-- | The structural (non-nominal) part of the map layer.
--
--   * 'NoObj' — no structural map values.
--   * @'ClosedObj' fs@ — a closed object with exactly the field labels @fs@
--     (more fields = subtype, via width).
--   * @'RecordObj' v@ — a homogeneous @record[V]@; the top of the structural
--     part (@{l: T} <: record[⋃T]@), absorbs closed objects on union.
-- | The structural object's fields reuse 'NormalizedParameter' (a parameter
-- signature is, semantically, an object): each field is a type plus whether it
-- is optional (may be absent).
data BareObj
  = NoObj
  | ClosedObj (Map Text NormalizedParameter)
  | RecordObj NormalizedType
  deriving (Eq, Show)

-- | Normalise / denormalise a single object field (preserving optionality).
normaliseField :: Parameter Resolved -> NormalizedParameter
normaliseField field = NormalizedParameter (normaliseSemantic field.parameterType) field.optional

denormaliseField :: NormalizedParameter -> Parameter Resolved
denormaliseField field = Parameter (denormalise field.parameterType) field.optional

-- | Map layer — object, record and @data@ merged into one layer.
--
--   * 'dataNames' is the set of @data@ type names inhabiting this type (the
--     discriminated-union part). Only the /name/ is stored — a data's
--     concrete fields are looked up on demand from an external env during
--     subtyping (the @data <: object@ rule), which keeps the normalized form
--     finite even for recursive @data@ (e.g. @data tree(left: tree)@) and
--     keeps union / intersect env-free.
--   * 'bare' is the structural part ('BareObj'). Data names are kept separate
--     from 'bare' (not absorbed into a record).
data MapSlot = MapSlot
  { dataNames :: Set QualifiedName,
    bare :: BareObj
  }
  deriving (Eq, Show)

-- | Function layer.
--
--   * 'FunctionSlotAbsent' — no function values inhabit this type.
--   * @'FunctionSlotOf' shape@ — function values matching @shape@.
--   * 'FunctionSlotAny' — every callable inhabits this slot (the
--     normalised form of the surface @function@ top type). Acts as the
--     top element of the function-slot lattice.
--
-- Multiple function shapes in a union are collapsed into a single shape via
-- the product-normalisation rule (label-set union with per-common-label
-- intersection of types).
data FunctionSlot where
  FunctionSlotAbsent :: FunctionSlot
  FunctionSlotOf :: FunctionShape -> FunctionSlot
  FunctionSlotAny :: FunctionSlot
  deriving (Eq, Show)

-- | Concrete function shape. Parameters are keyed by their label (order is
-- not represented at this level).
-- | A normalized function parameter: its type plus whether it is optional
-- (declared with a default, hence omittable at call sites).
data NormalizedParameter = NormalizedParameter
  { parameterType :: NormalizedType,
    optional :: Bool
  }
  deriving (Eq, Show)

-- | Concrete function shape. The parameter signature is a /single/
-- 'NormalizedType' (the type of the argument value, usually a 'ClosedObj' of
-- named params, but possibly a tuple etc. via spread). Function subtyping is
-- contravariant on this parameter type — and because the object lattice
-- already handles per-label width and optionality, no label-specific rule is
-- needed here.
data FunctionShape = FunctionShape
  { parameter :: NormalizedType,
    returnType :: NormalizedType,
    requests :: NormalizedEffect
  }
  deriving (Eq, Show)

-- | The normalised (flattened) form of an effect: the set of concrete @req@
-- names plus the set of in-scope @effect@-generic parameters it includes. The
-- @pure@ leaf contributes nothing. This is the canonical effect form used both
-- in a function shape's @requests@ and by the checker's effect inference.
data NormalizedEffect = NormalizedEffect
  { effectConcrete :: Set QualifiedName,
    effectGenerics :: Set GenericsId
  }
  deriving (Eq, Show)

-- | The empty (pure) normalised effect.
emptyNormalizedEffect :: NormalizedEffect
emptyNormalizedEffect = NormalizedEffect Set.empty Set.empty

instance Semigroup NormalizedEffect where
  (<>) = unionNormalizedEffect

instance Monoid NormalizedEffect where
  mempty = emptyNormalizedEffect

-- | Union of two normalised effects (per-set union).
unionNormalizedEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
unionNormalizedEffect leftEffect rightEffect =
  NormalizedEffect
    (Set.union leftEffect.effectConcrete rightEffect.effectConcrete)
    (Set.union leftEffect.effectGenerics rightEffect.effectGenerics)

-- | Intersection of two normalised effects (per-set intersection; covariant
-- meet of function shapes — loses completeness as elsewhere).
intersectNormalizedEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
intersectNormalizedEffect leftEffect rightEffect =
  NormalizedEffect
    (Set.intersection leftEffect.effectConcrete rightEffect.effectConcrete)
    (Set.intersection leftEffect.effectGenerics rightEffect.effectGenerics)

-- | Remove a set of concrete @req@ names from an effect (used when a @handle@
-- discharges the requests it names). Effect generics are left untouched — a
-- concrete handler cannot statically discharge an abstract generic effect, and
-- keeping it over-approximates the raised effect (sound).
subtractConcrete :: Set QualifiedName -> NormalizedEffect -> NormalizedEffect
subtractConcrete handled effect =
  effect {effectConcrete = Set.difference effect.effectConcrete handled}

-- | Per-set difference of two effects (used to report the elements a body
-- raises beyond its declared @with@ clause).
differenceNormalizedEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
differenceNormalizedEffect leftEffect rightEffect =
  NormalizedEffect
    (Set.difference leftEffect.effectConcrete rightEffect.effectConcrete)
    (Set.difference leftEffect.effectGenerics rightEffect.effectGenerics)

-- | True when an effect has no concrete requests and no generics (pure).
nullNormalizedEffect :: NormalizedEffect -> Bool
nullNormalizedEffect effect = Set.null effect.effectConcrete && Set.null effect.effectGenerics

-- | @subtypeEffect left right@ — every effect of @left@ is permitted by
-- @right@. Effect generics are unbounded, so (mirroring the type rule but
-- without bound expansion) a generic on the left cancels only against the same
-- generic on the right; any left-only generic fails. Concrete requests are
-- compared by subset. Right-only generics / requests are harmless slack.
subtypeEffect :: NormalizedEffect -> NormalizedEffect -> Bool
subtypeEffect leftEffect rightEffect =
  Set.isSubsetOf leftEffect.effectGenerics rightEffect.effectGenerics
    && Set.isSubsetOf leftEffect.effectConcrete rightEffect.effectConcrete

-- | Flatten a (resolved) effect tree to its normalised form.
normaliseEffect :: SemanticEffect Resolved -> NormalizedEffect
normaliseEffect = \case
  SemanticEffectPure -> emptyNormalizedEffect
  SemanticEffectRequest qualifiedName -> NormalizedEffect (Set.singleton qualifiedName) Set.empty
  SemanticEffectGeneric genericsId -> NormalizedEffect Set.empty (Set.singleton genericsId)
  SemanticEffectUnion branches -> foldr (unionNormalizedEffect . normaliseEffect) emptyNormalizedEffect branches

-- | Rebuild an effect tree from a normalised effect (concrete leaves then
-- generic leaves, in id order, for determinism).
denormaliseEffect :: NormalizedEffect -> SemanticEffect Resolved
denormaliseEffect effect =
  unionEffects
    ( (SemanticEffectRequest <$> Set.toList effect.effectConcrete)
        ++ (SemanticEffectGeneric <$> Set.toList effect.effectGenerics)
    )

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
      secretLayer = False,
      fileLayer = False,
      functionLayer = FunctionSlotAbsent,
      seqLayer = NoSeq,
      mapLayer = emptyMapSlot,
      genericsLayer = Set.empty
    }

-- | The empty map slot: no @data@ names, no structural object.
emptyMapSlot :: MapSlot
emptyMapSlot = MapSlot {dataNames = Set.empty, bare = NoObj}

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
      secretBranches secretLayer,
      fileBranches fileLayer,
      functionBranches functionLayer,
      seqBranches seqLayer,
      mapBranches mapLayer,
      SemanticTypeGeneric <$> Set.toList genericsLayer
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
nullBranches = \case
  True -> [SemanticTypeNull]
  False -> []

secretBranches :: Bool -> [SemanticType Resolved]
secretBranches = \case
  True -> [SemanticTypeSecret]
  False -> []

fileBranches :: Bool -> [SemanticType Resolved]
fileBranches = \case
  True -> [SemanticTypeFile]
  False -> []

functionBranches :: FunctionSlot -> [SemanticType Resolved]
functionBranches = \case
  FunctionSlotAbsent -> []
  FunctionSlotOf shape -> [makeFunction shape]
  FunctionSlotAny -> [SemanticTypeFunctionAny]
  where
    makeFunction FunctionShape {parameter, returnType, requests} =
      SemanticTypeFunction
        (denormalise parameter)
        (denormalise returnType)
        (denormaliseEffect requests)

seqBranches :: BareSeq -> [SemanticType Resolved]
seqBranches = \case
  NoSeq -> []
  Tuple elements -> [SemanticTypeTuple (denormalise <$> elements)]
  Array elementType -> [SemanticTypeArray (denormalise elementType)]

mapBranches :: MapSlot -> [SemanticType Resolved]
mapBranches MapSlot {dataNames, bare} =
  [SemanticTypeData qualifiedName | qualifiedName <- Set.toList dataNames]
    ++ case bare of
      NoObj -> []
      ClosedObj fields -> [SemanticTypeObject (Map.map denormaliseField fields)]
      RecordObj valueType -> [SemanticTypeRecord (denormalise valueType)]

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
    && not secretLayer
    && not fileLayer
    && isEmptyFunction functionLayer
    && isEmptySeq seqLayer
    && isEmptyMap mapLayer
    && Set.null genericsLayer

isEmptyNumber :: NumberSlot -> Bool
isEmptyNumber = \case
  NumberSlotLiterals s -> Set.null s
  _ -> False

isEmptyString :: StringSlot -> Bool
isEmptyString = \case
  StringSlotLiterals s -> Set.null s
  _ -> False

isEmptySeq :: BareSeq -> Bool
isEmptySeq = \case
  NoSeq -> True
  _ -> False

isEmptyFunction :: FunctionSlot -> Bool
isEmptyFunction = \case
  FunctionSlotAbsent -> True
  _ -> False

isEmptyMap :: MapSlot -> Bool
isEmptyMap (MapSlot dataNames bare) = Set.null dataNames && case bare of
  NoObj -> True
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
  -- function-top: the only layer that's non-empty is the function
  -- layer set to 'FunctionSlotAny'. This is the top element of the
  -- function lattice — every concrete function shape is a subtype.
  SemanticTypeFunctionAny ->
    NormalizedTypeLayered emptyLayered {functionLayer = FunctionSlotAny}
  SemanticTypeNull -> NormalizedTypeLayered emptyLayered {nullLayer = True}
  SemanticTypeBoolean ->
    NormalizedTypeLayered emptyLayered {booleanLayer = Set.fromList [True, False]}
  SemanticTypeInteger ->
    NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger}
  SemanticTypeNumber ->
    NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotNumber}
  SemanticTypeString ->
    NormalizedTypeLayered emptyLayered {stringLayer = StringSlotAny}
  SemanticTypeSecret ->
    NormalizedTypeLayered emptyLayered {secretLayer = True}
  SemanticTypeFile ->
    NormalizedTypeLayered emptyLayered {fileLayer = True}
  SemanticTypeLiteralInteger value ->
    NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotLiterals (Set.singleton value)}
  SemanticTypeLiteralString value ->
    NormalizedTypeLayered emptyLayered {stringLayer = StringSlotLiterals (Set.singleton value)}
  SemanticTypeLiteralBoolean value ->
    NormalizedTypeLayered emptyLayered {booleanLayer = Set.singleton value}
  SemanticTypeArray element ->
    NormalizedTypeLayered emptyLayered {seqLayer = Array (normaliseSemantic element)}
  SemanticTypeTuple elements ->
    NormalizedTypeLayered emptyLayered {seqLayer = Tuple (normaliseSemantic <$> elements)}
  -- TODO(#48): fill the data's concrete fields via the read-only data-fields
  -- env so the @data <: object@ (rule ii) edge can fire. For now the fields
  -- are empty and a data only matches another data by name.
  SemanticTypeData typeId ->
    NormalizedTypeLayered emptyLayered {mapLayer = emptyMapSlot {dataNames = Set.singleton typeId}}
  SemanticTypeGeneric genericsId ->
    NormalizedTypeLayered emptyLayered {genericsLayer = Set.singleton genericsId}
  SemanticTypeObject fields ->
    NormalizedTypeLayered
      emptyLayered
        { mapLayer = emptyMapSlot {bare = ClosedObj (Map.map normaliseField fields)}
        }
  SemanticTypeRecord valueType ->
    NormalizedTypeLayered
      emptyLayered
        { mapLayer = emptyMapSlot {bare = RecordObj (normaliseSemantic valueType)}
        }
  SemanticTypeFunction parameterType returnType effect ->
    let shape =
          FunctionShape
            { parameter = normaliseSemantic parameterType,
              returnType = normaliseSemantic returnType,
              requests = normaliseEffect effect
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
      secretLayer = leftLayered.secretLayer || rightLayered.secretLayer,
      fileLayer = leftLayered.fileLayer || rightLayered.fileLayer,
      functionLayer = unionFunctionLayer leftLayered.functionLayer rightLayered.functionLayer,
      seqLayer = unionSeq leftLayered.seqLayer rightLayered.seqLayer,
      mapLayer = unionMap leftLayered.mapLayer rightLayered.mapLayer,
      genericsLayer = Set.union leftLayered.genericsLayer rightLayered.genericsLayer
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

-- | Union (join) of sequence layers. Same-arity tuples union pointwise;
-- different arities coexist. An @array@ absorbs tuples (their element types
-- join into the homogeneous element).
unionSeq :: BareSeq -> BareSeq -> BareSeq
unionSeq leftSeq rightSeq = case (leftSeq, rightSeq) of
  (NoSeq, other) -> other
  (other, NoSeq) -> other
  -- join collapses to the common prefix (shorter length), positions unioned.
  (Tuple leftElements, Tuple rightElements) -> Tuple (zipWith unionNT leftElements rightElements)
  (Array leftElement, Array rightElement) -> Array (unionNT leftElement rightElement)
  -- an array absorbs a tuple: all element types join into the homogeneous element.
  (Tuple elements, Array element) -> Array (foldr unionNT element elements)
  (Array element, Tuple elements) -> Array (foldr unionNT element elements)

-- | Union (join) of map layers. Data names are unioned (kept separate);
-- 'bare' parts join via 'unionBareObj'.
unionMap :: MapSlot -> MapSlot -> MapSlot
unionMap (MapSlot leftData leftBare) (MapSlot rightData rightBare) =
  MapSlot (Set.union leftData rightData) (unionBareObj leftBare rightBare)

unionBareObj :: BareObj -> BareObj -> BareObj
unionBareObj leftBare rightBare = case (leftBare, rightBare) of
  (NoObj, other) -> other
  (other, NoObj) -> other
  -- covariant join: keep only common labels, types unioned (width); a label
  -- optional in either operand is optional in the join.
  (ClosedObj leftFields, ClosedObj rightFields) ->
    ClosedObj (Map.intersectionWith unionField leftFields rightFields)
  (RecordObj leftValue, RecordObj rightValue) -> RecordObj (unionNT leftValue rightValue)
  -- a record absorbs a closed object: every field value joins into V.
  (ClosedObj fields, RecordObj value) -> RecordObj (foldr (unionNT . (.parameterType)) value (Map.elems fields))
  (RecordObj value, ClosedObj fields) -> RecordObj (foldr (unionNT . (.parameterType)) value (Map.elems fields))
  where
    unionField leftField rightField =
      NormalizedParameter (unionNT leftField.parameterType rightField.parameterType) (leftField.optional || rightField.optional)

-- | Union of function slots.
--
-- Per the user-specified rule: take the **union** of label sets, with each
-- common label's type **intersected** (contravariant in args). Labels only
-- in one side are kept as-is. Requests are unioned.
unionFunctionLayer :: FunctionSlot -> FunctionSlot -> FunctionSlot
unionFunctionLayer leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, other) -> other
  (other, FunctionSlotAbsent) -> other
  -- 'function' (top of the function lattice) absorbs any specific shape.
  (FunctionSlotAny, _) -> FunctionSlotAny
  (_, FunctionSlotAny) -> FunctionSlotAny
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    FunctionSlotOf (unionFunctionShape leftShape rightShape)

unionFunctionShape :: FunctionShape -> FunctionShape -> FunctionShape
unionFunctionShape leftShape rightShape =
  FunctionShape
    { -- Contravariant in the parameter: the union of two function types accepts
      -- only arguments both accept, i.e. the /intersection/ of their parameter
      -- types. (Per-label width / optionality is handled inside the object
      -- lattice by 'intersectNT'.)
      parameter = intersectNT leftShape.parameter rightShape.parameter,
      returnType = unionNT leftShape.returnType rightShape.returnType,
      requests = unionNormalizedEffect leftShape.requests rightShape.requests
    }

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
      secretLayer = leftLayered.secretLayer && rightLayered.secretLayer,
      fileLayer = leftLayered.fileLayer && rightLayered.fileLayer,
      functionLayer = intersectFunctionLayer leftLayered.functionLayer rightLayered.functionLayer,
      seqLayer = intersectSeq leftLayered.seqLayer rightLayered.seqLayer,
      mapLayer = intersectMap leftLayered.mapLayer rightLayered.mapLayer,
      -- Set intersection: incomplete (drops the genuine @T & int@ overlap to
      -- @never@) but sound for the meet, which only narrows.
      genericsLayer = Set.intersection leftLayered.genericsLayer rightLayered.genericsLayer
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

-- | Intersection (meet) of sequence layers. A @tuple ∩ array@ keeps the
-- tuple shape, intersecting each position with the array's element type.
intersectSeq :: BareSeq -> BareSeq -> BareSeq
intersectSeq leftSeq rightSeq = case (leftSeq, rightSeq) of
  (NoSeq, _) -> NoSeq
  (_, NoSeq) -> NoSeq
  -- meet extends to all positions (longer length), common positions intersected.
  (Tuple leftElements, Tuple rightElements) -> Tuple (intersectTupleElements leftElements rightElements)
  (Array leftElement, Array rightElement) -> Array (intersectNT leftElement rightElement)
  -- a tuple ∩ array keeps the tuple, each position intersected with the element.
  (Tuple elements, Array element) -> Tuple (map (`intersectNT` element) elements)
  (Array element, Tuple elements) -> Tuple (map (intersectNT element) elements)

-- | Per-position intersection of two tuples: common positions intersected,
-- trailing positions of the longer tuple kept (max length).
intersectTupleElements :: [NormalizedType] -> [NormalizedType] -> [NormalizedType]
intersectTupleElements leftElements rightElements = case (leftElements, rightElements) of
  ([], rest) -> rest
  (rest, []) -> rest
  (left : leftRest, right : rightRest) ->
    intersectNT left right : intersectTupleElements leftRest rightRest

-- | Intersection of function slots.
--
-- Per the user-specified rule: take the **intersection** of label sets,
-- with each common label's type **unioned** (contravariant in args).
-- Requests are unioned per the spec.
intersectFunctionLayer :: FunctionSlot -> FunctionSlot -> FunctionSlot
intersectFunctionLayer leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, _) -> FunctionSlotAbsent
  (_, FunctionSlotAbsent) -> FunctionSlotAbsent
  -- 'function' is the function-lattice top; intersecting with it is
  -- the identity (any specific shape ⊆ function).
  (FunctionSlotAny, other) -> other
  (other, FunctionSlotAny) -> other
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    FunctionSlotOf (intersectFunctionShape leftShape rightShape)

intersectFunctionShape :: FunctionShape -> FunctionShape -> FunctionShape
intersectFunctionShape leftShape rightShape =
  FunctionShape
    { -- Contravariant in the parameter: the intersection of two function types
      -- accepts arguments either accepts, i.e. the /union/ of their parameter
      -- types. (Per-label width / optionality is handled inside the object
      -- lattice by 'unionNT'.)
      parameter = unionNT leftShape.parameter rightShape.parameter,
      returnType = intersectNT leftShape.returnType rightShape.returnType,
      requests = intersectNormalizedEffect leftShape.requests rightShape.requests
    }

-- | Intersection (meet) of map layers. Data names are intersected; 'bare'
-- parts meet via 'intersectBareObj'.
intersectMap :: MapSlot -> MapSlot -> MapSlot
intersectMap (MapSlot leftData leftBare) (MapSlot rightData rightBare) =
  MapSlot (Set.intersection leftData rightData) (intersectBareObj leftBare rightBare)

intersectBareObj :: BareObj -> BareObj -> BareObj
intersectBareObj leftBare rightBare = case (leftBare, rightBare) of
  (NoObj, _) -> NoObj
  (_, NoObj) -> NoObj
  -- meet: union of labels, common intersected, single-side kept; a common
  -- label is optional only when optional in both operands.
  (ClosedObj leftFields, ClosedObj rightFields) ->
    ClosedObj (Map.unionWith intersectField leftFields rightFields)
  (RecordObj leftValue, RecordObj rightValue) -> RecordObj (intersectNT leftValue rightValue)
  -- record ∩ closed object: keep the object, each field intersected with V.
  (ClosedObj fields, RecordObj value) -> ClosedObj (Map.map (intersectFieldType (`intersectNT` value)) fields)
  (RecordObj value, ClosedObj fields) -> ClosedObj (Map.map (intersectFieldType (intersectNT value)) fields)
  where
    intersectField leftField rightField =
      NormalizedParameter (intersectNT leftField.parameterType rightField.parameterType) (leftField.optional && rightField.optional)
    intersectFieldType f field = NormalizedParameter (f field.parameterType) field.optional

-- ---------------------------------------------------------------------------
-- Subtype check
-- ---------------------------------------------------------------------------

-- | Read-only env mapping each @data@ type's qualified name to its
-- normalized fields (an object view). Recursive @data@ references inside a
-- field normalize to name-only map slots, so each entry is finite; the
-- subtype check below stays well-founded because a recursive occurrence is
-- compared by name (rule i) rather than re-expanded. Built once by the
-- solver from the resolved constructor signatures.
type DataFieldEnv = Map QualifiedName (Map Text NormalizedParameter)

-- | Build a 'DataFieldEnv' from a resolved type environment. A @data@
-- constructor is the unique entry whose qualified name equals its returned
-- @data@ type's name (an ordinary agent returning a data value has a
-- different name), so it is identified without a separate constructor table;
-- its parameters (type + optionality) become that data type's normalized
-- fields — an optional field (@name ?: T@) may be omitted from the value.
buildDataFieldEnv :: Map QualifiedName (SemanticType Resolved) -> DataFieldEnv
buildDataFieldEnv typeEnv =
  Map.fromList
    [ (dataQName, Map.map normaliseField (functionParameters parameterObject))
      | (constructorQName, SemanticTypeFunction parameterObject (SemanticTypeData dataQName) _) <- Map.toList typeEnv,
        constructorQName == dataQName
    ]

-- | Read-only env mapping each in-scope generic parameter to the (normalized)
-- upper bound of its @extends@ clause. Consulted by 'subtypeNormalizedType' to
-- expand a generic on the subtype side. @Map.findWithDefault@ treats a missing
-- entry as 'NormalizedTypeUnknown' (the default @extends unknown@).
type BoundEnv = Map GenericsId NormalizedType

-- | @subtypeNormalizedType env boundEnv leftType rightType@ holds when every
-- value of @leftType@ is also a value of @rightType@. A per-layer check; @env@
-- is consulted for the @data <: object@ edge and @boundEnv@ for generic
-- expansion. All the per-layer helpers are nested in 'go''s @where@ so they
-- share @env@ implicitly.
subtypeNormalizedType :: DataFieldEnv -> BoundEnv -> NormalizedType -> NormalizedType -> Bool
subtypeNormalizedType env boundEnv = go
  where
    go leftType rightType = case (leftType, rightType) of
      (_, NormalizedTypeUnknown) -> True
      (NormalizedTypeUnknown, _) -> False
      (NormalizedTypeLayered leftLayered, NormalizedTypeLayered rightLayered) ->
        -- Expand the LHS's generics (cancel those shared with the RHS, replace
        -- the rest by their bounds) until none remain, then compare with the
        -- RHS's generics dropped (a RHS-only generic cannot help cover the LHS
        -- — sound, completeness-losing).
        case expandLeftGenerics boundEnv rightLayered.genericsLayer leftLayered of
          NormalizedTypeUnknown -> False
          NormalizedTypeLayered leftExpanded ->
            subtypeLayered leftExpanded rightLayered {genericsLayer = Set.empty}

    subtypeLayered leftLayered rightLayered =
      Set.isSubsetOf leftLayered.genericsLayer rightLayered.genericsLayer
        && subtypeNumberSlot leftLayered.numberLayer rightLayered.numberLayer
        && subtypeStringSlot leftLayered.stringLayer rightLayered.stringLayer
        && Set.isSubsetOf leftLayered.booleanLayer rightLayered.booleanLayer
        && (not leftLayered.nullLayer || rightLayered.nullLayer)
        && (not leftLayered.secretLayer || rightLayered.secretLayer)
        && (not leftLayered.fileLayer || rightLayered.fileLayer)
        && subtypeFunctionLayer leftLayered.functionLayer rightLayered.functionLayer
        && subtypeSeq leftLayered.seqLayer rightLayered.seqLayer
        && subtypeMap leftLayered.mapLayer rightLayered.mapLayer

    -- | Sequence layer. A tuple refines an array whose element covers all
    -- positions; an array is never a subtype of a tuple. Width: a longer
    -- tuple refines a shorter prefix.
    subtypeSeq leftSeq rightSeq = case (leftSeq, rightSeq) of
      (NoSeq, _) -> True
      (_, NoSeq) -> False
      (Tuple leftElements, Tuple rightElements) ->
        length leftElements >= length rightElements
          && and (zipWith go leftElements rightElements)
      (Tuple leftElements, Array rightElement) ->
        all (`go` rightElement) leftElements
      (Array _, Tuple _) -> False
      (Array leftElement, Array rightElement) -> go leftElement rightElement

    -- | Map layer. Each left @data@ either appears on the right (rule i) or
    -- its object view is a subtype of the right's structural part (rule ii,
    -- @data <: object@ — consulting 'env'). Object width subtyping plus
    -- @object <: record@; a record is never a subtype of a closed object.
    subtypeMap (MapSlot leftData leftBare) (MapSlot rightData rightBare) =
      all dataMatches (Set.toList leftData) && subtypeBareObj leftBare rightBare
      where
        dataMatches qualifiedName =
          Set.member qualifiedName rightData
            || subtypeBareObj (ClosedObj (dataObjectView qualifiedName)) rightBare
        dataObjectView qualifiedName = Map.findWithDefault Map.empty qualifiedName env

    subtypeBareObj leftBare rightBare = case (leftBare, rightBare) of
      (NoObj, _) -> True
      (_, NoObj) -> False
      (ClosedObj leftFields, ClosedObj rightFields) ->
        -- width: every required field of right is present in left with a
        -- compatible type; a right field that is optional may be absent in
        -- left, and a left field that is optional cannot satisfy a required
        -- right field (it might be absent). Left's extra fields are ignored.
        all (checkField leftFields) (Map.toList rightFields)
      (ClosedObj leftFields, RecordObj rightValue) ->
        all (\field -> go field.parameterType rightValue) (Map.elems leftFields)
      (RecordObj _, ClosedObj _) -> False
      (RecordObj leftValue, RecordObj rightValue) -> go leftValue rightValue
      where
        checkField leftFields (fieldName, rightField) =
          case Map.lookup fieldName leftFields of
            Just leftField ->
              (rightField.optional || not leftField.optional)
                && go leftField.parameterType rightField.parameterType
            Nothing -> rightField.optional

    subtypeFunctionLayer leftSlot rightSlot = case (leftSlot, rightSlot) of
      (FunctionSlotAbsent, _) -> True
      (_, FunctionSlotAbsent) -> False
      (_, FunctionSlotAny) -> True
      (FunctionSlotAny, FunctionSlotOf _) -> False
      (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
        subtypeFunctionShape leftShape rightShape

    -- Contravariant parameter, covariant return, covariant request set. The
    -- parameter type is a single type; the object lattice (via 'go') handles
    -- per-label width / optionality, so this is just a contravariant edge.
    subtypeFunctionShape leftShape rightShape =
      go rightShape.parameter leftShape.parameter
        && go leftShape.returnType rightShape.returnType
        && subtypeEffect leftShape.requests rightShape.requests

-- | Expand a layered type's generics until its generics layer is empty, for
-- use on the subtype (LHS) side. Generics also present on the RHS cancel (a
-- generic is a subtype of itself); each remaining LHS-only generic is replaced
-- by the union of its declared upper bound. A bound may itself introduce
-- further generics, which are expanded on the next iteration — the @extends@
-- relation is acyclic, so the loop terminates. A generic whose bound is
-- 'NormalizedTypeUnknown' (the default) lifts the whole type to the top.
-- | Expand a type's outermost generics to their declared bounds (no
-- cancellation set), leaving generics nested inside other layers untouched.
-- Used to project a generic scrutinee in a @match@: @T extends [int, string]@
-- becomes the tuple shape so a tuple pattern can read its components. The
-- recursion that walks into nested patterns expands each level in turn, so a
-- nested generic is handled when it becomes the next scrutinee.
expandGenerics :: BoundEnv -> NormalizedType -> NormalizedType
expandGenerics _ NormalizedTypeUnknown = NormalizedTypeUnknown
expandGenerics boundEnv (NormalizedTypeLayered layered) = expandLeftGenerics boundEnv Set.empty layered

expandLeftGenerics :: BoundEnv -> Set GenericsId -> LayeredType -> NormalizedType
expandLeftGenerics boundEnv rhsGenerics = loop
  where
    loop layered
      | Set.null layered.genericsLayer = NormalizedTypeLayered layered
      | otherwise =
          let lhsOnly = Set.difference layered.genericsLayer rhsGenerics
              -- Drop all generics (shared ones cancel); re-add the LHS-only
              -- ones via their bounds.
              cleared = NormalizedTypeLayered layered {genericsLayer = Set.empty}
              expanded = foldr (unionNT . boundOf) cleared (Set.toList lhsOnly)
           in case expanded of
                NormalizedTypeUnknown -> NormalizedTypeUnknown
                NormalizedTypeLayered layered' -> loop layered'
    boundOf genericsId = Map.findWithDefault NormalizedTypeUnknown genericsId boundEnv

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
