-- | Logic over the normalized type representation: normalization from semantic types, the
-- union / intersection lattice, subtyping, generic substitution, and denormalization back to
-- display-oriented semantic types. The passive data definitions live in "Katari.Data.NormalizedType".
--
-- Two structural ideas organise this module:
--
--   * 'TypeLattice' — types, effects, attributes and generic arguments all support the same three
--     relations: join (union), meet (intersection) and ordering (subtype). Join and meet are
--     written once as 'combine', parameterised by a 'LatticeDirection'; every dual rule
--     (absent slots, contravariant positions, effect-tail lacks) flips the direction instead of
--     duplicating the traversal.
--
--   * The subtyping /world/ — an attribute is not distributed into a type's interior; instead
--     'subtype' carries the attribute of the context it is comparing inside (the 'world'), and
--     compares every attribute joined with it. Descending through a private expectation raises the
--     world ('withWorld'), so "a value observed through a private container is itself private" holds
--     without any eager push-down. Attributes therefore stay exactly where they were written.
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
import Katari.Data.Environment (DataEnvironment, DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestEnvironment, RequestInformation (..))
import Katari.Data.GenericKind (GenericKind (..), renderGenericKind)
import Katari.Data.Id (GenericId)
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType (FieldInformation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..))
import Katari.Data.Variance (Variance (..))
import Katari.Error (CannotBeIntersectedErrorInfo (..), CannotBeUnionedErrorInfo (..), GenericArityErrorInfo (..), KindErrorInfo (..), SubtypeErrorInfo (..), TypeError (..))
import Katari.Panic (panic)

------------------------------------------------------------------------------------------------
-- The normalizer monad
------------------------------------------------------------------------------------------------

-- | The context every subtype / union / intersect comparison runs against: the nominal environment,
-- the in-scope generics (for their declared bounds), and the subtyping 'world'. The checker embeds
-- this verbatim ('Katari.Typechecker.Context.CheckerEnvironment') rather than duplicating its fields,
-- so there is a single source of truth and no projection copy.
data SubtypingContext = SubtypingContext
  { dataEnvironment :: DataEnvironment,
    requestEnvironment :: RequestEnvironment,
    -- | The generic parameters currently in scope, keyed by id, so 'boundArgumentFor' can resolve a
    -- generic's declared upper bound during a subtype check. Empty while the env-build normalizes the
    -- declarations themselves (their own bounds are not resolved there); populated by the checker.
    genericsInScope :: Map GenericId GenericParameterInformation,
    -- | The attribute of the context the current 'subtype' comparison is nested inside: bottom
    -- (public) at the top level, raised by 'withWorld' as the comparison descends through private
    -- expectations. Every attribute is compared joined with it.
    world :: NormalizedAttribute
  }
  deriving (Eq, Show)

-- | The normalizer runs over exactly the subtyping context.
type NormalizerEnvironment = SubtypingContext

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
-- Environment lookups. A name absent here is a compiler-invariant violation, not a user error: the
-- identifier resolved it and the environment is built complete, so the lookup 'panic's. The
-- user-facing "undefined name" belongs to the identifier phase (K2xxx).
------------------------------------------------------------------------------------------------

dataInfoFor :: QualifiedName -> Normalizer DataInformation
dataInfoFor qualifiedName = do
  maybeDataInformation <- asks (\environment -> Map.lookup qualifiedName environment.dataEnvironment)
  case maybeDataInformation of
    Just dataInfo -> pure dataInfo
    Nothing -> panic ("data type absent from the environment after name resolution: " <> renderQualifiedName qualifiedName)

requestInfoFor :: QualifiedName -> Normalizer RequestInformation
requestInfoFor qualifiedName = do
  maybeRequestInformation <- asks (\environment -> Map.lookup qualifiedName environment.requestEnvironment)
  case maybeRequestInformation of
    Just requestInfo -> pure requestInfo
    Nothing -> panic ("request absent from the environment after name resolution: " <> renderQualifiedName qualifiedName)

-- | Report when a data / request application does not supply exactly the declared generic
-- arguments. Runs once, at the semantic -> normalized boundary ('normalizeType' /
-- 'normalizeEffect'); the lattice and subtype code assume complete argument maps afterwards.
checkGenericArity :: QualifiedName -> Map Text GenericParameterInformation -> Map Text a -> Normalizer ()
checkGenericArity qualifiedName declaredParameters arguments =
  unless (Map.keysSet declaredParameters == Map.keysSet arguments) $
    tell
      [ TypeErrorGenericArity $
          GenericArityErrorInfo
            { name = qualifiedName,
              expected = Map.keys declaredParameters,
              actual = Map.keys arguments
            }
      ]

checkDataArity :: QualifiedName -> Map Text a -> Normalizer ()
checkDataArity qualifiedName arguments = do
  dataInfo <- dataInfoFor qualifiedName
  checkGenericArity qualifiedName dataInfo.genericParameters.parameterInformation arguments

checkRequestArity :: QualifiedName -> Map Text a -> Normalizer ()
checkRequestArity qualifiedName arguments = do
  requestInfo <- requestInfoFor qualifiedName
  checkGenericArity qualifiedName requestInfo.genericParameters.parameterInformation arguments

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

-- | A generic argument name absent from the declaration's parameters. 'checkGenericArity' runs at
-- normalization, so by the time the lattice / subtype code sees the arguments the name set matches
-- the declaration; an unknown name here is a compiler-invariant violation, not a user error.
panicUnknownGeneric :: Text -> a
panicUnknownGeneric genericArgumentName =
  panic ("generic argument absent from the declaration after the arity check: " <> genericArgumentName)

-- | An invariant generic argument received two different instantiations; report it for the
-- direction ('Join' = union, 'Meet' = intersection) being computed.
tellInvariantMismatch :: LatticeDirection -> NormalizedKindedType -> NormalizedKindedType -> Normalizer ()
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
    -- NOTE: an array is a homogeneous sequence with no fixed prefix; every position reads as the
    -- element type or @null@ (an out-of-range read is null), so the tail is @item | null@. That null
    -- in the tail is exactly what makes @array[T] </: [T]@ — an array cannot stand in for a
    -- fixed-length tuple, because its positions may be absent (@item | null </: item@).
    pure $ layered neverLayer {sequenceLayer = Just NormalizedSequence {items = [], rest = orNull normalizedItemType}}
  SemanticTypeTuple itemTypes -> do
    normalizedItemTypes <- mapM normalizeType itemTypes
    -- NOTE: a tuple is fixed-length: there are no positions past its prefix, so the tail is @null@
    -- (a read past the end is null). This @null@ tail (against an array's @item | null@) is what lets
    -- a tuple stand in for an array (@[T] <: array[T]@) while keeping the unsound reverse out.
    pure $ layered neverLayer {sequenceLayer = Just NormalizedSequence {items = normalizedItemTypes, rest = publicNull}}
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
    -- NOTE: a @record[T]@ is a homogeneous object with no fixed fields; reading any key gives
    -- @T | null@ (an absent key is null), mirroring @array[T]@. A fixed object literal keeps its open
    -- @unknown@ tail (width subtyping ignores undeclared keys); only the homogeneous record carries
    -- the typed @T | null@ tail.
    pure $ layered neverLayer {objectLayer = Just NormalizedObject {fields = mempty, rest = orNull normalizedRecordType}}
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
    publicNull = layered neverLayer {nullLayer = True}
    -- A homogeneous container reads as @element | null@ (an out-of-range / absent read is null). On
    -- @unknown@ (already the top, which subsumes null) this is the identity.
    orNull normalizedType = case normalizedType.baseType of
      NormalizedBaseTypeUnknown -> normalizedType
      NormalizedBaseTypeLayered layer -> normalizedType {baseType = NormalizedBaseTypeLayered layer {nullLayer = True}}

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
    pure $ NormalizedEffectRow $ EffectRow {request = Map.singleton qualifiedName normalizedGenericArguments, tails = mempty}
  SemanticEffectGeneric genericArgumentName ->
    pure $ NormalizedEffectRow $ EffectRow {request = mempty, tails = Map.singleton genericArgumentName mempty}
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
          EffectRow
            { -- the overwrite wins over the base's concrete request of the same name (left-biased union)
              request = Map.union overwriteRequests effectRow.request,
              -- and over every tail's contribution: the overwritten names are removed from each tail
              tails = Map.map (Set.union (Map.keysSet overwriteRequests)) effectRow.tails
            }
  SemanticEffectUnion effects -> foldM union bottomEffect =<< mapM normalizeEffect effects

normalizeGenericArgument :: SemanticGenericArgument -> Normalizer NormalizedKindedType
normalizeGenericArgument genericArgument = case genericArgument of
  SemanticGenericArgumentAttribute attribute -> NormalizedKindedTypeAttribute <$> normalizeAttribute attribute
  SemanticGenericArgumentEffect effect -> NormalizedKindedTypeEffect <$> normalizeEffect effect
  SemanticGenericArgumentType semanticType -> NormalizedKindedTypeType <$> normalizeType semanticType

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
-- slots, effect-tail lacks) flip the direction with 'dualDirection' instead of duplicating code.
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
      pure $ NormalizedEffectRow $ EffectRow {request = combinedRequests, tails = combineTails direction leftRow.tails rightRow.tails}

  subtype left right = case (left, right) of
    (NormalizedEffectAny, NormalizedEffectAny) -> pure ()
    (NormalizedEffectAny, NormalizedEffectRow _) ->
      tellEffectMismatch "Any effect cannot be a subtype of a known effect" left right
    (NormalizedEffectRow _, NormalizedEffectAny) -> pure ()
    (NormalizedEffectRow _, NormalizedEffectRow rightRow) -> do
      -- Expand the left's tails to their upper bounds (transitively), treating the supertype's own
      -- tails as already covered, then compare requests and tail lacks.
      effectiveLeft <- boundedEffect rightRow.tails left
      case effectiveLeft of
        -- A left-only tail is unbounded (any), so the effective left effect is any and cannot be a
        -- subtype of a known effect row.
        NormalizedEffectAny -> tellEffectMismatch "A left-only effect generic is unbounded, so the left effect is effectively any" effectiveLeft right
        NormalizedEffectRow effectiveLeftRow -> do
          -- NOTE: requests are covariant; every request the left performs must appear on the right
          mapM_
            ( \(qualifiedName, leftArguments) ->
                case Map.lookup qualifiedName rightRow.request of
                  Nothing -> tellEffectMismatch ("Left effect performs a request not present in the right effect: " <> renderQualifiedName qualifiedName) effectiveLeft right
                  Just rightArguments -> do
                    requestInfo <- requestInfoFor qualifiedName
                    subtypeArgumentsWith ((.variance) <$> requestInfo.genericParameters.parameterInformation) leftArguments rightArguments
            )
            (Map.toList effectiveLeftRow.request)
          -- NOTE: a tail's lacks set is contravariant: the left's @E@ is covered by the right's @E@
          -- only if the right removes no more requests than the left (right lacks ⊆ left lacks).
          mapM_
            ( \(genericId, leftLacks) ->
                case Map.lookup genericId rightRow.tails of
                  Nothing -> tellEffectMismatch "Left effect has an effect generic not present in the right effect" effectiveLeft right
                  Just rightLacks ->
                    unless (rightLacks `Set.isSubsetOf` leftLacks) $
                      tellEffectMismatch "Effect generic overrides are incompatible" effectiveLeft right
            )
            (Map.toList effectiveLeftRow.tails)

-- | Combine the argument maps of one request name according to the request's declared variances.
combineRequestArguments :: LatticeDirection -> QualifiedName -> Map Text NormalizedKindedType -> Map Text NormalizedKindedType -> Normalizer (Map Text NormalizedKindedType)
combineRequestArguments direction qualifiedName leftArguments rightArguments = do
  requestInfo <- requestInfoFor qualifiedName
  combineArgumentMap direction ((.variance) <$> requestInfo.genericParameters.parameterInformation) leftArguments rightArguments

-- | Combine the tails of two effect rows. A tail variable behaves covariantly (the join keeps tails
-- of either side, the meet only shared ones), but its lacks set is contravariant: @E \\ left@ joined
-- with @E \\ right@ is @E \\ (left ∩ right)@ (removed only if removed on both), and met is
-- @E \\ (left ∪ right)@. So the keys combine per the direction and the lacks per the dual.
combineTails :: LatticeDirection -> Map GenericId (Set QualifiedName) -> Map GenericId (Set QualifiedName) -> Map GenericId (Set QualifiedName)
combineTails = \case
  Join -> Map.unionWith Set.intersection
  Meet -> Map.intersectionWith Set.union

instance TypeLattice NormalizedKindedType where
  combine direction leftArgument rightArgument = case (leftArgument, rightArgument) of
    (NormalizedKindedTypeType leftType, NormalizedKindedTypeType rightType) ->
      NormalizedKindedTypeType <$> combine direction leftType rightType
    (NormalizedKindedTypeEffect leftEffect, NormalizedKindedTypeEffect rightEffect) ->
      NormalizedKindedTypeEffect <$> combine direction leftEffect rightEffect
    (NormalizedKindedTypeAttribute leftAttribute, NormalizedKindedTypeAttribute rightAttribute) ->
      NormalizedKindedTypeAttribute <$> combine direction leftAttribute rightAttribute
    _ -> do
      tellKindMismatch (kindOf leftArgument) (kindOf rightArgument) $ case direction of
        Join -> "Generic arguments with different kinds cannot be unioned"
        Meet -> "Generic arguments with different kinds cannot be intersected"
      pure leftArgument -- NOTE: either side works; the pair is not combinable anyway

  subtype leftArgument rightArgument = case (leftArgument, rightArgument) of
    (NormalizedKindedTypeType leftType, NormalizedKindedTypeType rightType) -> subtype leftType rightType
    (NormalizedKindedTypeEffect leftEffect, NormalizedKindedTypeEffect rightEffect) -> subtype leftEffect rightEffect
    (NormalizedKindedTypeAttribute leftAttribute, NormalizedKindedTypeAttribute rightAttribute) -> subtype leftAttribute rightAttribute
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
      dataInfo <- dataInfoFor qualifiedName
      combineArgumentMap direction ((.variance) <$> dataInfo.genericParameters.parameterInformation) leftArguments rightArguments

-- | Combine the named generic arguments of one data type or request, each according to its
-- declared variance:
--   covariant     -> combine in the same direction
--   contravariant -> combine in the dual direction
--   invariant     -> the two instantiations must be identical
--   bivariant     -> unconstrained; combine in the same direction
-- Ex) req1[T, U] covariant in T, contravariant in U:
--     req1[int, string] | req1[string, number] ~> req1[int | string, string & number]
combineArgumentMap :: LatticeDirection -> Map Text Variance -> Map Text NormalizedKindedType -> Map Text NormalizedKindedType -> Normalizer (Map Text NormalizedKindedType)
combineArgumentMap direction variances = unionWithKeyM combineNamedArgument
  where
    combineNamedArgument genericArgumentName leftArgument rightArgument = case Map.lookup genericArgumentName variances of
      Nothing -> panicUnknownGeneric genericArgumentName
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

-- | Merge two sequences position-by-position; a position present on only one side is combined with
-- the other side's tail ('rest'), which is @null@ for a tuple.
-- Ex) [number, string] | [boolean] ~> [number | boolean, string | null]
--     [number, string] & [boolean] ~> [number & boolean, string & null]
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
subtypeData :: NormalizedAttribute -> Map QualifiedName (Map Text NormalizedKindedType) -> NormalizedType -> LayeredType -> Normalizer ()
subtypeData leftAttribute leftDataLayer right rightLayer = mapM_ checkData (Map.toList leftDataLayer)
  where
    checkData (qualifiedName, leftArguments) = do
      dataInfo <- dataInfoFor qualifiedName
      case Map.lookup qualifiedName rightLayer.dataLayer of
        Just rightArguments -> do
          ((), nominalErrors) <- captureErrors $ subtypeArgumentsWith ((.variance) <$> dataInfo.genericParameters.parameterInformation) leftArguments rightArguments
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
constructorSubstitution :: DataInformation -> Map Text NormalizedKindedType -> Map GenericId NormalizedKindedType
constructorSubstitution dataInfo arguments =
  Map.fromList
    [ (genericId, argument)
      | (genericArgumentName, genericId) <- Map.toList ((.genericId) <$> dataInfo.genericParameters.parameterInformation),
        Just argument <- [Map.lookup genericArgumentName arguments]
    ]

-- | Compare the named generic arguments of one data type or request pointwise, each according to
-- its declared variance. Argument maps are complete by construction ('checkGenericArity' runs at
-- normalization), so the shared key set is the full declared set:
--   covariant     -> left <: right
--   contravariant -> right <: left
--   invariant     -> both directions
--   bivariant     -> no constraint
subtypeArgumentsWith :: Map Text Variance -> Map Text NormalizedKindedType -> Map Text NormalizedKindedType -> Normalizer ()
subtypeArgumentsWith variances leftArguments rightArguments =
  mapM_ checkNamedArgument (Map.toList (Map.intersectionWith (,) leftArguments rightArguments))
  where
    checkNamedArgument (genericArgumentName, (leftArgument, rightArgument)) =
      case Map.lookup genericArgumentName variances of
        Nothing -> panicUnknownGeneric genericArgumentName
        Just Covariant -> subtype leftArgument rightArgument
        Just Contravariant -> subtype rightArgument leftArgument
        Just Invariant -> do
          subtype leftArgument rightArgument
          subtype rightArgument leftArgument
        Just Bivariant -> pure ()

------------------------------------------------------------------------------------------------
-- Generic upper bounds
------------------------------------------------------------------------------------------------

-- | The upper-bound argument registered for a generic id, if any (callers default an absent one to
-- their own kind's top, so an unbounded generic never passes a subtype check vacuously).
boundArgumentFor :: GenericId -> Normalizer (Maybe NormalizedKindedType)
boundArgumentFor genericId = asks (\environment -> Map.lookup genericId environment.genericsInScope >>= (.upperBound))

-- | Iterate a value's generics to a fixpoint: resolve every not-yet-covered generic with @absorb@,
-- repeating because a bound may introduce further generics. @coveredGenerics@ are left untouched
-- (the supertype's own generics during a subtype check cancel rather than expand); generics nested
-- in inner layers are resolved when the comparison recurses into them, not here.
resolveGenerics :: (a -> Set GenericId) -> (a -> GenericId -> Normalizer a) -> Set GenericId -> a -> Normalizer a
resolveGenerics genericsOf absorb coveredGenerics = resolve Set.empty
  where
    resolve resolvedGenerics current = do
      let genericsToResolve = Set.difference (genericsOf current) (Set.union coveredGenerics resolvedGenerics)
      if Set.null genericsToResolve
        then pure current
        else do
          raised <- foldM absorb current (Set.toList genericsToResolve)
          resolve (Set.union resolvedGenerics genericsToResolve) raised

-- | Raise a type to the upper bounds of its own generics, joining ('union') each bound in; an
-- unregistered generic extends the type top.
boundedType :: Set GenericId -> NormalizedType -> Normalizer NormalizedType
boundedType = resolveGenerics (\normalizedType -> normalizedType.generics) absorbBound
  where
    absorbBound accumulated genericId = do
      maybeArgument <- boundArgumentFor genericId
      case maybeArgument of
        Nothing -> union accumulated topType
        Just (NormalizedKindedTypeType bound) -> union accumulated bound
        Just other -> accumulated <$ tellKindMismatch GenericKindType (kindOf other) "Expected a type bound for a type generic"

-- | Raise an attribute to the upper bounds of its own generics; as 'boundedType', for the attribute
-- lattice.
boundedAttribute :: Set GenericId -> NormalizedAttribute -> Normalizer NormalizedAttribute
boundedAttribute = resolveGenerics (\attribute -> attribute.generic) absorbBound
  where
    absorbBound accumulated genericId = do
      maybeArgument <- boundArgumentFor genericId
      case maybeArgument of
        Nothing -> union accumulated topAttribute
        Just (NormalizedKindedTypeAttribute bound) -> union accumulated bound
        Just other -> accumulated <$ tellKindMismatch GenericKindAttribute (kindOf other) "Expected an attribute bound for an attribute generic"

-- | Restrict an effect to lack the given request names: drop them from its concrete requests and
-- add them to every tail's lacks set. This re-applies an override's precedence wherever a tail is
-- replaced by a concrete effect (bound expansion, substitution). @all@ has no representable
-- restriction, so it is returned unchanged (a sound over-approximation).
restrictEffect :: Set QualifiedName -> NormalizedEffect -> NormalizedEffect
restrictEffect lacks = \case
  NormalizedEffectAny -> NormalizedEffectAny
  NormalizedEffectRow effectRow ->
    NormalizedEffectRow
      EffectRow
        { request = Map.withoutKeys effectRow.request lacks,
          tails = Map.map (Set.union lacks) effectRow.tails
        }

-- | The declared upper bound of an effect generic; an unregistered generic defaults to @all@. The
-- effect lattice resolves tails bespoke (see 'boundedEffect'), so it is not folded by 'boundedType'.
effectBoundFor :: GenericId -> Normalizer NormalizedEffect
effectBoundFor genericId = do
  maybeArgument <- boundArgumentFor genericId
  case maybeArgument of
    Nothing -> pure topEffect
    Just (NormalizedKindedTypeEffect bound) -> pure bound
    Just other -> topEffect <$ tellKindMismatch GenericKindEffect (kindOf other) "Expected an effect bound for an effect generic"

-- | Expand an effect's tails to their upper bounds, transitively: each tail @(E, lacks)@ becomes
-- @E@'s bound restricted to lack those names ('restrictEffect'), joined in. Tails in @coveredTails@
-- are left in place (the supertype's own tails during a subtype check cancel rather than expand).
boundedEffect :: Map GenericId (Set QualifiedName) -> NormalizedEffect -> Normalizer NormalizedEffect
boundedEffect coveredTails = resolve Set.empty
  where
    resolve resolvedTails = \case
      NormalizedEffectAny -> pure NormalizedEffectAny
      NormalizedEffectRow effectRow -> do
        let tailsToExpand = Map.withoutKeys effectRow.tails (Set.union (Map.keysSet coveredTails) resolvedTails)
        if Map.null tailsToExpand
          then pure (NormalizedEffectRow effectRow)
          else do
            expansions <- mapM (\(genericId, lacks) -> restrictEffect lacks <$> effectBoundFor genericId) (Map.toList tailsToExpand)
            raised <- foldM union (NormalizedEffectRow effectRow {tails = Map.withoutKeys effectRow.tails (Map.keysSet tailsToExpand)}) expansions
            resolve (Set.union resolvedTails (Map.keysSet tailsToExpand)) raised

------------------------------------------------------------------------------------------------
-- Generic substitution
------------------------------------------------------------------------------------------------

-- | Literal substitution of generic ids. A generic id occurring in a node's generics set is
-- removed and its replacement unioned into that node (the set representation means "this node is
-- a union with the generic", so unioning the replacement in is exact substitution, not an
-- approximation), and nested argument positions are substituted recursively. Ids missing from the
-- map are left untouched. Used to instantiate a data constructor type with concrete arguments.
substituteType :: Map GenericId NormalizedKindedType -> NormalizedType -> Normalizer NormalizedType
substituteType substitution normalizedType = do
  substitutedBaseType <- case normalizedType.baseType of
    NormalizedBaseTypeUnknown -> pure NormalizedBaseTypeUnknown
    NormalizedBaseTypeLayered layered -> NormalizedBaseTypeLayered <$> substituteLayered layered
  substitutedAttribute <- substituteAttribute substitution normalizedType.attribute
  -- Replace the node's own type generics: drop each replaced id from the set and union its (type)
  -- replacement into the node.
  let (replaced, kept) = Set.partition (`Map.member` substitution) normalizedType.generics
      base = normalizedType {baseType = substitutedBaseType, attribute = substitutedAttribute, generics = kept}
  foldM absorbType base (Map.elems (Map.restrictKeys substitution replaced))
  where
    absorbType accumulated = \case
      NormalizedKindedTypeType replacement -> union accumulated replacement
      other -> accumulated <$ tellKindMismatch GenericKindType (kindOf other) "Expected a type argument for a type generic"
    substituteLayered layered = do
      functionLayer <- traverse substituteFunction layered.functionLayer
      sequenceLayer <- traverse substituteSequence layered.sequenceLayer
      objectLayer <- traverse substituteObject layered.objectLayer
      dataLayer <- traverse (traverse (substituteGenericArgument substitution)) layered.dataLayer
      pure layered {functionLayer = functionLayer, sequenceLayer = sequenceLayer, objectLayer = objectLayer, dataLayer = dataLayer}
    substituteFunction function =
      NormalizedFunction
        <$> substituteType substitution function.argumentType
        <*> substituteType substitution function.returnType
        <*> substituteEffect substitution function.effect
    substituteSequence normalizedSequence = do
      items <- mapM (substituteType substitution) normalizedSequence.items
      rest <- substituteType substitution normalizedSequence.rest
      pure NormalizedSequence {items = items, rest = rest}
    substituteObject normalizedObject = do
      fields <- mapM (\field -> (\substituted -> field {normalizedType = substituted}) <$> substituteType substitution field.normalizedType) normalizedObject.fields
      rest <- substituteType substitution normalizedObject.rest
      pure NormalizedObject {fields = fields, rest = rest}

-- | As 'substituteType', for effects (effect-kind generic ids and the request arguments). A tail
-- @(E, lacks)@ whose @E@ is substituted is replaced by its replacement restricted to lack those
-- names ('restrictEffect') — the override's precedence, re-applied at substitution as at bound
-- expansion.
substituteEffect :: Map GenericId NormalizedKindedType -> NormalizedEffect -> Normalizer NormalizedEffect
substituteEffect substitution effect = case effect of
  NormalizedEffectAny -> pure NormalizedEffectAny
  NormalizedEffectRow effectRow -> do
    substitutedRequests <- mapM (mapM (substituteGenericArgument substitution)) effectRow.request
    let (replacedTails, keptTails) = Map.partitionWithKey (\genericId _ -> Map.member genericId substitution) effectRow.tails
        base = NormalizedEffectRow effectRow {request = substitutedRequests, tails = keptTails}
    foldM spliceTail base (Map.toList replacedTails)
  where
    spliceTail accumulated (genericId, lacks) = case Map.lookup genericId substitution of
      Just (NormalizedKindedTypeEffect replacement) -> union accumulated (restrictEffect lacks replacement)
      Just other -> accumulated <$ tellKindMismatch GenericKindEffect (kindOf other) "Expected an effect argument for an effect generic"
      Nothing -> pure accumulated

-- | As 'substituteType', for attributes (attribute-kind generic ids).
substituteAttribute :: Map GenericId NormalizedKindedType -> NormalizedAttribute -> Normalizer NormalizedAttribute
substituteAttribute substitution attribute = do
  let (replaced, kept) = Set.partition (`Map.member` substitution) attribute.generic
      base = NormalizedAttribute {private = attribute.private, generic = kept}
  foldM absorbAttribute base (Map.elems (Map.restrictKeys substitution replaced))
  where
    absorbAttribute accumulated = \case
      NormalizedKindedTypeAttribute replacement -> union accumulated replacement
      other -> accumulated <$ tellKindMismatch GenericKindAttribute (kindOf other) "Expected an attribute argument for an attribute generic"

substituteGenericArgument :: Map GenericId NormalizedKindedType -> NormalizedKindedType -> Normalizer NormalizedKindedType
substituteGenericArgument substitution genericArgument = case genericArgument of
  NormalizedKindedTypeType normalizedType -> NormalizedKindedTypeType <$> substituteType substitution normalizedType
  NormalizedKindedTypeEffect effect -> NormalizedKindedTypeEffect <$> substituteEffect substitution effect
  NormalizedKindedTypeAttribute attribute -> NormalizedKindedTypeAttribute <$> substituteAttribute substitution attribute

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

-- | The element type a homogeneous @array[T]@ / @record[T]@ displays. Their normalized tail is
-- @T | null@ (every position / key read is out-of-range-nullable), so the surface form drops the
-- implicit @null@. When the tail is exactly @null@ the element type genuinely is @null@, so it is
-- kept — an @array[null]@ must not render as @array[never]@.
displayElementType :: NormalizedType -> NormalizedType
displayElementType rest = case rest.baseType of
  NormalizedBaseTypeUnknown -> rest
  NormalizedBaseTypeLayered layer ->
    let stripped = rest {baseType = NormalizedBaseTypeLayered layer {nullLayer = False}}
     in if stripped.baseType == NormalizedBaseTypeLayered neverLayer && Set.null stripped.generics
          then rest
          else stripped

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
          -- A homogeneous array's tail is @T | null@; the surface form is @array[T]@, so the implicit
          -- out-of-range null is dropped for display ('displayElementType').
          semanticItem <- denormalize (displayElementType normalizedSequence.rest)
          pure [SemanticTypeArray semanticItem]
        else do
          -- A tuple's @null@ tail is implicit (a fixed-length sequence), so only the prefix is shown.
          semanticItems <- mapM denormalize normalizedSequence.items
          pure [SemanticTypeTuple semanticItems]
  objectPart <- case layeredType.objectLayer of
    Nothing -> pure []
    Just normalizedObject ->
      if Map.null normalizedObject.fields
        then do
          semanticRecord <- denormalize (displayElementType normalizedObject.rest)
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

denormalizeData :: QualifiedName -> Map Text NormalizedKindedType -> Normalizer SemanticType
denormalizeData qualifiedName arguments = do
  semanticArguments <- mapM denormalizeGenericArgument arguments
  pure $ SemanticTypeData qualifiedName semanticArguments

denormalizeGenericArgument :: NormalizedKindedType -> Normalizer SemanticGenericArgument
denormalizeGenericArgument genericArgument = case genericArgument of
  NormalizedKindedTypeType normalizedType -> SemanticGenericArgumentType <$> denormalize normalizedType
  NormalizedKindedTypeEffect effect -> SemanticGenericArgumentEffect <$> denormalizeEffect effect
  NormalizedKindedTypeAttribute attribute -> pure $ SemanticGenericArgumentAttribute (denormalizeAttribute attribute)

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
    let genericEffects = SemanticEffectGeneric <$> Map.keys effectRow.tails
    pure $ case requestEffects <> genericEffects of
      [] -> SemanticEffectPure
      [single] -> single
      many -> SemanticEffectUnion many

denormalizeRequest :: QualifiedName -> Map Text NormalizedKindedType -> Normalizer SemanticEffect
denormalizeRequest qualifiedName arguments = do
  semanticArguments <- mapM denormalizeGenericArgument arguments
  pure $ SemanticEffectRequest qualifiedName semanticArguments
