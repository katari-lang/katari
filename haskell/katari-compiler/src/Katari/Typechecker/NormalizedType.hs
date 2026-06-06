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
    dataParamIdsOf,
    Variance (..),
    variancesOf,
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
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Common (QualifiedName)
import Katari.Id (GenericsId)
import Katari.SemanticType (Parameter (..), Resolved, SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..), functionParameters, substituteGenerics, unionEffects)

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
--   * 'RecordObj' — the @record@ type: the top of the structural map part (any
--     map value; @{l: T} <: record@ always, soundly, since @record@ promises
--     nothing about field types — reads yield @unknown@). Absorbs closed
--     objects on union. Nullary (no element type).
-- | The structural object's fields reuse 'NormalizedParameter' (a parameter
-- signature is, semantically, an object): each field is a type plus whether it
-- is optional (may be absent).
data BareObj
  = NoObj
  | ClosedObj (Map Text NormalizedParameter)
  | RecordObj
  deriving (Eq, Show)

-- | A required (non-optional) normalized field.
requiredNormalizedField :: NormalizedType -> NormalizedParameter
requiredNormalizedField parameterType = NormalizedParameter {parameterType = parameterType, optional = False}

-- | Normalise / denormalise a single object field (preserving optionality).
normaliseField :: DataFieldEnv -> Parameter Resolved -> NormalizedParameter
normaliseField env field = NormalizedParameter (normaliseSemantic env field.parameterType) field.optional

denormaliseField :: NormalizedParameter -> Parameter Resolved
denormaliseField field = Parameter (denormalise field.parameterType) field.optional

-- | Variance of a generic parameter — how the whole type relates when the arg
-- at that position is replaced by a subtype. Lattice @bivariant \<:
-- {covariant, contravariant} \<: invariant@ (bivariant most permissive,
-- invariant most restrictive). Drives union / intersect / subtype of two
-- applications of the same generic @data@.
data Variance = Covariant | Contravariant | Invariant | Bivariant
  deriving (Eq, Show)

-- | One argument applied to a generic @data@ in the normalised form — a
-- normalised type or effect (mirrors 'SemanticGenericArgument').
data NormalizedGenericArg
  = NormalizedGenericArgType NormalizedType
  | NormalizedGenericArgEffect NormalizedEffect
  deriving (Eq, Show)

-- | Map layer — object, record and @data@ merged into one layer.
--
--   * 'dataApps' maps each @data@ type name inhabiting this type (the
--     discriminated-union part) to its applied type / effect arguments (empty
--     for non-generic @data@). One entry per name: two applications of the same
--     @data@ with differing args are combined per the parameters' variance
--     (see 'unionBareObj'-level data handling), collapsing to one entry or to
--     'NormalizedTypeUnknown' (invariant mismatch). A data's concrete fields are
--     looked up on demand from the data env during subtyping (the @data \<:
--     object@ rule, args substituted), keeping recursive @data@ finite.
--   * 'bare' is the structural part ('BareObj'), kept separate from data names.
data MapSlot = MapSlot
  { dataApps :: Map QualifiedName [NormalizedGenericArg],
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
data NormalizedEffect
  = -- | The effect top — \"any effect\" (surface @all@). Absorbs on union, is the
    -- identity on intersect, covered only by itself. Arises from an
    -- invariant-arg union of generic requests (no representable LUB).
    NormalizedEffectAny
  | -- | A finite union: concrete (possibly generic) @req@ names applied to their
    -- args, plus in-scope @effect@ generics. The @pure@ leaf contributes the
    -- empty rows. The @[Variance]@ baked onto each request (from the data env at
    -- 'normaliseEffect') lets the env-free lattice ops combine two
    -- instantiations of the same request by its parameters' variance.
    NormalizedEffectRows
      { effectConcrete :: Map QualifiedName ([Variance], [NormalizedGenericArg]),
        effectGenerics :: Set GenericsId
      }
  deriving (Eq, Show)

-- | The empty (pure) normalised effect.
emptyNormalizedEffect :: NormalizedEffect
emptyNormalizedEffect = NormalizedEffectRows Map.empty Set.empty

instance Semigroup NormalizedEffect where
  (<>) = unionNormalizedEffect

instance Monoid NormalizedEffect where
  mempty = emptyNormalizedEffect

-- | Union of two normalised effects. @all@ absorbs; two instantiations of the
-- same request combine their args by variance (covariant → union, contravariant
-- → intersect, invariant mismatch → @all@). Env-free: the arg /types/ are
-- combined with an empty data env, so nested generic data with differing args
-- conservatively widens (sound, rarely imprecise).
unionNormalizedEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
unionNormalizedEffect leftEffect rightEffect = case (leftEffect, rightEffect) of
  (NormalizedEffectAny, _) -> NormalizedEffectAny
  (_, NormalizedEffectAny) -> NormalizedEffectAny
  (NormalizedEffectRows leftConcrete leftGenerics, NormalizedEffectRows rightConcrete rightGenerics) ->
    case unionRequestApps leftConcrete rightConcrete of
      Nothing -> NormalizedEffectAny
      Just merged -> NormalizedEffectRows merged (Set.union leftGenerics rightGenerics)

type RequestApps = Map QualifiedName ([Variance], [NormalizedGenericArg])

-- | Merge two request-app maps for a union; 'Nothing' on an invariant mismatch.
unionRequestApps :: RequestApps -> RequestApps -> Maybe RequestApps
unionRequestApps leftConcrete rightConcrete =
  fmap Map.fromList . traverse combine . Set.toList $ Set.union (Map.keysSet leftConcrete) (Map.keysSet rightConcrete)
  where
    combine name = case (Map.lookup name leftConcrete, Map.lookup name rightConcrete) of
      (Just (variances, leftArgs), Just (_, rightArgs)) ->
        (\merged -> (name, (variances, merged))) <$> combineArgs (unionArg Map.empty) variances leftArgs rightArgs
      (Just app, Nothing) -> Just (name, app)
      (Nothing, Just app) -> Just (name, app)
      (Nothing, Nothing) -> Nothing

-- | Intersection of two normalised effects. @all@ is the identity; only shared
-- requests survive, args combined dually (invariant mismatch drops the request).
intersectNormalizedEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
intersectNormalizedEffect leftEffect rightEffect = case (leftEffect, rightEffect) of
  (NormalizedEffectAny, other) -> other
  (other, NormalizedEffectAny) -> other
  (NormalizedEffectRows leftConcrete leftGenerics, NormalizedEffectRows rightConcrete rightGenerics) ->
    NormalizedEffectRows
      ( Map.fromList
          [ (name, (variances, merged))
            | (name, (variances, leftArgs)) <- Map.toList leftConcrete,
              Just (_, rightArgs) <- [Map.lookup name rightConcrete],
              Just merged <- [combineArgs (intersectArg Map.empty) variances leftArgs rightArgs]
          ]
      )
      (Set.intersection leftGenerics rightGenerics)

-- | Remove a set of concrete @req@ names from an effect (used when a @handle@
-- discharges the requests it names). Effect generics are left untouched — a
-- concrete handler cannot statically discharge an abstract generic effect, and
-- keeping it over-approximates the raised effect (sound). @all@ cannot be
-- discharged by a finite handler set.
subtractConcrete :: Set QualifiedName -> NormalizedEffect -> NormalizedEffect
subtractConcrete handled = \case
  NormalizedEffectAny -> NormalizedEffectAny
  NormalizedEffectRows concrete generics -> NormalizedEffectRows (Map.withoutKeys concrete handled) generics

-- | The elements @left@ raises beyond @right@ (for the @with@-coverage report).
-- A request is covered when @right@ names it with args that @left@'s
-- instantiation is a subeffect of (per variance). @all@ minus a finite set is
-- still uncoverable; anything minus @all@ is covered.
differenceNormalizedEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
differenceNormalizedEffect leftEffect rightEffect = case (leftEffect, rightEffect) of
  (_, NormalizedEffectAny) -> emptyNormalizedEffect
  (NormalizedEffectAny, _) -> NormalizedEffectAny
  (NormalizedEffectRows leftConcrete leftGenerics, NormalizedEffectRows rightConcrete rightGenerics) ->
    NormalizedEffectRows
      ( Map.fromList
          [ (name, app)
            | (name, app@(variances, leftArgs)) <- Map.toList leftConcrete,
              case Map.lookup name rightConcrete of
                Just (_, rightArgs) -> not (subtypeRequestArgs variances leftArgs rightArgs)
                Nothing -> True
          ]
      )
      (Set.difference leftGenerics rightGenerics)

-- | True when an effect is exactly @pure@ (no requests, no generics; not @all@).
nullNormalizedEffect :: NormalizedEffect -> Bool
nullNormalizedEffect = \case
  NormalizedEffectAny -> False
  NormalizedEffectRows concrete generics -> Map.null concrete && Set.null generics

-- | @subtypeEffect left right@ — every effect of @left@ is permitted by
-- @right@. @all@ is the top. A left generic cancels only against the same right
-- generic. A left request must appear on the right with args its instantiation
-- is a subeffect of (per variance). Right-only slack is harmless.
subtypeEffect :: NormalizedEffect -> NormalizedEffect -> Bool
subtypeEffect leftEffect rightEffect = case (leftEffect, rightEffect) of
  (_, NormalizedEffectAny) -> True
  (NormalizedEffectAny, _) -> False
  (NormalizedEffectRows leftConcrete leftGenerics, NormalizedEffectRows rightConcrete rightGenerics) ->
    Set.isSubsetOf leftGenerics rightGenerics
      && all requestCovered (Map.toList leftConcrete)
    where
      requestCovered (name, (variances, leftArgs)) = case Map.lookup name rightConcrete of
        Just (_, rightArgs) -> subtypeRequestArgs variances leftArgs rightArgs
        Nothing -> False

-- | Relate two arg lists of the same request by its baked variances (covariant
-- forward, contravariant reversed, invariant both, bivariant always). Env-free.
subtypeRequestArgs :: [Variance] -> [NormalizedGenericArg] -> [NormalizedGenericArg] -> Bool
subtypeRequestArgs variances leftArgs rightArgs =
  length leftArgs == length rightArgs && and (zipWith3 oneArg variances leftArgs rightArgs)
  where
    oneArg variance leftArg rightArg = case variance of
      Covariant -> sub leftArg rightArg
      Contravariant -> sub rightArg leftArg
      Invariant -> sub leftArg rightArg && sub rightArg leftArg
      Bivariant -> True
    sub leftArg rightArg = case (leftArg, rightArg) of
      (NormalizedGenericArgType left, NormalizedGenericArgType right) -> subtypeNormalizedType Map.empty Map.empty left right
      (NormalizedGenericArgEffect left, NormalizedGenericArgEffect right) -> subtypeEffect left right
      _ -> True

-- | Flatten a (resolved) effect tree to its normalised form. Needs the data env
-- to bake each request's parameter variances onto its app entry.
normaliseEffect :: DataFieldEnv -> SemanticEffect Resolved -> NormalizedEffect
normaliseEffect env = \case
  SemanticEffectPure -> emptyNormalizedEffect
  SemanticEffectAll -> NormalizedEffectAny
  SemanticEffectRequest qualifiedName arguments ->
    NormalizedEffectRows (Map.singleton qualifiedName (variancesOf env qualifiedName, map (normaliseArg env) arguments)) Set.empty
  SemanticEffectGeneric genericsId -> NormalizedEffectRows Map.empty (Set.singleton genericsId)
  SemanticEffectUnion branches -> foldr (unionNormalizedEffect . normaliseEffect env) emptyNormalizedEffect branches

-- | Rebuild an effect tree from a normalised effect (concrete leaves then
-- generic leaves, in id order, for determinism).
denormaliseEffect :: NormalizedEffect -> SemanticEffect Resolved
denormaliseEffect = \case
  NormalizedEffectAny -> SemanticEffectAll
  NormalizedEffectRows concrete generics ->
    unionEffects
      ( [SemanticEffectRequest name (map denormaliseArg arguments) | (name, (_, arguments)) <- Map.toList concrete]
          ++ (SemanticEffectGeneric <$> Set.toList generics)
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
emptyMapSlot = MapSlot {dataApps = Map.empty, bare = NoObj}

-- | Denormalise a generic argument back to its 'SemanticGenericArgument'.
denormaliseArg :: NormalizedGenericArg -> SemanticGenericArgument Resolved
denormaliseArg = \case
  NormalizedGenericArgType normalizedType -> SemanticGenericArgumentType (denormalise normalizedType)
  NormalizedGenericArgEffect normalizedEffect -> SemanticGenericArgumentEffect (denormaliseEffect normalizedEffect)

-- | Normalise a generic argument (a type or an effect).
normaliseArg :: DataFieldEnv -> SemanticGenericArgument Resolved -> NormalizedGenericArg
normaliseArg env = \case
  SemanticGenericArgumentType semanticType -> NormalizedGenericArgType (normaliseSemantic env semanticType)
  SemanticGenericArgumentEffect semanticEffect -> NormalizedGenericArgEffect (normaliseEffect env semanticEffect)

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
mapBranches MapSlot {dataApps, bare} =
  [SemanticTypeData qualifiedName (map denormaliseArg arguments) | (qualifiedName, arguments) <- Map.toList dataApps]
    ++ case bare of
      NoObj -> []
      ClosedObj fields -> [SemanticTypeObject (Map.map denormaliseField fields)]
      RecordObj -> [SemanticTypeRecord]

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
isEmptyMap (MapSlot dataApps bare) = Map.null dataApps && case bare of
  NoObj -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Normalisation: SemanticType Resolved -> NormalizedType
-- ---------------------------------------------------------------------------

-- | Convert a fully-resolved 'SemanticType' (no unification variables) into
-- the canonical 'NormalizedType'. Inverse direction of 'denormalise', though
-- the round-trip is not the identity (the product-normalisation rule
-- collapses cross-component correlation in tuple unions).
normaliseSemantic :: DataFieldEnv -> SemanticType Resolved -> NormalizedType
normaliseSemantic env = go
  where
    go = \case
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
        NormalizedTypeLayered emptyLayered {seqLayer = Array (go element)}
      SemanticTypeTuple elements ->
        NormalizedTypeLayered emptyLayered {seqLayer = Tuple (go <$> elements)}
      SemanticTypeData typeId arguments ->
        NormalizedTypeLayered emptyLayered {mapLayer = emptyMapSlot {dataApps = Map.singleton typeId (map (normaliseArg env) arguments)}}
      SemanticTypeGeneric genericsId ->
        NormalizedTypeLayered emptyLayered {genericsLayer = Set.singleton genericsId}
      SemanticTypeObject fields ->
        NormalizedTypeLayered
          emptyLayered
            { mapLayer = emptyMapSlot {bare = ClosedObj (Map.map (normaliseField env) fields)}
            }
      SemanticTypeRecord ->
        NormalizedTypeLayered
          emptyLayered
            { mapLayer = emptyMapSlot {bare = RecordObj}
            }
      SemanticTypeFunction parameterType returnType effect ->
        let shape =
              FunctionShape
                { parameter = go parameterType,
                  returnType = go returnType,
                  requests = normaliseEffect env effect
                }
         in NormalizedTypeLayered emptyLayered {functionLayer = FunctionSlotOf shape}
      SemanticTypeUnion branches ->
        foldr (unionNT env . go) (NormalizedTypeLayered emptyLayered) branches

-- ---------------------------------------------------------------------------
-- Union (least upper bound)
-- ---------------------------------------------------------------------------

-- | Pointwise union of two normalized types. Carries the data env so the
-- @data@ layer can combine same-name applications by their parameters' variance.
unionNT :: DataFieldEnv -> NormalizedType -> NormalizedType -> NormalizedType
unionNT env leftType rightType = case (leftType, rightType) of
  (NormalizedTypeUnknown, _) -> NormalizedTypeUnknown
  (_, NormalizedTypeUnknown) -> NormalizedTypeUnknown
  (NormalizedTypeLayered leftLayered, NormalizedTypeLayered rightLayered) ->
    -- The map layer's @data@ combine can fail (invariant args mismatch), in
    -- which case the whole union has no representable supertype but @unknown@.
    case unionMap env leftLayered.mapLayer rightLayered.mapLayer of
      Nothing -> NormalizedTypeUnknown
      Just mergedMap -> NormalizedTypeLayered (unionLayered env leftLayered rightLayered) {mapLayer = mergedMap}

-- | Union of every non-map layer (the map layer is handled by 'unionMap' in
-- 'unionNT', since it may collapse the whole type to @unknown@).
unionLayered :: DataFieldEnv -> LayeredType -> LayeredType -> LayeredType
unionLayered env leftLayered rightLayered =
  LayeredType
    { numberLayer = unionNumberSlot leftLayered.numberLayer rightLayered.numberLayer,
      stringLayer = unionStringSlot leftLayered.stringLayer rightLayered.stringLayer,
      booleanLayer = Set.union leftLayered.booleanLayer rightLayered.booleanLayer,
      nullLayer = leftLayered.nullLayer || rightLayered.nullLayer,
      secretLayer = leftLayered.secretLayer || rightLayered.secretLayer,
      fileLayer = leftLayered.fileLayer || rightLayered.fileLayer,
      functionLayer = unionFunctionLayer env leftLayered.functionLayer rightLayered.functionLayer,
      seqLayer = unionSeq env leftLayered.seqLayer rightLayered.seqLayer,
      mapLayer = emptyMapSlot, -- overwritten by 'unionNT'
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
unionSeq :: DataFieldEnv -> BareSeq -> BareSeq -> BareSeq
unionSeq env leftSeq rightSeq = case (leftSeq, rightSeq) of
  (NoSeq, other) -> other
  (other, NoSeq) -> other
  -- join collapses to the common prefix (shorter length), positions unioned.
  (Tuple leftElements, Tuple rightElements) -> Tuple (zipWith (unionNT env) leftElements rightElements)
  (Array leftElement, Array rightElement) -> Array (unionNT env leftElement rightElement)
  -- an array absorbs a tuple: all element types join into the homogeneous element.
  (Tuple elements, Array element) -> Array (foldr (unionNT env) element elements)
  (Array element, Tuple elements) -> Array (foldr (unionNT env) element elements)

-- | Union (join) of map layers. Distinct data names coexist; a shared data name
-- combines its args by the parameters' variance. 'Nothing' signals an
-- invariant-arg mismatch (no representable supertype but @unknown@).
unionMap :: DataFieldEnv -> MapSlot -> MapSlot -> Maybe MapSlot
unionMap env (MapSlot leftData leftBare) (MapSlot rightData rightBare) = do
  mergedData <- unionDataApps env leftData rightData
  pure (MapSlot mergedData (unionBareObj env leftBare rightBare))

-- | Combine two @data@-application maps for a union. Shared names combine
-- arg-wise by variance; distinct names coexist. 'Nothing' = invariant mismatch.
unionDataApps ::
  DataFieldEnv ->
  Map QualifiedName [NormalizedGenericArg] ->
  Map QualifiedName [NormalizedGenericArg] ->
  Maybe (Map QualifiedName [NormalizedGenericArg])
unionDataApps env leftData rightData =
  fmap Map.fromList . traverse combine . Set.toList $ Set.union (Map.keysSet leftData) (Map.keysSet rightData)
  where
    combine dataQName = case (Map.lookup dataQName leftData, Map.lookup dataQName rightData) of
      (Just leftArgs, Just rightArgs) ->
        (dataQName,) <$> combineArgs (unionArg env) (variancesOfList' env dataQName) leftArgs rightArgs
      (Just leftArgs, Nothing) -> Just (dataQName, leftArgs)
      (Nothing, Just rightArgs) -> Just (dataQName, rightArgs)
      (Nothing, Nothing) -> Nothing

-- | Combine two arg lists position-wise with @per@; 'Nothing' if a position
-- fails (invariant mismatch) or the arities differ.
combineArgs ::
  (Variance -> NormalizedGenericArg -> NormalizedGenericArg -> Maybe NormalizedGenericArg) ->
  [Variance] ->
  [NormalizedGenericArg] ->
  [NormalizedGenericArg] ->
  Maybe [NormalizedGenericArg]
combineArgs per variances leftArgs rightArgs
  | length leftArgs /= length rightArgs = Nothing
  -- Pad variances with 'Invariant' (the conservative default) so a short / empty
  -- variance list (e.g. a request whose variances aren't yet in the env) still
  -- combines soundly rather than truncating the args.
  | otherwise = sequence (zipWith3 per (variances ++ repeat Invariant) leftArgs rightArgs)

-- | Union-combine one @data@ argument by its variance. Covariant / bivariant
-- join; contravariant meet; invariant requires equality.
unionArg :: DataFieldEnv -> Variance -> NormalizedGenericArg -> NormalizedGenericArg -> Maybe NormalizedGenericArg
unionArg env variance leftArg rightArg = case variance of
  Covariant -> Just (joinArg env leftArg rightArg)
  Bivariant -> Just (joinArg env leftArg rightArg)
  Contravariant -> Just (meetArg env leftArg rightArg)
  Invariant -> if leftArg == rightArg then Just leftArg else Nothing

-- | Intersect-combine one @data@ argument by its variance (dual of 'unionArg').
intersectArg :: DataFieldEnv -> Variance -> NormalizedGenericArg -> NormalizedGenericArg -> Maybe NormalizedGenericArg
intersectArg env variance leftArg rightArg = case variance of
  Covariant -> Just (meetArg env leftArg rightArg)
  Bivariant -> Just (meetArg env leftArg rightArg)
  Contravariant -> Just (joinArg env leftArg rightArg)
  Invariant -> if leftArg == rightArg then Just leftArg else Nothing

-- | Join (union) of one argument. Mixed kinds cannot occur (same parameter slot).
joinArg :: DataFieldEnv -> NormalizedGenericArg -> NormalizedGenericArg -> NormalizedGenericArg
joinArg env leftArg rightArg = case (leftArg, rightArg) of
  (NormalizedGenericArgType a, NormalizedGenericArgType b) -> NormalizedGenericArgType (unionNT env a b)
  (NormalizedGenericArgEffect a, NormalizedGenericArgEffect b) -> NormalizedGenericArgEffect (unionNormalizedEffect a b)
  _ -> leftArg

-- | Meet (intersection) of one argument.
meetArg :: DataFieldEnv -> NormalizedGenericArg -> NormalizedGenericArg -> NormalizedGenericArg
meetArg env leftArg rightArg = case (leftArg, rightArg) of
  (NormalizedGenericArgType a, NormalizedGenericArgType b) -> NormalizedGenericArgType (intersectNT env a b)
  (NormalizedGenericArgEffect a, NormalizedGenericArgEffect b) -> NormalizedGenericArgEffect (intersectNormalizedEffect a b)
  _ -> leftArg

-- | Variances of a data, padded with 'Invariant' so a longer arg list still
-- combines soundly (the conservative default).
variancesOfList' :: DataFieldEnv -> QualifiedName -> [Variance]
variancesOfList' env dataQName = variancesOf env dataQName ++ repeat Invariant

unionBareObj :: DataFieldEnv -> BareObj -> BareObj -> BareObj
unionBareObj env leftBare rightBare = case (leftBare, rightBare) of
  (NoObj, other) -> other
  (other, NoObj) -> other
  -- covariant join: keep only common labels, types unioned (width); a label
  -- optional in either operand is optional in the join.
  (ClosedObj leftFields, ClosedObj rightFields) ->
    ClosedObj (Map.intersectionWith unionField leftFields rightFields)
  -- 'record' is the map-layer top: it absorbs any object on union.
  (RecordObj, _) -> RecordObj
  (_, RecordObj) -> RecordObj
  where
    unionField leftField rightField =
      NormalizedParameter (unionNT env leftField.parameterType rightField.parameterType) (leftField.optional || rightField.optional)

-- | Union of function slots.
--
-- Per the user-specified rule: take the **union** of label sets, with each
-- common label's type **intersected** (contravariant in args). Labels only
-- in one side are kept as-is. Requests are unioned.
unionFunctionLayer :: DataFieldEnv -> FunctionSlot -> FunctionSlot -> FunctionSlot
unionFunctionLayer env leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, other) -> other
  (other, FunctionSlotAbsent) -> other
  -- 'function' (top of the function lattice) absorbs any specific shape.
  (FunctionSlotAny, _) -> FunctionSlotAny
  (_, FunctionSlotAny) -> FunctionSlotAny
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    FunctionSlotOf (unionFunctionShape env leftShape rightShape)

unionFunctionShape :: DataFieldEnv -> FunctionShape -> FunctionShape -> FunctionShape
unionFunctionShape env leftShape rightShape =
  FunctionShape
    { -- Contravariant in the parameter: the union of two function types accepts
      -- only arguments both accept, i.e. the /intersection/ of their parameter
      -- types. (Per-label width / optionality is handled inside the object
      -- lattice by 'intersectNT'.)
      parameter = intersectNT env leftShape.parameter rightShape.parameter,
      returnType = unionNT env leftShape.returnType rightShape.returnType,
      requests = unionNormalizedEffect leftShape.requests rightShape.requests
    }

-- ---------------------------------------------------------------------------
-- Intersection (greatest lower bound)
-- ---------------------------------------------------------------------------

-- | Pointwise intersection of two normalized types. Carries the data env for
-- the variance-aware @data@ combine.
intersectNT :: DataFieldEnv -> NormalizedType -> NormalizedType -> NormalizedType
intersectNT env leftType rightType = case (leftType, rightType) of
  (NormalizedTypeUnknown, other) -> other
  (other, NormalizedTypeUnknown) -> other
  (NormalizedTypeLayered leftLayered, NormalizedTypeLayered rightLayered) ->
    NormalizedTypeLayered (intersectLayered env leftLayered rightLayered)

intersectLayered :: DataFieldEnv -> LayeredType -> LayeredType -> LayeredType
intersectLayered env leftLayered rightLayered =
  LayeredType
    { numberLayer = intersectNumberSlot leftLayered.numberLayer rightLayered.numberLayer,
      stringLayer = intersectStringSlot leftLayered.stringLayer rightLayered.stringLayer,
      booleanLayer = Set.intersection leftLayered.booleanLayer rightLayered.booleanLayer,
      nullLayer = leftLayered.nullLayer && rightLayered.nullLayer,
      secretLayer = leftLayered.secretLayer && rightLayered.secretLayer,
      fileLayer = leftLayered.fileLayer && rightLayered.fileLayer,
      functionLayer = intersectFunctionLayer env leftLayered.functionLayer rightLayered.functionLayer,
      seqLayer = intersectSeq env leftLayered.seqLayer rightLayered.seqLayer,
      mapLayer = intersectMap env leftLayered.mapLayer rightLayered.mapLayer,
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
intersectSeq :: DataFieldEnv -> BareSeq -> BareSeq -> BareSeq
intersectSeq env leftSeq rightSeq = case (leftSeq, rightSeq) of
  (NoSeq, _) -> NoSeq
  (_, NoSeq) -> NoSeq
  -- meet extends to all positions (longer length), common positions intersected.
  (Tuple leftElements, Tuple rightElements) -> Tuple (intersectTupleElements env leftElements rightElements)
  (Array leftElement, Array rightElement) -> Array (intersectNT env leftElement rightElement)
  -- a tuple ∩ array keeps the tuple, each position intersected with the element.
  (Tuple elements, Array element) -> Tuple (map (\e -> intersectNT env e element) elements)
  (Array element, Tuple elements) -> Tuple (map (intersectNT env element) elements)

-- | Per-position intersection of two tuples: common positions intersected,
-- trailing positions of the longer tuple kept (max length).
intersectTupleElements :: DataFieldEnv -> [NormalizedType] -> [NormalizedType] -> [NormalizedType]
intersectTupleElements env leftElements rightElements = case (leftElements, rightElements) of
  ([], rest) -> rest
  (rest, []) -> rest
  (left : leftRest, right : rightRest) ->
    intersectNT env left right : intersectTupleElements env leftRest rightRest

-- | Intersection of function slots.
--
-- Per the user-specified rule: take the **intersection** of label sets,
-- with each common label's type **unioned** (contravariant in args).
-- Requests are unioned per the spec.
intersectFunctionLayer :: DataFieldEnv -> FunctionSlot -> FunctionSlot -> FunctionSlot
intersectFunctionLayer env leftSlot rightSlot = case (leftSlot, rightSlot) of
  (FunctionSlotAbsent, _) -> FunctionSlotAbsent
  (_, FunctionSlotAbsent) -> FunctionSlotAbsent
  -- 'function' is the function-lattice top; intersecting with it is
  -- the identity (any specific shape ⊆ function).
  (FunctionSlotAny, other) -> other
  (other, FunctionSlotAny) -> other
  (FunctionSlotOf leftShape, FunctionSlotOf rightShape) ->
    FunctionSlotOf (intersectFunctionShape env leftShape rightShape)

intersectFunctionShape :: DataFieldEnv -> FunctionShape -> FunctionShape -> FunctionShape
intersectFunctionShape env leftShape rightShape =
  FunctionShape
    { -- Contravariant in the parameter: the intersection of two function types
      -- accepts arguments either accepts, i.e. the /union/ of their parameter
      -- types. (Per-label width / optionality is handled inside the object
      -- lattice by 'unionNT'.)
      parameter = unionNT env leftShape.parameter rightShape.parameter,
      returnType = intersectNT env leftShape.returnType rightShape.returnType,
      requests = intersectNormalizedEffect leftShape.requests rightShape.requests
    }

-- | Intersection (meet) of map layers. Only shared data names survive (a value
-- inhabiting both must be of a data both name), each combining its args by
-- variance (an invariant mismatch drops the name — empty meet); 'bare' parts
-- meet via 'intersectBareObj'.
intersectMap :: DataFieldEnv -> MapSlot -> MapSlot -> MapSlot
intersectMap env (MapSlot leftData leftBare) (MapSlot rightData rightBare) =
  MapSlot (intersectDataApps env leftData rightData) (intersectBareObj env leftBare rightBare)

-- | Combine two @data@-application maps for an intersection: only shared names,
-- args combined by variance; an invariant mismatch drops the name (empty meet).
intersectDataApps ::
  DataFieldEnv ->
  Map QualifiedName [NormalizedGenericArg] ->
  Map QualifiedName [NormalizedGenericArg] ->
  Map QualifiedName [NormalizedGenericArg]
intersectDataApps env leftData rightData =
  Map.fromList
    [ (dataQName, combined)
      | (dataQName, leftArgs) <- Map.toList leftData,
        Just rightArgs <- [Map.lookup dataQName rightData],
        Just combined <- [combineArgs (intersectArg env) (variancesOfList' env dataQName) leftArgs rightArgs]
    ]

intersectBareObj :: DataFieldEnv -> BareObj -> BareObj -> BareObj
intersectBareObj env leftBare rightBare = case (leftBare, rightBare) of
  (NoObj, _) -> NoObj
  (_, NoObj) -> NoObj
  -- meet: union of labels, common intersected, single-side kept; a common
  -- label is optional only when optional in both operands.
  (ClosedObj leftFields, ClosedObj rightFields) ->
    ClosedObj (Map.unionWith intersectField leftFields rightFields)
  -- 'record' is the map-layer top: meet with it keeps the other operand.
  (RecordObj, other) -> other
  (other, RecordObj) -> other
  where
    intersectField leftField rightField =
      NormalizedParameter (intersectNT env leftField.parameterType rightField.parameterType) (leftField.optional && rightField.optional)

-- ---------------------------------------------------------------------------
-- Subtype check
-- ---------------------------------------------------------------------------

-- | Per-@data@ info consulted by the lattice ops:
--
--   * 'dataParamIds' — the generic parameters' ids, positional (matching the
--     declaration's @typeParameters@ and the application args).
--   * 'dataVariances' — each parameter's variance (inferred from field
--     positions, see 'inferVariances'), positional.
--   * 'dataFields' — the constructor's field types, kept **un-normalized**
--     (generics intact) so subtyping can substitute a use site's args into them
--     before normalising; storing them normalised would require the very env we
--     are building (a circularity).
data DataInfo = DataInfo
  { dataParamIds :: [GenericsId],
    dataVariances :: [Variance],
    dataFields :: Map Text (SemanticType Resolved)
  }
  deriving (Show)

-- | Read-only env mapping each @data@ type's qualified name to its 'DataInfo'.
-- Built once from the resolved constructor signatures, threaded through
-- normalize / union / intersect / subtype so a generic @data@'s args drive both
-- the variance combine and the @data \<: object@ field view. Recursive @data@
-- references inside a field stay well-founded: the subtype check compares a
-- recursive occurrence by name + args (rule i) rather than re-expanding.
type DataFieldEnv = Map QualifiedName DataInfo

-- | A data's parameter variances (positional); empty (→ treated as invariant by
-- the combine) for an unknown / non-generic data.
variancesOf :: DataFieldEnv -> QualifiedName -> [Variance]
variancesOf env qualifiedName = maybe [] (.dataVariances) (Map.lookup qualifiedName env)

-- | A data's generic parameter ids (positional), for substituting a use site's
-- application args into its field types (field access / match binding). Empty
-- for an unknown / non-generic data.
dataParamIdsOf :: DataFieldEnv -> QualifiedName -> [GenericsId]
dataParamIdsOf env qualifiedName = maybe [] (.dataParamIds) (Map.lookup qualifiedName env)

-- | Build a 'DataFieldEnv' from a resolved type environment. A @data@
-- constructor is the unique entry whose qualified name equals its returned
-- @data@ type's name; its parameter types become that data's (un-normalized)
-- fields, and its return type @data foo[T…]@ carries the parameter ids (each a
-- self-applied @SemanticTypeGeneric@ / @SemanticEffectGeneric@). Variances are
-- inferred from field positions (see 'inferVariances').
--
-- Every field is a /present/ field of the value (a constructor fills any
-- omitted optional / defaulted field), so optionality lives on the call
-- signature, not the value's object view (the field type already reflects it,
-- @null | T@ for a @?:@ field).
buildDataFieldEnv :: Map QualifiedName (SemanticType Resolved) -> DataFieldEnv
buildDataFieldEnv typeEnv =
  let -- @data@ constructors: the entry whose return is its own data type. Its
      -- fields are the value's object view; each field is a covariant (positive)
      -- position for variance inference.
      dataDecls =
        [ (dataQName, mapMaybe argGenericId returnArgs, fields, [(fieldType, Pos) | fieldType <- Map.elems fields])
          | (constructorQName, SemanticTypeFunction parameterObject (SemanticTypeData dataQName returnArgs) _) <- Map.toList typeEnv,
            constructorQName == dataQName,
            let fields = Map.map (.parameterType) (functionParameters parameterObject)
        ]
      -- @request@ declarations: the entry whose own effect is itself. The effect
      -- sits in a negative position, so the request parameter is covariant (scan
      -- at 'Pos') and the return contravariant (scan at 'Neg'); the self-effect
      -- itself is not scanned. Requests have no object-view fields.
      requestDecls =
        [ (requestQName, mapMaybe argGenericId selfArgs, [(parameterObject, Pos), (returnType, Neg)])
          | (entryQName, SemanticTypeFunction parameterObject returnType (SemanticEffectRequest requestQName selfArgs)) <- Map.toList typeEnv,
            entryQName == requestQName
        ]
      paramIdsByName =
        Map.fromList ([(qn, ids) | (qn, ids, _, _) <- dataDecls] ++ [(qn, ids) | (qn, ids, _) <- requestDecls])
      scanTargetsByName =
        Map.fromList ([(qn, targets) | (qn, _, _, targets) <- dataDecls] ++ [(qn, targets) | (qn, _, targets) <- requestDecls])
      variancesByName = inferVariances paramIdsByName scanTargetsByName
      info qn ids fields = DataInfo {dataParamIds = ids, dataVariances = Map.findWithDefault [] qn variancesByName, dataFields = fields}
   in Map.fromList
        ( [(qn, info qn ids fields) | (qn, ids, fields, _) <- dataDecls]
            ++ [(qn, info qn ids Map.empty) | (qn, ids, _) <- requestDecls]
        )
  where
    argGenericId = \case
      SemanticGenericArgumentType (SemanticTypeGeneric genericsId) -> Just genericsId
      SemanticGenericArgumentEffect (SemanticEffectGeneric genericsId) -> Just genericsId
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- Variance inference
-- ---------------------------------------------------------------------------

-- | A position's polarity during the variance scan. A generic parameter is
-- covariant if it only ever occurs positively, contravariant if only
-- negatively, invariant if both, bivariant if never.
data Polarity = Pos | Neg
  deriving (Eq, Ord, Show)

flipPolarity :: Polarity -> Polarity
flipPolarity = \case Pos -> Neg; Neg -> Pos

-- | Infer each @data@'s parameter variances by a position-sign scan over its
-- field types, with a least-fixpoint over (mutually) recursive @data@
-- references. Parameters start at 'Bivariant' (no occurrence yet) and only ever
-- widen toward 'Invariant', so the iteration converges.
inferVariances ::
  Map QualifiedName [GenericsId] ->
  Map QualifiedName [(SemanticType Resolved, Polarity)] ->
  Map QualifiedName [Variance]
inferVariances paramIdsByName scanTargetsByName = fixpoint (Map.map (map (const Bivariant)) paramIdsByName)
  where
    fixpoint estimates =
      let next = Map.mapWithKey (\declQName paramIds -> map (paramVariance estimates declQName) paramIds) paramIdsByName
       in if next == estimates then next else fixpoint next
    paramVariance estimates declQName paramId =
      signsToVariance
        (foldMap (\(scanType, polarity) -> signsOfType estimates paramId polarity scanType) (Map.findWithDefault [] declQName scanTargetsByName))

signsToVariance :: Set Polarity -> Variance
signsToVariance signs
  | signs == Set.fromList [Pos, Neg] = Invariant
  | signs == Set.singleton Pos = Covariant
  | signs == Set.singleton Neg = Contravariant
  | otherwise = Bivariant

-- | The set of polarities at which @target@ (a type- or effect-generic id)
-- occurs in @semanticType@, given the ambient polarity. Nested @data@ args
-- compose the ambient polarity with that arg's (estimated) variance.
signsOfType :: Map QualifiedName [Variance] -> GenericsId -> Polarity -> SemanticType Resolved -> Set Polarity
signsOfType estimates target polarity = \case
  SemanticTypeGeneric genericsId
    | genericsId == target -> Set.singleton polarity
    | otherwise -> Set.empty
  SemanticTypeArray element -> signsOfType estimates target polarity element
  SemanticTypeTuple elements -> foldMap (signsOfType estimates target polarity) elements
  SemanticTypeUnion branches -> foldMap (signsOfType estimates target polarity) branches
  SemanticTypeObject fields -> foldMap (signsOfType estimates target polarity . (.parameterType)) (Map.elems fields)
  SemanticTypeFunction parameterType returnType effect ->
    signsOfType estimates target (flipPolarity polarity) parameterType
      <> signsOfType estimates target polarity returnType
      <> signsOfEffect target polarity effect
  SemanticTypeData dataQName arguments ->
    let variances = variancesOfList estimates dataQName
     in mconcat (zipWith (argSigns estimates target polarity) variances arguments)
  _ -> Set.empty

-- | The polarities at which @target@ occurs in one @data@ argument, given the
-- ambient polarity composed with the argument position's variance.
argSigns :: Map QualifiedName [Variance] -> GenericsId -> Polarity -> Variance -> SemanticGenericArgument Resolved -> Set Polarity
argSigns estimates target polarity variance argument =
  let scan pol = case argument of
        SemanticGenericArgumentType argumentType -> signsOfType estimates target pol argumentType
        SemanticGenericArgumentEffect argumentEffect -> signsOfEffect target pol argumentEffect
   in case variance of
        Covariant -> scan polarity
        Contravariant -> scan (flipPolarity polarity)
        Invariant -> scan polarity <> scan (flipPolarity polarity)
        Bivariant -> Set.empty

-- | Polarities at which @target@ (an effect generic) occurs in an effect tree.
signsOfEffect :: GenericsId -> Polarity -> SemanticEffect Resolved -> Set Polarity
signsOfEffect target polarity = \case
  SemanticEffectGeneric genericsId
    | genericsId == target -> Set.singleton polarity
    | otherwise -> Set.empty
  SemanticEffectUnion branches -> foldMap (signsOfEffect target polarity) branches
  _ -> Set.empty

-- | Estimated variances for a data name (padding with 'Invariant' for safety).
variancesOfList :: Map QualifiedName [Variance] -> QualifiedName -> [Variance]
variancesOfList estimates dataQName = Map.findWithDefault [] dataQName estimates ++ repeat Invariant

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
        case expandLeftGenerics env boundEnv rightLayered.genericsLayer leftLayered of
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

    -- | Map layer. Each left @data@ either appears on the right with args
    -- related per the parameters' variance (rule i) or its (arg-substituted)
    -- object view is a subtype of the right's structural part (rule ii,
    -- @data <: object@ — consulting 'env'). Object width subtyping plus
    -- @object <: record@; a record is never a subtype of a closed object.
    subtypeMap (MapSlot leftData leftBare) (MapSlot rightData rightBare) =
      all dataMatches (Map.toList leftData) && subtypeBareObj leftBare rightBare
      where
        dataMatches (qualifiedName, leftArgs) =
          ( case Map.lookup qualifiedName rightData of
              Just rightArgs -> subtypeArgs (variancesOfList' env qualifiedName) leftArgs rightArgs
              Nothing -> False
          )
            || subtypeBareObj (ClosedObj (dataObjectView qualifiedName leftArgs)) rightBare

    -- | Args of two applications of the same @data@, related by each parameter's
    -- variance: covariant forwards, contravariant reversed, invariant both ways,
    -- bivariant unconditionally.
    subtypeArgs variances leftArgs rightArgs =
      length leftArgs == length rightArgs && and (zipWith3 subtypeArg variances leftArgs rightArgs)
    subtypeArg variance leftArg rightArg = case variance of
      Covariant -> subtypeArgFwd leftArg rightArg
      Bivariant -> True
      Contravariant -> subtypeArgFwd rightArg leftArg
      Invariant -> subtypeArgFwd leftArg rightArg && subtypeArgFwd rightArg leftArg
    subtypeArgFwd leftArg rightArg = case (leftArg, rightArg) of
      (NormalizedGenericArgType a, NormalizedGenericArgType b) -> go a b
      (NormalizedGenericArgEffect a, NormalizedGenericArgEffect b) -> subtypeEffect a b
      _ -> True

    -- | A @data@'s object view at a use site: substitute the use site's args for
    -- the data's generic parameters in its (un-normalized) field types, then
    -- normalise — so @data \<: object@ sees the specialised field types.
    dataObjectView qualifiedName leftArgs = case Map.lookup qualifiedName env of
      Nothing -> Map.empty
      Just info ->
        let typeSubstitution = Map.fromList [(paramId, denormalise normalizedType) | (paramId, NormalizedGenericArgType normalizedType) <- zip info.dataParamIds leftArgs]
            effectSubstitution = Map.fromList [(paramId, denormaliseEffect normalizedEffect) | (paramId, NormalizedGenericArgEffect normalizedEffect) <- zip info.dataParamIds leftArgs]
         in Map.map (requiredNormalizedField . normaliseSemantic env . substituteGenerics typeSubstitution effectSubstitution) info.dataFields

    subtypeBareObj leftBare rightBare = case (leftBare, rightBare) of
      (NoObj, _) -> True
      (_, NoObj) -> False
      (ClosedObj leftFields, ClosedObj rightFields) ->
        -- width: every required field of right is present in left with a
        -- compatible type; a right field that is optional may be absent in
        -- left, and a left field that is optional cannot satisfy a required
        -- right field (it might be absent). Left's extra fields are ignored.
        all (checkField leftFields) (Map.toList rightFields)
      -- 'record' is the map-layer top: every object/data is a subtype of it
      -- (soundly — record promises nothing about field types), but record is a
      -- subtype only of itself / the top, never of a specific closed object.
      (ClosedObj _, RecordObj) -> True
      (RecordObj, ClosedObj _) -> False
      (RecordObj, RecordObj) -> True
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
expandGenerics :: DataFieldEnv -> BoundEnv -> NormalizedType -> NormalizedType
expandGenerics _ _ NormalizedTypeUnknown = NormalizedTypeUnknown
expandGenerics env boundEnv (NormalizedTypeLayered layered) = expandLeftGenerics env boundEnv Set.empty layered

expandLeftGenerics :: DataFieldEnv -> BoundEnv -> Set GenericsId -> LayeredType -> NormalizedType
expandLeftGenerics env boundEnv rhsGenerics = loop
  where
    loop layered
      | Set.null layered.genericsLayer = NormalizedTypeLayered layered
      | otherwise =
          let lhsOnly = Set.difference layered.genericsLayer rhsGenerics
              -- Drop all generics (shared ones cancel); re-add the LHS-only
              -- ones via their bounds.
              cleared = NormalizedTypeLayered layered {genericsLayer = Set.empty}
              expanded = foldr (unionNT env . boundOf) cleared (Set.toList lhsOnly)
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
