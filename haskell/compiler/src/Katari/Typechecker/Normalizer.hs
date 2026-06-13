-- | Logic over the normalized type representation: normalization from semantic types, the
-- union / intersection lattice, subtyping, generic substitution, and denormalization back to
-- display-oriented semantic types. The passive data definitions live in "Katari.Data.NormalizedType".
--
-- Three structural ideas organise this module:
--
--   * 'TypeLattice' — types, effects, attributes and generic arguments all support the same three
--     relations: join (union), meet (intersection) and ordering (subtype). Join and meet are
--     written once as 'combine', parameterised by a 'LatticeDirection'; every dual rule
--     (absent slots, contravariant positions, shadowed sets) flips the direction instead of
--     duplicating the traversal.
--
--   * The subtyping /world/ — an attribute is not distributed into a type's interior; instead
--     'subtype' carries the attribute of the context it is comparing inside (the 'world'), and
--     compares every attribute joined with it. Descending through a private expectation raises the
--     world ('withWorld'), so "a value observed through a private container is itself private" holds
--     without any eager push-down. Attributes therefore stay exactly where they were written.
--
--   * 'traverseArguments' — generic substitution ('substituteType') rebuilds every nested argument
--     position; this is its shared traversal.
--
-- Errors carry 'SemanticGenericArgument' payloads (user-facing types), so normalized nodes are
-- denormalized at the report site; see the @tell*@ helpers.
module Katari.Typechecker.Normalizer where

import Control.Monad (foldM, unless, when)
import Control.Monad.RWS.CPS (RWS)
import Control.Monad.RWS.Class (MonadWriter (..), asks, local)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Map.Merge.Strict qualified as Merge
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Common (intersectWithKeyM, unionWithKeyM)
import Katari.Data.Environment (DataEnvironment, DataInfo (..), GenericBoundEnvironment, GenericParameterInfo, RequestEnvironment, RequestInfo (..), genericIdsByName, genericParameterNames, variancesByName)
import Katari.Data.GenericKind (GenericKind (..), renderGenericKind)
import Katari.Data.Id (GenericId)
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType (FieldInformation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..))
import Katari.Data.Variance (Variance (..))
import Katari.Error (CannotBeIntersectedErrorInfo (..), CannotBeUnionedErrorInfo (..), GenericArityErrorInfo (..), KindErrorInfo (..), SubtypeErrorInfo (..), TypeError (..), UnknownDataErrorInfo (..), UnknownGenericErrorInfo (..), UnknownRequestErrorInfo (..))

------------------------------------------------------------------------------------------------
-- The normalizer monad
------------------------------------------------------------------------------------------------

data NormalizerEnvironment = NormalizerEnvironment
  { dataEnvironment :: DataEnvironment NormalizedType,
    requestEnvironment :: RequestEnvironment NormalizedType,
    genericBoundEnvironment :: GenericBoundEnvironment NormalizedGenericArgument,
    -- | The attribute of the context the current 'subtype' comparison is nested inside: bottom
    -- (public) at the top level, raised by 'withWorld' as the comparison descends through private
    -- expectations. Every attribute is compared joined with it.
    world :: NormalizedAttribute
  }
  deriving (Eq, Show)

type NormalizeError = TypeError

type Normalizer a = RWS NormalizerEnvironment (List NormalizeError) () a

-- | Run a sub-check, capturing its errors instead of emitting them.
captureErrors :: Normalizer a -> Normalizer (a, List NormalizeError)
captureErrors action = pass $ do
  (result, errors) <- listen action
  pure ((result, errors), const [])

-- | Pure join of two attributes (private wins, attribute-generics union). 'combine' computes the
-- same in the 'Normalizer'; this pure form threads the subtyping 'world'.
joinAttribute :: NormalizedAttribute -> NormalizedAttribute -> NormalizedAttribute
joinAttribute left right =
  NormalizedAttribute {private = left.private || right.private, generic = Set.union left.generic right.generic}

-- | The attribute of the context the current comparison is nested inside (see 'world').
currentWorld :: Normalizer NormalizedAttribute
currentWorld = asks (\environment -> environment.world)

-- | Compare the interior of a node whose (supertype) attribute is @attribute@ in a world raised by
-- it: the interior is observed through that attribute, so it joins the world for nested comparisons.
withWorld :: NormalizedAttribute -> Normalizer a -> Normalizer a
withWorld attribute = local (\environment -> environment {world = joinAttribute environment.world attribute})

------------------------------------------------------------------------------------------------
-- Environment lookups. Unknown names are reported at each lookup site (callers never re-report);
-- the same name may surface more than once until errors carry source spans and the checker dedups.
------------------------------------------------------------------------------------------------

dataInfoFor :: QualifiedName -> Normalizer (Maybe (DataInfo NormalizedType))
dataInfoFor qualifiedName = do
  maybeDataInfo <- asks (\environment -> Map.lookup qualifiedName environment.dataEnvironment)
  case maybeDataInfo of
    Nothing -> do
      tell [TypeErrorUnknownData $ UnknownDataErrorInfo {expected = qualifiedName}]
      pure Nothing
    Just dataInfo -> pure (Just dataInfo)

requestInfoFor :: QualifiedName -> Normalizer (Maybe (RequestInfo NormalizedType))
requestInfoFor qualifiedName = do
  maybeRequestInfo <- asks (\environment -> Map.lookup qualifiedName environment.requestEnvironment)
  case maybeRequestInfo of
    Nothing -> do
      tell [TypeErrorUnknownRequest $ UnknownRequestErrorInfo {expected = qualifiedName}]
      pure Nothing
    Just requestInfo -> pure (Just requestInfo)

-- | The upper bound registered for each generic id. An id with no registered bound defaults to
-- the kind's top ("no upper bound ~> extends top"), so an unbounded generic can never pass a
-- subtype check vacuously.
genericBoundsFor :: NormalizedGenericArgument -> Set GenericId -> Normalizer (List NormalizedGenericArgument)
genericBoundsFor defaultBound generics =
  asks
    ( \environment ->
        (\genericId -> Map.findWithDefault defaultBound genericId environment.genericBoundEnvironment)
          <$> Set.toList generics
    )

-- | Report when a data / request application does not supply exactly the declared generic
-- arguments. Runs once, at the semantic -> normalized boundary ('normalizeType' /
-- 'normalizeEffect'); the lattice and subtype code assume complete argument maps afterwards.
checkGenericArity :: QualifiedName -> List GenericParameterInfo -> Map Text a -> Normalizer ()
checkGenericArity qualifiedName declaredParameters arguments =
  unless (Map.keysSet arguments == Set.fromList declaredNames) $
    tell
      [ TypeErrorGenericArity $
          GenericArityErrorInfo
            { name = qualifiedName,
              expected = declaredNames,
              actual = Map.keys arguments
            }
      ]
  where
    declaredNames = genericParameterNames declaredParameters

checkDataArity :: QualifiedName -> Map Text a -> Normalizer ()
checkDataArity qualifiedName arguments = do
  maybeDataInfo <- dataInfoFor qualifiedName
  mapM_
    (\dataInfo -> checkGenericArity qualifiedName dataInfo.genericParameters arguments)
    maybeDataInfo

checkRequestArity :: QualifiedName -> Map Text a -> Normalizer ()
checkRequestArity qualifiedName arguments = do
  maybeRequestInfo <- requestInfoFor qualifiedName
  mapM_
    (\requestInfo -> checkGenericArity qualifiedName requestInfo.genericParameters arguments)
    maybeRequestInfo

------------------------------------------------------------------------------------------------
-- Error reporting
-- Error payloads are user-facing 'SemanticGenericArgument's, so normalized nodes are denormalized
-- here (denormalization itself never emits errors).
------------------------------------------------------------------------------------------------

tellSubtypeMismatch :: Text -> NormalizedType -> NormalizedType -> Normalizer ()
tellSubtypeMismatch reason actual expected = do
  actualSemantic <- denormalize actual
  expectedSemantic <- denormalize expected
  tell
    [ TypeErrorSubtype $
        SubtypeErrorInfo
          { expected = SemanticGenericArgumentType expectedSemantic,
            actual = SemanticGenericArgumentType actualSemantic,
            reason = reason
          }
    ]

tellEffectMismatch :: Text -> NormalizedEffect -> NormalizedEffect -> Normalizer ()
tellEffectMismatch reason actual expected = do
  actualSemantic <- denormalizeEffect actual
  expectedSemantic <- denormalizeEffect expected
  tell
    [ TypeErrorSubtype $
        SubtypeErrorInfo
          { expected = SemanticGenericArgumentEffect expectedSemantic,
            actual = SemanticGenericArgumentEffect actualSemantic,
            reason = reason
          }
    ]

tellAttributeMismatch :: Text -> NormalizedAttribute -> NormalizedAttribute -> Normalizer ()
tellAttributeMismatch reason actual expected =
  tell
    [ TypeErrorSubtype $
        SubtypeErrorInfo
          { expected = SemanticGenericArgumentAttribute (denormalizeAttribute expected),
            actual = SemanticGenericArgumentAttribute (denormalizeAttribute actual),
            reason = reason
          }
    ]

tellKindMismatch :: GenericKind -> GenericKind -> Text -> Normalizer ()
tellKindMismatch expectedKind actualKind reason =
  tell [TypeErrorKind $ KindErrorInfo {expected = renderGenericKind expectedKind, actual = renderGenericKind actualKind, reason = reason}]

tellUnknownGeneric :: Text -> Normalizer ()
tellUnknownGeneric genericArgumentName =
  tell [TypeErrorUnknownGeneric $ UnknownGenericErrorInfo {expected = genericArgumentName}]

-- | An invariant generic argument received two different instantiations; report it for the
-- direction ('Join' = union, 'Meet' = intersection) being computed.
tellInvariantMismatch :: LatticeDirection -> NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer ()
tellInvariantMismatch direction leftArgument rightArgument = do
  leftSemantic <- denormalizeGenericArgument leftArgument
  rightSemantic <- denormalizeGenericArgument rightArgument
  tell $ case direction of
    Join -> [TypeErrorCannotBeUnioned $ CannotBeUnionedErrorInfo {left = leftSemantic, right = rightSemantic}]
    Meet -> [TypeErrorCannotBeIntersected $ CannotBeIntersectedErrorInfo {left = leftSemantic, right = rightSemantic}]

-- | Wrap a layered type as a plain public type (for error payloads).
layeredAsType :: LayeredType -> NormalizedType
layeredAsType layer = NormalizedType {baseType = NormalizedBaseTypeLayered layer, generics = Set.empty, attribute = bottomAttribute}

------------------------------------------------------------------------------------------------
-- Normalization (semantic -> normalized)
------------------------------------------------------------------------------------------------

normalizeType :: SemanticType -> Normalizer NormalizedType
normalizeType semanticBaseType = case semanticBaseType of
  SemanticTypeNever -> pure bottomType
  SemanticTypeUnknown -> pure $ public NormalizedBaseTypeUnknown
  SemanticTypeNull -> pure $ layered neverLayer {nullLayer = True}
  SemanticTypeBoolean -> pure $ layered neverLayer {booleanLayer = True}
  SemanticTypeFile -> pure $ layered neverLayer {fileLayer = True}
  SemanticTypeInteger -> pure $ layered neverLayer {numberLayer = NumberSlotInteger}
  SemanticTypeNumber -> pure $ layered neverLayer {numberLayer = NumberSlotNumber}
  SemanticTypeString -> pure $ layered neverLayer {stringLayer = True}
  SemanticTypeGeneric genericArgumentName -> pure bottomType {generics = Set.singleton genericArgumentName}
  SemanticTypeAgent parameterType returnType effect -> do
    normalizedArgument <- normalizeType parameterType
    normalizedReturnType <- normalizeType returnType
    normalizedEffect <- normalizeEffect effect
    pure $ layered neverLayer {functionLayer = Just NormalizedFunction {argumentType = normalizedArgument, returnType = normalizedReturnType, effect = normalizedEffect}}
  SemanticTypeArray itemType -> do
    normalizedItemType <- normalizeType itemType
    -- NOTE: an array is a sequence with no fixed prefix; every element falls under `rest`
    pure $ layered neverLayer {sequenceLayer = Just NormalizedSequence {items = [], rest = normalizedItemType}}
  SemanticTypeTuple itemTypes -> do
    normalizedItemTypes <- mapM normalizeType itemTypes
    -- NOTE: a tuple's tail is open (rest = unknown of public), mirroring how an object's other fields default to unknown of public
    pure $ layered neverLayer {sequenceLayer = Just NormalizedSequence {items = normalizedItemTypes, rest = publicUnknown}}
  SemanticTypeData qualifiedName genericArguments -> do
    checkDataArity qualifiedName genericArguments
    normalizedGenericArguments <- mapM normalizeGenericArgument genericArguments
    pure $ layered neverLayer {dataLayer = Map.singleton qualifiedName normalizedGenericArguments}
  SemanticTypeObject fields -> do
    normalizedFields <- mapM normalizeFieldInformation fields
    -- NOTE: Other fields must be "public"
    -- then; {x: number, y: number of private} /<: {x: number}  <-- Error because field y is private in the left type but public in the right type.
    --       {x: number, y: number of private} <: {x: number} of private   <-- OK.
    pure $ layered neverLayer {objectLayer = Just NormalizedObject {fields = normalizedFields, rest = publicUnknown}}
  SemanticTypeRecord recordType -> do
    normalizedRecordType <- normalizeType recordType
    pure $ layered neverLayer {objectLayer = Just NormalizedObject {fields = mempty, rest = normalizedRecordType}}
  SemanticTypeUnion semanticTypes -> foldM union bottomType =<< mapM normalizeType semanticTypes
  SemanticTypeAttribute baseType attribute -> do
    normalized <- normalizeType baseType
    normalizedAttribute <- normalizeAttribute attribute
    -- NOTE: number of public of private ~> number of private. The attribute sits on the node; it is
    -- not distributed into the interior — 'subtype' applies it contextually through the 'world'.
    pure normalized {attribute = joinAttribute normalized.attribute normalizedAttribute}
  where
    -- A type carrying the default (public) attribute and no generics.
    public base = NormalizedType {baseType = base, generics = Set.empty, attribute = bottomAttribute}
    layered = public . NormalizedBaseTypeLayered
    publicUnknown = public NormalizedBaseTypeUnknown

normalizeAttribute :: SemanticAttribute -> Normalizer NormalizedAttribute
normalizeAttribute attribute = case attribute of
  SemanticAttributePublic -> pure $ NormalizedAttribute {private = False, generic = Set.empty}
  SemanticAttributePrivate -> pure $ NormalizedAttribute {private = True, generic = Set.empty}
  SemanticAttributeUnion attributes -> foldM union bottomAttribute =<< mapM normalizeAttribute attributes
  SemanticAttributeGeneric genericArgumentName -> pure $ NormalizedAttribute {private = False, generic = Set.singleton genericArgumentName}

normalizeEffect :: SemanticEffect -> Normalizer NormalizedEffect
normalizeEffect effect = case effect of
  SemanticEffectPure -> pure bottomEffect
  SemanticEffectAny -> pure topEffect
  SemanticEffectRequest qualifiedName genericArguments -> do
    checkRequestArity qualifiedName genericArguments
    normalizedGenericArguments <- mapM normalizeGenericArgument genericArguments
    pure $
      NormalizedEffectRow $
        EffectRow
          { request = Map.singleton qualifiedName normalizedGenericArguments,
            generic = mempty,
            shadowed = mempty
          }
  SemanticEffectGeneric genericArgumentName ->
    pure $
      NormalizedEffectRow $
        EffectRow {request = mempty, generic = Set.singleton genericArgumentName, shadowed = mempty}
  SemanticEffectOverwrite baseEffect overwrites -> do
    normalized <- normalizeEffect baseEffect
    overwriteRequests <-
      Map.fromList
        <$> mapM
          ( \(qualifiedName, genericArguments) -> do
              checkRequestArity qualifiedName genericArguments
              normalizedGenericArguments <- mapM normalizeGenericArgument genericArguments
              pure (qualifiedName, normalizedGenericArguments)
          )
          overwrites
    pure $ case normalized of
      NormalizedEffectAny -> NormalizedEffectAny
      NormalizedEffectRow effectRow ->
        NormalizedEffectRow $
          effectRow
            { request = Map.union overwriteRequests effectRow.request,
              -- NOTE: a shadow is a guarantee about the base's generic part. Over a concrete base
              -- the overwrite is already applied to the request map, so no shadow is recorded;
              -- over a base with generics the base's own shadows must survive (union, not replace).
              shadowed =
                if Set.null effectRow.generic
                  then effectRow.shadowed
                  else Set.union effectRow.shadowed (Map.keysSet overwriteRequests)
            }
  SemanticEffectUnion effects -> foldM union bottomEffect =<< mapM normalizeEffect effects

normalizeGenericArgument :: SemanticGenericArgument -> Normalizer NormalizedGenericArgument
normalizeGenericArgument genericArgument = case genericArgument of
  SemanticGenericArgumentAttribute attribute -> NormalizedGenericArgumentAttribute <$> normalizeAttribute attribute
  SemanticGenericArgumentEffect effect -> NormalizedGenericArgumentEffect <$> normalizeEffect effect
  SemanticGenericArgumentType semanticType -> NormalizedGenericArgumentType <$> normalizeType semanticType

normalizeFieldInformation :: FieldInformation -> Normalizer NormalizedFieldInformation
normalizeFieldInformation fieldInformation = do
  normalizedType <- normalizeType fieldInformation.semanticType
  pure $
    NormalizedFieldInformation
      { normalizedType = normalizedType,
        optional = fieldInformation.optional
      }

------------------------------------------------------------------------------------------------
-- The type lattice
------------------------------------------------------------------------------------------------

-- | Which lattice operation 'combine' computes. Dual rules (contravariant positions, absent
-- slots, shadowed sets) flip the direction with 'dualDirection' instead of duplicating code.
data LatticeDirection = Join | Meet
  deriving (Eq, Show)

dualDirection :: LatticeDirection -> LatticeDirection
dualDirection = \case
  Join -> Meet
  Meet -> Join

-- | The lattice shared by types, effects, attributes and generic arguments: join, meet and the
-- ordering. @subtype left right@ checks @left <: right@ and reports (rather than throws) errors.
class TypeLattice a where
  combine :: LatticeDirection -> a -> a -> Normalizer a
  subtype :: a -> a -> Normalizer ()

union :: (TypeLattice a) => a -> a -> Normalizer a
union = combine Join

intersect :: (TypeLattice a) => a -> a -> Normalizer a
intersect = combine Meet

instance TypeLattice NormalizedType where
  -- NOTE: the generics set holds union members, so the meet under-approximates: generic∧concrete
  -- cross terms are dropped (intersection of the sets). That is the sound direction for the
  -- dual-direction uses inside join (contravariant positions); a scrutinee-narrowing meet needs
  -- an over-approximation instead and must not use this.
  combine direction left right = do
    combinedBaseType <- combineBaseType direction left.baseType right.baseType
    combinedAttribute <- combine direction left.attribute right.attribute
    -- NOTE: attributes are not redistributed. A one-sided layer may carry an attribute below the
    -- combined node's, but 'subtype' compares every attribute joined with the world (which picks up
    -- the node attribute on the way down), so the node's attribute is never lost.
    pure $
      NormalizedType
        { baseType = combinedBaseType,
          generics = combineSet direction left.generics right.generics,
          attribute = combinedAttribute
        }

  -- Check if the first type is a subtype of the second type (first <: second).
  --
  -- NOTE: Attribute — public <: private, private /<: public, both compared joined with the current
  -- 'world'. A node's own attribute describes the handle, not its interior, so it is compared once
  -- here; the interior is then compared under @world ∪ right.attribute@ ('withWorld'), which is how
  -- "observed through a private container" propagates without an eager push-down. @{x: number of
  -- private}@ stays a public object with a private field (fits under @unknown of public@); a value
  -- private at the handle does not (@unknown of private@ is the top, @unknown of public@ is not).
  subtype left right = do
    -- Resolve the left's generics to their upper bounds (transitively), treating the supertype's
    -- own generics as already covered (they cancel). The resulting generics field is then ignored:
    -- every remaining generic is either covered by the right or already expanded into the
    -- base/attribute.
    effectiveLeft <- boundedType right.generics left
    subtype effectiveLeft.attribute right.attribute
    -- The interior is observed through the supertype's attribute, so it joins the world below.
    withWorld right.attribute $ case (effectiveLeft.baseType, right.baseType) of
      (NormalizedBaseTypeUnknown, NormalizedBaseTypeUnknown) -> pure ()
      (NormalizedBaseTypeUnknown, NormalizedBaseTypeLayered _) ->
        tellSubtypeMismatch "Unknown type cannot be a subtype of a known type" effectiveLeft right
      (_, NormalizedBaseTypeUnknown) -> pure ()
      (NormalizedBaseTypeLayered leftLayer, NormalizedBaseTypeLayered rightLayer) -> do
        subtypeLayers leftLayer rightLayer
        subtypeData effectiveLeft.attribute leftLayer.dataLayer right rightLayer

-- | Attributes:
--   join: private wins (a value that may be private must be treated as private); generics union.
--   meet: public wins (Ex: agent (x: number of private) -> r | agent (x: number) -> r ~> x must be public); generics intersection.
instance TypeLattice NormalizedAttribute where
  combine direction left right =
    pure $
      NormalizedAttribute
        { private = combineFlag direction left.private right.private,
          generic = combineSet direction left.generic right.generic
        }

  subtype left right = do
    -- Compare both sides joined with the world: inside a private context every attribute is at least
    -- private, so the public/private distinction collapses there (sound — a private context observes
    -- everything privately).
    world <- currentWorld
    let worldedLeft = joinAttribute left world
        worldedRight = joinAttribute right world
    -- Resolve the left's attribute-generics to their upper bounds (transitively), treating the
    -- supertype's own attribute-generics as already covered, then compare the private part.
    effectiveLeft <- boundedAttribute worldedRight.generic worldedLeft
    when (effectiveLeft.private && not worldedRight.private) $
      tellAttributeMismatch "Private attribute cannot be a subtype of public attribute" effectiveLeft worldedRight

instance TypeLattice NormalizedEffect where
  combine direction left right = case (left, right, direction) of
    -- NOTE: any is the top effect: it absorbs the join and is the identity of the meet
    (NormalizedEffectAny, _, Join) -> pure NormalizedEffectAny
    (_, NormalizedEffectAny, Join) -> pure NormalizedEffectAny
    (NormalizedEffectAny, other, Meet) -> pure other
    (other, NormalizedEffectAny, Meet) -> pure other
    (NormalizedEffectRow leftRow, NormalizedEffectRow rightRow, _) -> do
      -- NOTE: requests behave covariantly as a set: the join keeps requests of either side, the
      -- meet keeps only requests present in both
      combinedRequests <-
        keyedMerge direction (combineRequestArguments direction) leftRow.request rightRow.request
      pure $
        NormalizedEffectRow $
          EffectRow
            { request = combinedRequests,
              generic = combineSet direction leftRow.generic rightRow.generic,
              -- NOTE: shadowing is contravariant: a request is shadowed in the join only if
              -- shadowed on both sides, and in the meet if shadowed on either side
              shadowed = combineSet (dualDirection direction) leftRow.shadowed rightRow.shadowed
            }

  subtype left right = case (left, right) of
    (NormalizedEffectAny, NormalizedEffectAny) -> pure ()
    (NormalizedEffectAny, NormalizedEffectRow _) ->
      tellEffectMismatch "Any effect cannot be a subtype of a known effect" left right
    (NormalizedEffectRow _, NormalizedEffectAny) -> pure ()
    (NormalizedEffectRow _, NormalizedEffectRow rightRow) -> do
      -- Resolve the left's effect-generics to their upper bounds (transitively), treating the
      -- supertype's own effect-generics as already covered, then compare requests and shadowing.
      effectiveLeft <- boundedEffect rightRow.generic left
      case effectiveLeft of
        -- A left-only effect-generic is unbounded (any), so the effective left effect is any and
        -- cannot be a subtype of a known effect row.
        NormalizedEffectAny -> tellEffectMismatch "A left-only effect generic is unbounded, so the left effect is effectively any" effectiveLeft right
        NormalizedEffectRow effectiveLeftRow -> do
          -- NOTE: requests are covariant; every request the left performs must appear on the right
          mapM_
            ( \(qualifiedName, leftArguments) ->
                case Map.lookup qualifiedName rightRow.request of
                  Nothing -> tellEffectMismatch ("Left effect performs a request not present in the right effect: " <> renderQualifiedName qualifiedName) effectiveLeft right
                  Just rightArguments -> do
                    maybeRequestInfo <- requestInfoFor qualifiedName
                    mapM_ (\requestInfo -> subtypeArgumentsWith (variancesByName requestInfo.genericParameters) leftArguments rightArguments) maybeRequestInfo
            )
            (Map.toList effectiveLeftRow.request)
          -- NOTE: shadowing is contravariant: the left's shadowed set must cover the right's
          unless (rightRow.shadowed `Set.isSubsetOf` effectiveLeftRow.shadowed) $
            tellEffectMismatch "Effect shadowed requests are incompatible" effectiveLeft right

-- | Combine the argument maps of one request name according to the request's declared variances.
combineRequestArguments :: LatticeDirection -> QualifiedName -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer (Map Text NormalizedGenericArgument)
combineRequestArguments direction qualifiedName leftArguments rightArguments = do
  maybeRequestInfo <- requestInfoFor qualifiedName
  combineArgumentMap direction ((\requestInfo -> variancesByName requestInfo.genericParameters) <$> maybeRequestInfo) leftArguments rightArguments

instance TypeLattice NormalizedGenericArgument where
  combine direction leftArgument rightArgument = case (leftArgument, rightArgument) of
    (NormalizedGenericArgumentType leftType, NormalizedGenericArgumentType rightType) ->
      NormalizedGenericArgumentType <$> combine direction leftType rightType
    (NormalizedGenericArgumentEffect leftEffect, NormalizedGenericArgumentEffect rightEffect) ->
      NormalizedGenericArgumentEffect <$> combine direction leftEffect rightEffect
    (NormalizedGenericArgumentAttribute leftAttribute, NormalizedGenericArgumentAttribute rightAttribute) ->
      NormalizedGenericArgumentAttribute <$> combine direction leftAttribute rightAttribute
    _ -> do
      tellKindMismatch (kindOf leftArgument) (kindOf rightArgument) $ case direction of
        Join -> "Generic arguments with different kinds cannot be unioned"
        Meet -> "Generic arguments with different kinds cannot be intersected"
      pure leftArgument -- NOTE: either side works; the pair is not combinable anyway

  subtype leftArgument rightArgument = case (leftArgument, rightArgument) of
    (NormalizedGenericArgumentType leftType, NormalizedGenericArgumentType rightType) -> subtype leftType rightType
    (NormalizedGenericArgumentEffect leftEffect, NormalizedGenericArgumentEffect rightEffect) -> subtype leftEffect rightEffect
    (NormalizedGenericArgumentAttribute leftAttribute, NormalizedGenericArgumentAttribute rightAttribute) -> subtype leftAttribute rightAttribute
    _ -> tellKindMismatch (kindOf rightArgument) (kindOf leftArgument) "Generic argument kinds are incompatible"

-- | join = (||), meet = (&&). Doubles as the optionality combiner of 'mergeObject': a field is
-- optional in the union if optional on either side, and in the intersection only if on both.
combineFlag :: LatticeDirection -> Bool -> Bool -> Bool
combineFlag = \case
  Join -> (||)
  Meet -> (&&)

combineSet :: (Ord a) => LatticeDirection -> Set a -> Set a -> Set a
combineSet = \case
  Join -> Set.union
  Meet -> Set.intersection

-- | join keeps keys of either side (one-sided entries pass through), meet keeps only shared keys.
keyedMerge :: (Ord k) => LatticeDirection -> (k -> a -> a -> Normalizer a) -> Map k a -> Map k a -> Normalizer (Map k a)
keyedMerge = \case
  Join -> unionWithKeyM
  Meet -> intersectWithKeyM

combineBaseType :: LatticeDirection -> NormalizedBaseType -> NormalizedBaseType -> Normalizer NormalizedBaseType
combineBaseType direction left right = case (left, right, direction) of
  -- NOTE: unknown is the top of the base lattice: it absorbs the join and is the identity of the meet
  (NormalizedBaseTypeUnknown, _, Join) -> pure NormalizedBaseTypeUnknown
  (_, NormalizedBaseTypeUnknown, Join) -> pure NormalizedBaseTypeUnknown
  (NormalizedBaseTypeUnknown, other, Meet) -> pure other
  (other, NormalizedBaseTypeUnknown, Meet) -> pure other
  (NormalizedBaseTypeLayered leftLayer, NormalizedBaseTypeLayered rightLayer, _) ->
    NormalizedBaseTypeLayered <$> combineLayers direction leftLayer rightLayer

-- | Absent is the bottom of every slot's own lattice: the identity of the join, absorbing for
-- the meet.
combineSlot :: LatticeDirection -> (a -> a -> Normalizer a) -> Maybe a -> Maybe a -> Normalizer (Maybe a)
combineSlot direction combinePresent left right = case (left, right, direction) of
  (Nothing, other, Join) -> pure other
  (other, Nothing, Join) -> pure other
  (Nothing, _, Meet) -> pure Nothing
  (_, Nothing, Meet) -> pure Nothing
  (Just leftValue, Just rightValue, _) -> Just <$> combinePresent leftValue rightValue

combineLayers :: LatticeDirection -> LayeredType -> LayeredType -> Normalizer LayeredType
combineLayers direction left right = do
  combinedFunctionLayer <- combineSlot direction combineFunction left.functionLayer right.functionLayer
  combinedSequenceLayer <- combineSlot direction (mergeSequence (combine direction)) left.sequenceLayer right.sequenceLayer
  combinedObjectLayer <- combineSlot direction (mergeObject (combine direction) (combineFlag direction)) left.objectLayer right.objectLayer
  -- NOTE: nominal data types combine as a set (join keeps either side, meet keeps shared names —
  -- distinct nominal types meet to never); the generic arguments combine per declared variance.
  combinedDataLayer <- keyedMerge direction combineDataArguments left.dataLayer right.dataLayer
  pure $
    LayeredType
      { nullLayer = combineFlag direction left.nullLayer right.nullLayer,
        -- NOTE: 'NumberSlot' is the chain Absent < Integer < Number, so join = max and meet = min
        numberLayer = (case direction of Join -> max; Meet -> min) left.numberLayer right.numberLayer,
        stringLayer = combineFlag direction left.stringLayer right.stringLayer,
        booleanLayer = combineFlag direction left.booleanLayer right.booleanLayer,
        fileLayer = combineFlag direction left.fileLayer right.fileLayer,
        functionLayer = combinedFunctionLayer,
        sequenceLayer = combinedSequenceLayer,
        objectLayer = combinedObjectLayer,
        dataLayer = combinedDataLayer
      }
  where
    combineFunction leftFunction rightFunction =
      NormalizedFunction
        -- NOTE: the argument is contravariant, so it combines in the dual direction
        <$> combine (dualDirection direction) leftFunction.argumentType rightFunction.argumentType
        <*> combine direction leftFunction.returnType rightFunction.returnType
        <*> combine direction leftFunction.effect rightFunction.effect
    combineDataArguments qualifiedName leftArguments rightArguments = do
      maybeDataInfo <- dataInfoFor qualifiedName
      combineArgumentMap direction ((\dataInfo -> variancesByName dataInfo.genericParameters) <$> maybeDataInfo) leftArguments rightArguments

-- | Combine the named generic arguments of one data type or request, each according to its
-- declared variance:
--   covariant     -> combine in the same direction
--   contravariant -> combine in the dual direction
--   invariant     -> the two instantiations must be identical
--   bivariant     -> unconstrained; combine in the same direction
-- Ex) req1[T, U] covariant in T, contravariant in U:
--     req1[int, string] | req1[string, number] ~> req1[int | string, string & number]
-- When the owner is unknown (variances 'Nothing', already reported), the arguments are merged
-- positionally without further checks.
combineArgumentMap :: LatticeDirection -> Maybe (Map Text Variance) -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer (Map Text NormalizedGenericArgument)
combineArgumentMap direction maybeVariances leftArguments rightArguments = case maybeVariances of
  Nothing -> pure $ Map.union leftArguments rightArguments
  Just variances -> unionWithKeyM combineNamedArgument leftArguments rightArguments
    where
      combineNamedArgument genericArgumentName leftArgument rightArgument = case Map.lookup genericArgumentName variances of
        Nothing -> do
          tellUnknownGeneric genericArgumentName
          pure leftArgument
        Just Covariant -> combine direction leftArgument rightArgument
        Just Contravariant -> combine (dualDirection direction) leftArgument rightArgument
        Just Bivariant -> combine direction leftArgument rightArgument
        Just Invariant
          | leftArgument == rightArgument -> pure leftArgument
          | otherwise -> do
              tellInvariantMismatch direction leftArgument rightArgument
              pure leftArgument -- NOTE: either side works; the pair is not combinable anyway

-- | The field a name missing from one side stands for: that side's `rest`, optional.
restField :: NormalizedObject -> NormalizedFieldInformation
restField object = NormalizedFieldInformation {normalizedType = object.rest, optional = True}

-- | Pair up the fields of two objects under every name present on either side; a missing field is
-- that side's 'restField'. Shared by 'mergeObject' and 'subtypeObject' so the defaulting rule
-- cannot drift between combine and subtype.
alignObjectFields :: NormalizedObject -> NormalizedObject -> Map Text (NormalizedFieldInformation, NormalizedFieldInformation)
alignObjectFields leftObject rightObject =
  Merge.merge
    (Merge.mapMissing (\_ leftField -> (leftField, restField rightObject)))
    (Merge.mapMissing (\_ rightField -> (restField leftObject, rightField)))
    (Merge.zipWithMatched (\_ leftField rightField -> (leftField, rightField)))
    leftObject.fields
    rightObject.fields

-- | Pair up two sequences position-by-position; the shorter side is padded with its `rest`. The
-- rests themselves are not included. Shared by 'mergeSequence' and 'subtypeSequence'.
alignSequenceItems :: NormalizedSequence -> NormalizedSequence -> List (NormalizedType, NormalizedType)
alignSequenceItems leftSequence rightSequence = go leftSequence.items rightSequence.items
  where
    go [] [] = []
    go (leftItem : leftRemaining) (rightItem : rightRemaining) = (leftItem, rightItem) : go leftRemaining rightRemaining
    go (leftItem : leftRemaining) [] = (leftItem, rightSequence.rest) : go leftRemaining []
    go [] (rightItem : rightRemaining) = (leftSequence.rest, rightItem) : go [] rightRemaining

-- | Merge two objects field-by-field with the given combiners.
-- Ex) {x: number, y: number} | {y: number, z: number} ~> {x?: unknown, y: number, z?: unknown}
--     {x: number} & {y: number} ~> {x: number, y: number}
mergeObject ::
  (NormalizedType -> NormalizedType -> Normalizer NormalizedType) ->
  (Bool -> Bool -> Bool) ->
  NormalizedObject ->
  NormalizedObject ->
  Normalizer NormalizedObject
mergeObject combineType combineOptional leftObject rightObject = do
  mergedFields <-
    mapM
      ( \(leftField, rightField) -> do
          mergedFieldType <- combineType leftField.normalizedType rightField.normalizedType
          pure NormalizedFieldInformation {normalizedType = mergedFieldType, optional = combineOptional leftField.optional rightField.optional}
      )
      (alignObjectFields leftObject rightObject)
  mergedRest <- combineType leftObject.rest rightObject.rest
  pure $ NormalizedObject {fields = mergedFields, rest = mergedRest}

-- | Merge two sequences position-by-position.
-- Ex) [number, string] | [boolean] ~> [number | boolean, string | unknown]
--     [number, string] & [boolean] ~> [number & boolean, string & unknown]
mergeSequence ::
  (NormalizedType -> NormalizedType -> Normalizer NormalizedType) ->
  NormalizedSequence ->
  NormalizedSequence ->
  Normalizer NormalizedSequence
mergeSequence combineType leftSequence rightSequence = do
  mergedItems <- mapM (uncurry combineType) (alignSequenceItems leftSequence rightSequence)
  mergedRest <- combineType leftSequence.rest rightSequence.rest
  pure $ NormalizedSequence {items = mergedItems, rest = mergedRest}

------------------------------------------------------------------------------------------------
-- Subtyping helpers (the entry points are the 'subtype' methods of 'TypeLattice')
------------------------------------------------------------------------------------------------

-- | Compare the structural layers — everything except the data layer, which 'subtypeData' handles.
-- Within one layered type the slots are independent union members, so each slot is compared on its
-- own chain; absent is the bottom of every slot.
subtypeLayers :: LayeredType -> LayeredType -> Normalizer ()
subtypeLayers leftLayer rightLayer = do
  let mismatch message = tellSubtypeMismatch message (layeredAsType leftLayer) (layeredAsType rightLayer)
  unless (leftLayer.nullLayer <= rightLayer.nullLayer) $ mismatch "Null layers are incompatible"
  -- NOTE: 'NumberSlot' is the chain Absent < Integer < Number, so the ordering is 'Ord'
  unless (leftLayer.numberLayer <= rightLayer.numberLayer) $ mismatch "Number layers are incompatible"
  unless (leftLayer.stringLayer <= rightLayer.stringLayer) $ mismatch "String layers are incompatible"
  unless (leftLayer.booleanLayer <= rightLayer.booleanLayer) $ mismatch "Boolean layers are incompatible"
  unless (leftLayer.fileLayer <= rightLayer.fileLayer) $ mismatch "File layers are incompatible"
  subtypeSlot (mismatch "Function layers are incompatible") subtypeFunction leftLayer.functionLayer rightLayer.functionLayer
  subtypeSlot (mismatch "Sequence layers are incompatible") subtypeSequence leftLayer.sequenceLayer rightLayer.sequenceLayer
  subtypeSlot (mismatch "Object layers are incompatible") subtypeObject leftLayer.objectLayer rightLayer.objectLayer

-- | Absent is the bottom of every slot: an absent left fits anything, a present left needs a
-- present right.
subtypeSlot :: Normalizer () -> (a -> a -> Normalizer ()) -> Maybe a -> Maybe a -> Normalizer ()
subtypeSlot mismatch checkPresent left right = case (left, right) of
  (Nothing, _) -> pure ()
  (Just _, Nothing) -> mismatch
  (Just leftValue, Just rightValue) -> checkPresent leftValue rightValue

subtypeFunction :: NormalizedFunction -> NormalizedFunction -> Normalizer ()
subtypeFunction leftFunction rightFunction = do
  -- NOTE: the function argument is contravariant
  subtype rightFunction.argumentType leftFunction.argumentType
  subtype leftFunction.returnType rightFunction.returnType
  subtype leftFunction.effect rightFunction.effect

-- | Sequences are covariant: every position's element type must be a subtype, including the tail
-- (rest). A position present on only one side is compared against the other side's rest.
subtypeSequence :: NormalizedSequence -> NormalizedSequence -> Normalizer ()
subtypeSequence leftSequence rightSequence = do
  mapM_ (uncurry subtype) (alignSequenceItems leftSequence rightSequence)
  subtype leftSequence.rest rightSequence.rest

-- | Object field types are covariant. A field present on only one side is compared against the
-- other side's rest (treated as optional). A required field on the right must be required on the
-- left, otherwise the left value may omit a field the right guarantees.
subtypeObject :: NormalizedObject -> NormalizedObject -> Normalizer ()
subtypeObject leftObject rightObject = do
  mapM_ checkField (Map.toList (alignObjectFields leftObject rightObject))
  subtype leftObject.rest rightObject.rest
  where
    checkField (fieldName, (leftField, rightField)) = do
      subtype leftField.normalizedType rightField.normalizedType
      when (leftField.optional && not rightField.optional) $
        tellSubtypeMismatch ("Optional field cannot be a subtype of a required field: " <> fieldName) leftField.normalizedType rightField.normalizedType

-- | The data layer is a union of nominal types. Every nominal type on the left must satisfy one of:
--
--   (i)  the same nominal type appears on the right, with generic arguments compatible per the
--        declared variance, or
--   (ii) its constructor type (with the generic arguments substituted in) is a subtype of the whole
--        right side; data foo[T](x: T) gives foo[U] <: {x: U}, so fields of a data value can be read
--        through the object layer.
--
-- The constructor instance is the data value's interior, so it is compared with the left node's
-- attribute joined into the world ('withWorld') — observed through the data's handle, by the same
-- contextual rule the rest of subtyping uses.
subtypeData :: NormalizedAttribute -> Map QualifiedName (Map Text NormalizedGenericArgument) -> NormalizedType -> LayeredType -> Normalizer ()
subtypeData leftAttribute leftDataLayer right rightLayer = mapM_ checkData (Map.toList leftDataLayer)
  where
    checkData (qualifiedName, leftArguments) = do
      maybeDataInfo <- dataInfoFor qualifiedName
      case maybeDataInfo of
        Nothing -> pure () -- already reported by the lookup
        Just dataInfo -> case Map.lookup qualifiedName rightLayer.dataLayer of
          Just rightArguments -> do
            ((), nominalErrors) <- captureErrors $ subtypeArgumentsWith (variancesByName dataInfo.genericParameters) leftArguments rightArguments
            unless (null nominalErrors) $ do
              ((), constructorErrors) <- constructorCheck dataInfo leftArguments
              -- NOTE: when both fail, report the nominal errors; they refer to the type as written
              unless (null constructorErrors) $ tell nominalErrors
          Nothing -> do
            ((), constructorErrors) <- constructorCheck dataInfo leftArguments
            unless (null constructorErrors) $ do
              tellSubtypeMismatch
                ("Data type is not present in the supertype, and its constructor is not a subtype either: " <> renderQualifiedName qualifiedName)
                (layeredAsType neverLayer {dataLayer = Map.singleton qualifiedName leftArguments})
                right
              tell constructorErrors
    constructorCheck dataInfo leftArguments = captureErrors $ withWorld leftAttribute $ do
      constructorInstance <- substituteType (constructorSubstitution dataInfo leftArguments) dataInfo.constructor
      subtype constructorInstance right

-- | The generic-id substitution that instantiates a data declaration's constructor with the
-- arguments of one application of it.
constructorSubstitution :: DataInfo NormalizedType -> Map Text NormalizedGenericArgument -> Map GenericId NormalizedGenericArgument
constructorSubstitution dataInfo arguments =
  Map.fromList
    [ (genericId, argument)
      | (genericArgumentName, genericId) <- Map.toList (genericIdsByName dataInfo.genericParameters),
        Just argument <- [Map.lookup genericArgumentName arguments]
    ]

-- | Compare the named generic arguments of one data type or request pointwise, each according to
-- its declared variance. Argument maps are complete by construction ('checkGenericArity' runs at
-- normalization), so the shared key set is the full declared set:
--   covariant     -> left <: right
--   contravariant -> right <: left
--   invariant     -> both directions
--   bivariant     -> no constraint
subtypeArgumentsWith :: Map Text Variance -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer ()
subtypeArgumentsWith variances leftArguments rightArguments =
  mapM_ checkNamedArgument (Map.toList (Map.intersectionWith (,) leftArguments rightArguments))
  where
    checkNamedArgument (genericArgumentName, (leftArgument, rightArgument)) =
      case Map.lookup genericArgumentName variances of
        Nothing -> tellUnknownGeneric genericArgumentName
        Just Covariant -> subtype leftArgument rightArgument
        Just Contravariant -> subtype rightArgument leftArgument
        Just Invariant -> do
          subtype leftArgument rightArgument
          subtype rightArgument leftArgument
        Just Bivariant -> pure ()

------------------------------------------------------------------------------------------------
-- Generic upper bounds
------------------------------------------------------------------------------------------------

-- | Raise a value to the upper bounds of its own generics by absorbing the bounds in,
-- transitively: a bound may itself introduce more generics, which are then resolved too. Generics
-- in @coveredGenerics@ are left untouched (they are "already covered" — e.g. the supertype's own
-- generics during a subtype check, which cancel rather than expand). Generics that appear only
-- inside nested layers (object fields, sequence elements, …) are NOT touched here; they live in
-- those nested values' own generics sets and are resolved when the comparison recurses into them.
resolveUpperBounds ::
  NormalizedGenericArgument ->
  (a -> Set GenericId) ->
  (a -> NormalizedGenericArgument -> Normalizer a) ->
  Set GenericId ->
  a ->
  Normalizer a
resolveUpperBounds defaultBound genericsOf absorbBound coveredGenerics = resolve Set.empty
  where
    resolve resolvedGenerics current = do
      let genericsToResolve = Set.difference (genericsOf current) (Set.union coveredGenerics resolvedGenerics)
      if Set.null genericsToResolve
        then pure current
        else do
          bounds <- genericBoundsFor defaultBound genericsToResolve
          next <- foldM absorbBound current bounds
          resolve (Set.union resolvedGenerics genericsToResolve) next

boundedType :: Set GenericId -> NormalizedType -> Normalizer NormalizedType
boundedType = resolveUpperBounds (NormalizedGenericArgumentType topType) (\normalizedType -> normalizedType.generics) absorbBound
  where
    absorbBound accumulated = \case
      NormalizedGenericArgumentType bound -> union accumulated bound
      other -> do
        tellKindMismatch GenericKindType (kindOf other) "Expected a type bound for a type generic"
        pure accumulated

boundedEffect :: Set GenericId -> NormalizedEffect -> Normalizer NormalizedEffect
boundedEffect = resolveUpperBounds (NormalizedGenericArgumentEffect topEffect) effectGenerics absorbBound
  where
    effectGenerics = \case
      NormalizedEffectAny -> Set.empty
      NormalizedEffectRow effectRow -> effectRow.generic
    absorbBound accumulated = \case
      NormalizedGenericArgumentEffect bound -> absorbEffectBound accumulated bound
      other -> do
        tellKindMismatch GenericKindEffect (kindOf other) "Expected an effect bound for an effect generic"
        pure accumulated

-- | Absorb an effect generic's upper bound into the row that carried the generic. Not a lattice
-- join: the row's shadowed names replace the generic part's contribution (that is what a shadow
-- means), so they are dropped from the bound before joining, and the row's shadow guarantees
-- survive the absorption.
absorbEffectBound :: NormalizedEffect -> NormalizedEffect -> Normalizer NormalizedEffect
absorbEffectBound accumulated bound = case (accumulated, bound) of
  (NormalizedEffectAny, _) -> pure NormalizedEffectAny
  (_, NormalizedEffectAny) -> pure NormalizedEffectAny
  (NormalizedEffectRow accumulatedRow, NormalizedEffectRow boundRow) -> do
    combinedRequests <-
      keyedMerge Join (combineRequestArguments Join) accumulatedRow.request (Map.withoutKeys boundRow.request accumulatedRow.shadowed)
    pure $
      NormalizedEffectRow $
        EffectRow
          { request = combinedRequests,
            generic = Set.union accumulatedRow.generic boundRow.generic,
            shadowed = Set.union accumulatedRow.shadowed boundRow.shadowed
          }

boundedAttribute :: Set GenericId -> NormalizedAttribute -> Normalizer NormalizedAttribute
boundedAttribute = resolveUpperBounds (NormalizedGenericArgumentAttribute topAttribute) (\attribute -> attribute.generic) absorbBound
  where
    absorbBound accumulated = \case
      NormalizedGenericArgumentAttribute bound -> union accumulated bound
      other -> do
        tellKindMismatch GenericKindAttribute (kindOf other) "Expected an attribute bound for an attribute generic"
        pure accumulated

------------------------------------------------------------------------------------------------
-- Argument traversal: attribute push-down and generic substitution
------------------------------------------------------------------------------------------------

-- | Callbacks of 'traverseArguments', one per argument kind.
data ArgumentVisitor = ArgumentVisitor
  { visitType :: NormalizedType -> Normalizer NormalizedType,
    visitEffect :: NormalizedEffect -> Normalizer NormalizedEffect,
    visitAttribute :: NormalizedAttribute -> Normalizer NormalizedAttribute
  }

-- | Rebuild every nested argument position of a layered type: object fields and rest, sequence
-- items and rest, the function argument / return / effect, and data arguments. Variance-agnostic —
-- its one user, 'substituteType', rebuilds every position alike.
traverseArguments :: ArgumentVisitor -> LayeredType -> Normalizer LayeredType
traverseArguments visitor layered = do
  visitedFunctionLayer <- traverse visitFunction layered.functionLayer
  visitedSequenceLayer <- traverse visitSequence layered.sequenceLayer
  visitedObjectLayer <- traverse visitObject layered.objectLayer
  visitedDataLayer <- traverse (traverse visitArgument) layered.dataLayer
  pure $
    layered
      { functionLayer = visitedFunctionLayer,
        sequenceLayer = visitedSequenceLayer,
        objectLayer = visitedObjectLayer,
        dataLayer = visitedDataLayer
      }
  where
    visitFunction function =
      NormalizedFunction
        <$> visitor.visitType function.argumentType
        <*> visitor.visitType function.returnType
        <*> visitor.visitEffect function.effect
    visitSequence normalizedSequence = do
      visitedItems <- mapM visitor.visitType normalizedSequence.items
      visitedRest <- visitor.visitType normalizedSequence.rest
      pure $ NormalizedSequence {items = visitedItems, rest = visitedRest}
    visitObject normalizedObject = do
      visitedFields <-
        mapM
          ( \fieldInformation -> do
              visitedFieldType <- visitor.visitType fieldInformation.normalizedType
              pure fieldInformation {normalizedType = visitedFieldType}
          )
          normalizedObject.fields
      visitedRest <- visitor.visitType normalizedObject.rest
      pure $ NormalizedObject {fields = visitedFields, rest = visitedRest}
    visitArgument = \case
      NormalizedGenericArgumentType normalizedType -> NormalizedGenericArgumentType <$> visitor.visitType normalizedType
      NormalizedGenericArgumentEffect effect -> NormalizedGenericArgumentEffect <$> visitor.visitEffect effect
      NormalizedGenericArgumentAttribute attribute -> NormalizedGenericArgumentAttribute <$> visitor.visitAttribute attribute

-- | Literal substitution of generic ids. A generic id occurring in a node's generics set is
-- removed and its replacement unioned into that node (the set representation means "this node is
-- a union with the generic", so unioning the replacement in is exact substitution, not an
-- approximation), and nested argument positions are substituted recursively. Ids missing from the
-- map are left untouched. Used to instantiate a data constructor type with concrete arguments.
substituteType :: Map GenericId NormalizedGenericArgument -> NormalizedType -> Normalizer NormalizedType
substituteType substitution normalizedType = do
  substitutedBaseType <- case normalizedType.baseType of
    NormalizedBaseTypeUnknown -> pure NormalizedBaseTypeUnknown
    NormalizedBaseTypeLayered layered -> NormalizedBaseTypeLayered <$> traverseArguments substituteVisitor layered
  substitutedAttribute <- substituteAttribute substitution normalizedType.attribute
  substituteGenerics
    GenericKindType
    (\accumulated -> \case NormalizedGenericArgumentType replacement -> Just (union accumulated replacement); _ -> Nothing)
    substitution
    (\generics -> normalizedType {baseType = substitutedBaseType, attribute = substitutedAttribute, generics = generics})
    normalizedType.generics
  where
    substituteVisitor =
      ArgumentVisitor
        { visitType = substituteType substitution,
          visitEffect = substituteEffect substitution,
          visitAttribute = substituteAttribute substitution
        }

-- | As 'substituteType', for effects (effect-kind generic ids and the request arguments).
substituteEffect :: Map GenericId NormalizedGenericArgument -> NormalizedEffect -> Normalizer NormalizedEffect
substituteEffect substitution effect = case effect of
  NormalizedEffectAny -> pure NormalizedEffectAny
  NormalizedEffectRow effectRow -> do
    substitutedRequests <- mapM (mapM (substituteGenericArgument substitution)) effectRow.request
    substituteGenerics
      GenericKindEffect
      (\accumulated -> \case NormalizedGenericArgumentEffect replacement -> Just (union accumulated replacement); _ -> Nothing)
      substitution
      (\generics -> NormalizedEffectRow $ effectRow {request = substitutedRequests, generic = generics})
      effectRow.generic

-- | As 'substituteType', for attributes (attribute-kind generic ids).
substituteAttribute :: Map GenericId NormalizedGenericArgument -> NormalizedAttribute -> Normalizer NormalizedAttribute
substituteAttribute substitution attribute =
  substituteGenerics
    GenericKindAttribute
    (\accumulated -> \case NormalizedGenericArgumentAttribute replacement -> Just (union accumulated replacement); _ -> Nothing)
    substitution
    (\generics -> NormalizedAttribute {private = attribute.private, generic = generics})
    attribute.generic

substituteGenericArgument :: Map GenericId NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
substituteGenericArgument substitution genericArgument = case genericArgument of
  NormalizedGenericArgumentType normalizedType -> NormalizedGenericArgumentType <$> substituteType substitution normalizedType
  NormalizedGenericArgumentEffect effect -> NormalizedGenericArgumentEffect <$> substituteEffect substitution effect
  NormalizedGenericArgumentAttribute attribute -> NormalizedGenericArgumentAttribute <$> substituteAttribute substitution attribute

-- | The shared core of the @substitute*@ family: split a generics set into replaced and kept ids,
-- rebuild the node with the kept ones, then absorb each replacement of the expected kind
-- (reporting a kind mismatch otherwise).
substituteGenerics ::
  GenericKind ->
  (a -> NormalizedGenericArgument -> Maybe (Normalizer a)) ->
  Map GenericId NormalizedGenericArgument ->
  (Set GenericId -> a) ->
  Set GenericId ->
  Normalizer a
substituteGenerics expectedKind absorbReplacement substitution rebuild generics = do
  let (replacedGenerics, keptGenerics) = Set.partition (`Map.member` substitution) generics
  foldM
    absorb
    (rebuild keptGenerics)
    (Map.elems (Map.restrictKeys substitution replacedGenerics))
  where
    absorb accumulated replacement = case absorbReplacement accumulated replacement of
      Just absorbed -> absorbed
      Nothing -> do
        tellKindMismatch expectedKind (kindOf replacement) ("Expected " <> article expectedKind <> " argument for " <> article expectedKind <> " generic")
        pure accumulated
    -- NOTE: the indefinite article agrees with the kind's spoken name (a type / an effect / an attribute).
    article = \case
      GenericKindType -> "a type"
      GenericKindEffect -> "an effect"
      GenericKindAttribute -> "an attribute"

------------------------------------------------------------------------------------------------
-- Denormalization (normalized -> display-oriented semantic)
------------------------------------------------------------------------------------------------

-- | Convert a normalized type back into a (display-oriented) semantic type — the inverse of
-- 'normalizeType' for presentation. Error messages should show types the way the user wrote them,
-- not in the lossy normal form. It is approximate: the normal form merges unions into the layer
-- flags, and an object's open tail (@rest@) cannot be expressed by 'SemanticTypeObject', so it is
-- dropped (a non-trivial @rest@ is preserved only for the record form, fields empty). Effect
-- shadowing (overwrite) is likewise not reconstructed. Denormalization never emits errors: it is
-- used while constructing errors.
--
-- Attributes are read straight off each node (subtyping never distributed them), so a type written
-- as @{x: number} of private@ renders back the same, with @of private@ exactly where it sits.
denormalize :: NormalizedType -> Normalizer SemanticType
denormalize normalizedType = do
  baseSemanticType <- denormalizeBaseType normalizedType.baseType normalizedType.generics
  pure $
    if normalizedType.attribute == bottomAttribute
      then baseSemanticType
      else SemanticTypeAttribute baseSemanticType (denormalizeAttribute normalizedType.attribute)

denormalizeBaseType :: NormalizedBaseType -> Set GenericId -> Normalizer SemanticType
denormalizeBaseType baseType generics = case baseType of
  NormalizedBaseTypeUnknown -> pure SemanticTypeUnknown
  NormalizedBaseTypeLayered layeredType -> do
    layerTypes <- denormalizeLayers layeredType
    let genericTypes = SemanticTypeGeneric <$> Set.toList generics
    pure $ case layerTypes <> genericTypes of
      [] -> SemanticTypeNever
      [single] -> single
      many -> SemanticTypeUnion many

-- | One semantic type per active layer (in a fixed order); the caller unions them.
denormalizeLayers :: LayeredType -> Normalizer (List SemanticType)
denormalizeLayers layeredType = do
  let nullPart = [SemanticTypeNull | layeredType.nullLayer]
      numberPart = case layeredType.numberLayer of
        NumberSlotAbsent -> []
        NumberSlotInteger -> [SemanticTypeInteger]
        NumberSlotNumber -> [SemanticTypeNumber]
      stringPart = [SemanticTypeString | layeredType.stringLayer]
      booleanPart = [SemanticTypeBoolean | layeredType.booleanLayer]
      filePart = [SemanticTypeFile | layeredType.fileLayer]
  functionPart <- case layeredType.functionLayer of
    Nothing -> pure []
    Just function -> do
      semanticArgument <- denormalize function.argumentType
      semanticReturn <- denormalize function.returnType
      semanticEffect <- denormalizeEffect function.effect
      pure [SemanticTypeAgent semanticArgument semanticReturn semanticEffect]
  sequencePart <- case layeredType.sequenceLayer of
    Nothing -> pure []
    Just normalizedSequence ->
      if null normalizedSequence.items
        then do
          semanticItem <- denormalize normalizedSequence.rest
          pure [SemanticTypeArray semanticItem]
        else do
          semanticItems <- mapM denormalize normalizedSequence.items
          pure [SemanticTypeTuple semanticItems]
  objectPart <- case layeredType.objectLayer of
    Nothing -> pure []
    Just normalizedObject ->
      if Map.null normalizedObject.fields
        then do
          semanticRecord <- denormalize normalizedObject.rest
          pure [SemanticTypeRecord semanticRecord]
        else do
          semanticFields <- mapM denormalizeFieldInformation normalizedObject.fields
          pure [SemanticTypeObject semanticFields]
  dataPart <- mapM (uncurry denormalizeData) (Map.toList layeredType.dataLayer)
  pure $ nullPart <> numberPart <> stringPart <> booleanPart <> filePart <> functionPart <> sequencePart <> objectPart <> dataPart

denormalizeFieldInformation :: NormalizedFieldInformation -> Normalizer FieldInformation
denormalizeFieldInformation fieldInformation = do
  semanticFieldType <- denormalize fieldInformation.normalizedType
  pure FieldInformation {semanticType = semanticFieldType, optional = fieldInformation.optional}

denormalizeData :: QualifiedName -> Map Text NormalizedGenericArgument -> Normalizer SemanticType
denormalizeData qualifiedName arguments = do
  semanticArguments <- mapM denormalizeGenericArgument arguments
  pure $ SemanticTypeData qualifiedName semanticArguments

denormalizeGenericArgument :: NormalizedGenericArgument -> Normalizer SemanticGenericArgument
denormalizeGenericArgument genericArgument = case genericArgument of
  NormalizedGenericArgumentType normalizedType -> SemanticGenericArgumentType <$> denormalize normalizedType
  NormalizedGenericArgumentEffect effect -> SemanticGenericArgumentEffect <$> denormalizeEffect effect
  NormalizedGenericArgumentAttribute attribute -> pure $ SemanticGenericArgumentAttribute (denormalizeAttribute attribute)

denormalizeAttribute :: NormalizedAttribute -> SemanticAttribute
denormalizeAttribute attribute =
  case [SemanticAttributePrivate | attribute.private] <> (SemanticAttributeGeneric <$> Set.toList attribute.generic) of
    [] -> SemanticAttributePublic
    [single] -> single
    many -> SemanticAttributeUnion many

denormalizeEffect :: NormalizedEffect -> Normalizer SemanticEffect
denormalizeEffect effect = case effect of
  NormalizedEffectAny -> pure SemanticEffectAny
  NormalizedEffectRow effectRow -> do
    requestEffects <- mapM (uncurry denormalizeRequest) (Map.toList effectRow.request)
    let genericEffects = SemanticEffectGeneric <$> Set.toList effectRow.generic
    pure $ case requestEffects <> genericEffects of
      [] -> SemanticEffectPure
      [single] -> single
      many -> SemanticEffectUnion many

denormalizeRequest :: QualifiedName -> Map Text NormalizedGenericArgument -> Normalizer SemanticEffect
denormalizeRequest qualifiedName arguments = do
  semanticArguments <- mapM denormalizeGenericArgument arguments
  pure $ SemanticEffectRequest qualifiedName semanticArguments
