module Katari.Data.NormalizedType where

import Control.Monad (foldM, when)
import Control.Monad.RWS (RWS)
import Control.Monad.RWS.Class (MonadWriter (..), asks)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import GHC.List (List)
import Katari.Common (intersectWithKeyM, mapMaybeM, unionWithKeyM)
import Katari.Data.Environment (DataEnvironment, GenericBoundEnvironment, RequestEnvironment, variance)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType (FieldInfomation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..), semanticType)
import Katari.Data.Variant (Variance (..))
import Safe (atMay)

-- | NOTE: Bottom & Top types
-- Bottom ... never of public
-- Top ... unknown of private  <--  unknown of public is not top
data NormalizedType where
  NormalizedType :: {baseType :: NormalizedBaseType, attribute :: NormalizedAttribute} -> NormalizedType
  deriving (Eq, Ord, Show)

data NormalizedBaseType where
  NormalizedBaseTypeUnknown :: NormalizedBaseType
  NormalizedBaseTypeLayerd :: LayeredType -> NormalizedBaseType
  deriving (Eq, Ord, Show)

data LayeredType where
  LayeredType ::
    { nullLayer :: Bool,
      numberLayer :: NumberSlot,
      stringLayer :: Bool,
      booleanLayer :: Bool,
      fileLayer :: Bool,
      functionLayer :: FunctionSlot,
      -- tuple, array
      sequenceLayer :: SequenceSlot,
      -- object, record
      objectLayer :: ObjectSlot,
      dataLayer :: Map QualifiedName (Map Text NormalizedGenericArgument),
      genericLayer :: Set GenericId
    } ->
    LayeredType
  deriving (Eq, Ord, Show)

data NumberSlot where
  NumberSlotAbsent :: NumberSlot
  NumberSlotInteger :: NumberSlot
  NumberSlotNumber :: NumberSlot
  deriving (Eq, Ord, Show)

data FunctionSlot where
  FunctionSlotAbsent :: FunctionSlot
  FunctionSlotOf :: NormalizedType -> NormalizedType -> NormalizedEffect -> FunctionSlot
  deriving (Eq, Ord, Show)

data SequenceSlot where
  SequenceSlotAbsent :: SequenceSlot
  SequenceSlotOf :: NormalizedSequence -> SequenceSlot
  deriving (Eq, Ord, Show)

data NormalizedSequence where
  NormalizedSequence ::
    { items :: List NormalizedType,
      rest :: NormalizedType -- NOTE: Type of ANY further elements (the array tail). A plain tuple has rest = unknown of public, an array has items = [] and rest = element type.
    } ->
    NormalizedSequence
  deriving (Eq, Ord, Show)

data ObjectSlot where
  ObjectSlotAbsent :: ObjectSlot
  ObjectSlotOf :: NormalizedObject -> ObjectSlot
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

data SubtypeError where
  SubtypeError ::
    SubtypeErrorInfo ->
    SubtypeError
  UnknownRequestError ::
    UnknownRequestErrorInfo ->
    SubtypeError
  UnknownDataError ::
    UnknownDataErrorInfo ->
    SubtypeError
  UnknownGenericError ::
    UnknownGenericErrorInfo ->
    SubtypeError
  CannotBeUnionedError ::
    CannotBeUnionedErrorInfo ->
    SubtypeError
  CannotBeIntersectedError ::
    CannotBeIntersectedErrorInfo ->
    SubtypeError
  KindError ::
    KindErrorInfo ->
    SubtypeError
  deriving (Eq, Ord, Show)

data SubtypeErrorInfo where
  SubtypeErrorInfo ::
    { expected :: NormalizedGenericArgument,
      actual :: NormalizedGenericArgument,
      message :: Text
    } ->
    SubtypeErrorInfo
  deriving (Eq, Ord, Show)

data UnknownRequestErrorInfo where
  UnknownRequestErrorInfo ::
    { expected :: QualifiedName,
      message :: Text
    } ->
    UnknownRequestErrorInfo
  deriving (Eq, Ord, Show)

data UnknownDataErrorInfo where
  UnknownDataErrorInfo ::
    { expected :: QualifiedName,
      message :: Text
    } ->
    UnknownDataErrorInfo
  deriving (Eq, Ord, Show)

data UnknownGenericErrorInfo where
  UnknownGenericErrorInfo ::
    { expected :: Text,
      message :: Text
    } ->
    UnknownGenericErrorInfo
  deriving (Eq, Ord, Show)

data CannotBeUnionedErrorInfo where
  CannotBeUnionedErrorInfo ::
    { left :: NormalizedGenericArgument,
      right :: NormalizedGenericArgument,
      message :: Text
    } ->
    CannotBeUnionedErrorInfo
  deriving (Eq, Ord, Show)

data CannotBeIntersectedErrorInfo where
  CannotBeIntersectedErrorInfo ::
    { left :: NormalizedGenericArgument,
      right :: NormalizedGenericArgument,
      message :: Text
    } ->
    CannotBeIntersectedErrorInfo
  deriving (Eq, Ord, Show)

data KindErrorInfo where
  KindErrorInfo ::
    { expected :: Text,
      actual :: Text,
      message :: Text
    } ->
    KindErrorInfo
  deriving (Eq, Ord, Show)

data NormalizerEnvironment = NormalizeEnvironment
  { dataEnvironment :: DataEnvironment NormalizedType,
    requestEnvironment :: RequestEnvironment NormalizedType,
    genericBoundEnvironment :: GenericBoundEnvironment NormalizedGenericArgument
  }
  deriving (Eq, Show)

type Normalizer a = RWS NormalizerEnvironment (List SubtypeError) () a

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
      functionLayer = FunctionSlotAbsent,
      sequenceLayer = SequenceSlotAbsent,
      objectLayer = ObjectSlotAbsent,
      dataLayer = mempty,
      genericLayer = mempty
    }

bottomType :: NormalizedType
bottomType = NormalizedType {baseType = NormalizedBaseTypeLayerd neverLayer, attribute = bottomAttribute}

bottomAttribute :: NormalizedAttribute
bottomAttribute = NormalizedAttribute {private = False, generic = Set.empty}

bottomEffect :: NormalizedEffect
bottomEffect = NormalizedEffectRow $ EffectRow {request = mempty, generic = mempty, shadowed = mempty}

topType :: NormalizedType
topType = NormalizedType {baseType = NormalizedBaseTypeUnknown, attribute = topAttribute}

topAttribute :: NormalizedAttribute
topAttribute = NormalizedAttribute {private = True, generic = Set.empty}

topEffect :: NormalizedEffect
topEffect = NormalizedEffectAny

normalizeType :: SemanticType -> Normalizer NormalizedType
normalizeType semanticBaseType = case semanticBaseType of
  SemanticTypeNever -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer
  SemanticTypeUnknown -> pure $ makeNormalizedTypeWithPublic NormalizedBaseTypeUnknown
  SemanticTypeAgent parameterType returnType effect -> do
    normalizedArgument <- normalizeType parameterType
    normalizedReturnType <- normalizeType returnType
    normalizedEffect <- normalizeEffect effect
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedBaseTypeLayerd $
          neverLayer
            { functionLayer = FunctionSlotOf normalizedArgument normalizedReturnType normalizedEffect
            }
  SemanticTypeNull -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {nullLayer = True}
  SemanticTypeBoolean -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {booleanLayer = True}
  SemanticTypeFile -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {fileLayer = True}
  SemanticTypeInteger -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {numberLayer = NumberSlotInteger}
  SemanticTypeNumber -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {numberLayer = NumberSlotNumber}
  SemanticTypeString -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {stringLayer = True}
  SemanticTypeArray itemType -> do
    normalizedItemType <- normalizeType itemType
    -- NOTE: an array is a sequence with no fixed prefix; every element falls under `rest`
    pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {sequenceLayer = SequenceSlotOf $ NormalizedSequence {items = [], rest = normalizedItemType}}
  SemanticTypeTuple itemTypes -> do
    normalizedItemTypes <- mapM normalizeType itemTypes
    -- NOTE: a tuple's tail is open (rest = unknown of public), mirroring how an object's other fields default to unknown of public
    pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {sequenceLayer = SequenceSlotOf $ NormalizedSequence {items = normalizedItemTypes, rest = NormalizedType {baseType = NormalizedBaseTypeUnknown, attribute = bottomAttribute}}}
  SemanticTypeData qualifiedName genericArguments -> do
    normalizedGenericArguments <- mapM normalizeGenericArgument genericArguments
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedBaseTypeLayerd neverLayer {dataLayer = Map.singleton qualifiedName normalizedGenericArguments}
  SemanticTypeObject fields -> do
    normalizedFields <- mapM normalizeFieldInformation fields
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedBaseTypeLayerd
          neverLayer
            { objectLayer =
                ObjectSlotOf $
                  NormalizedObject
                    { fields = normalizedFields,
                      -- NOTE: Other fields must be "public"
                      -- then; {x: number, y: number of private} /<: {x: number}  <-- Error because field y is private in the left type but public in the right type.
                      --       {x: number, y: number of private} <: {x: number} of private   <-- OK.
                      rest = NormalizedType {baseType = NormalizedBaseTypeUnknown, attribute = bottomAttribute}
                    }
            }
  SemanticTypeRecord recordType -> do
    normalizedRecordType <- normalizeType recordType
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedBaseTypeLayerd neverLayer {objectLayer = ObjectSlotOf $ NormalizedObject {fields = mempty, rest = normalizedRecordType}}
  SemanticTypeGeneric genericArgumentName -> pure $ makeNormalizedTypeWithPublic $ NormalizedBaseTypeLayerd neverLayer {genericLayer = Set.singleton genericArgumentName}
  SemanticTypeUnion semanticTypes -> do
    -- union environment $ fmap (normalize environment) semanticTypes
    normalizedTypes <- mapM normalizeType semanticTypes
    foldM unionType bottomType normalizedTypes
  SemanticTypeAttribute baseType attribute -> do
    normalized <- normalizeType baseType
    normalizedAttribute <- normalizeAttribute attribute
    unionedAttribute <- unionAttribute normalized.attribute normalizedAttribute
    pure $ normalized {attribute = unionedAttribute} -- NOTE: number of public of private ~> number of private
  where
    makeNormalizedTypeWithPublic normalizedBaseType =
      NormalizedType {baseType = normalizedBaseType, attribute = bottomAttribute} -- default attribute is public

normalizeAttribute :: SemanticAttribute -> Normalizer NormalizedAttribute
normalizeAttribute attribute = case attribute of
  SemanticAttributePublic -> pure $ NormalizedAttribute {private = False, generic = Set.empty}
  SemanticAttributePrivate -> pure $ NormalizedAttribute {private = True, generic = Set.empty}
  SemanticAttributeUnion attributes -> foldM unionAttribute bottomAttribute =<< mapM normalizeAttribute attributes
  SemanticAttributeGeneric genericArgumentName -> pure $ NormalizedAttribute {private = False, generic = Set.singleton genericArgumentName}

normalizeEffect :: SemanticEffect -> Normalizer NormalizedEffect
normalizeEffect effect = case effect of
  SemanticEffectPure -> pure bottomEffect
  SemanticEffectAny -> pure topEffect
  SemanticEffectRequest qualifiedName genericArguments -> do
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
              shadowed = Set.fromList $ Map.keys overwriteRequests
            }
  SemanticEffectUnion effects -> foldM unionEffect bottomEffect =<< mapM normalizeEffect effects

normalizeGenericArgument :: SemanticGenericArgument -> Normalizer NormalizedGenericArgument
normalizeGenericArgument genericArgument = case genericArgument of
  SemanticGenericArgumentAttribute attribute -> NormalizedGenericArgumentAttribute <$> normalizeAttribute attribute
  SemanticGenericArgumentEffect effect -> NormalizedGenericArgumentEffect <$> normalizeEffect effect
  SemanticGenericArgumentType semanticType -> NormalizedGenericArgumentType <$> normalizeType semanticType

normalizeFieldInformation :: FieldInfomation -> Normalizer NormalizedFieldInformation
normalizeFieldInformation fieldInformation = do
  normalizedType <- normalizeType fieldInformation.semanticType
  pure $
    NormalizedFieldInformation
      { normalizedType = normalizedType,
        optional = fieldInformation.optional
      }

unionType :: NormalizedType -> NormalizedType -> Normalizer NormalizedType
unionType left right = do
  unionedBaseType <- unionBaseType left.baseType right.baseType
  unionedAttribute <- unionAttribute left.attribute right.attribute
  pure $ NormalizedType {baseType = unionedBaseType, attribute = unionedAttribute}

unionBaseType :: NormalizedBaseType -> NormalizedBaseType -> Normalizer NormalizedBaseType
unionBaseType left right = case (left, right) of
  (NormalizedBaseTypeUnknown, _) -> pure NormalizedBaseTypeUnknown
  (_, NormalizedBaseTypeUnknown) -> pure NormalizedBaseTypeUnknown
  (NormalizedBaseTypeLayerd leftLayer, NormalizedBaseTypeLayerd rightLayer) -> do
    unionedLayer <- unionLayeredType leftLayer rightLayer
    pure $ NormalizedBaseTypeLayerd unionedLayer
  where
    unionLayeredType :: LayeredType -> LayeredType -> Normalizer LayeredType
    unionLayeredType leftLayered rightLayered = do
      unionedNumberLayer <- case (leftLayered.numberLayer, rightLayered.numberLayer) of
        (NumberSlotInteger, NumberSlotInteger) -> pure NumberSlotInteger
        (NumberSlotNumber, NumberSlotNumber) -> pure NumberSlotNumber
        (NumberSlotAbsent, other) -> pure other
        (other, NumberSlotAbsent) -> pure other
        (NumberSlotInteger, NumberSlotNumber) -> pure NumberSlotNumber
        (NumberSlotNumber, NumberSlotInteger) -> pure NumberSlotNumber
      unionedFunctionLayer <- case (leftLayered.functionLayer, rightLayered.functionLayer) of
        (FunctionSlotAbsent, other) -> pure other
        (other, FunctionSlotAbsent) -> pure other
        (FunctionSlotOf leftArgument leftReturnType leftEffect, FunctionSlotOf rightArgument rightReturnType rightEffect) -> do
          unionedArgument <- intersectType leftArgument rightArgument
          unionedReturnType <- unionType leftReturnType rightReturnType
          unionedEffect <- unionEffect leftEffect rightEffect
          pure $ FunctionSlotOf unionedArgument unionedReturnType unionedEffect
      unionedSequenceLayer <- unionSequenceLayer leftLayered.sequenceLayer rightLayered.sequenceLayer
      unionedObjectLayer <- unionObjectLayer leftLayered.objectLayer rightLayered.objectLayer
      unionedDataLayer <- unionWithKeyM unionDataLayerWithKey leftLayered.dataLayer rightLayered.dataLayer
      pure $
        LayeredType
          { nullLayer = leftLayered.nullLayer || rightLayered.nullLayer,
            numberLayer = unionedNumberLayer,
            stringLayer = leftLayered.stringLayer || rightLayered.stringLayer,
            booleanLayer = leftLayered.booleanLayer || rightLayered.booleanLayer,
            fileLayer = leftLayered.fileLayer || rightLayered.fileLayer,
            functionLayer = unionedFunctionLayer,
            sequenceLayer = unionedSequenceLayer,
            objectLayer = unionedObjectLayer,
            dataLayer = unionedDataLayer,
            genericLayer = Set.union leftLayered.genericLayer rightLayered.genericLayer
          }

    unionDataLayerWithKey :: QualifiedName -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer (Map Text NormalizedGenericArgument)
    unionDataLayerWithKey qualifiedName leftGenerics rightGenerics = do
      maybeDataInfo <- asks $ \environment -> Map.lookup qualifiedName environment.dataEnvironment
      case maybeDataInfo of
        Nothing -> do
          tell [UnknownDataError $ UnknownDataErrorInfo {expected = qualifiedName, message = "Unknown data: " <> pack (show qualifiedName)}]
          pure $ Map.union leftGenerics rightGenerics
        Just dataInfo -> unionWithKeyM (unionGenericArgumentWithVariance dataInfo.variance) leftGenerics rightGenerics

    unionSequenceLayer :: SequenceSlot -> SequenceSlot -> Normalizer SequenceSlot
    unionSequenceLayer leftSequence rightSequence = case (leftSequence, rightSequence) of
      -- NOTE: absent is the bottom of the sequence layer, so the union with anything is the other
      (SequenceSlotAbsent, other) -> pure other
      (other, SequenceSlotAbsent) -> pure other
      -- NOTE: a position only present on one side is unioned with the other side's `rest`
      -- Ex) [number, string] | [boolean] ~> [number | boolean, string | unknown] ~> [number | boolean, unknown]
      (SequenceSlotOf leftNormalizedSequence, SequenceSlotOf rightNormalizedSequence) ->
        SequenceSlotOf <$> mergeSequence unionType leftNormalizedSequence rightNormalizedSequence

    unionObjectLayer :: ObjectSlot -> ObjectSlot -> Normalizer ObjectSlot
    unionObjectLayer leftObject rightObject = case (leftObject, rightObject) of
      (ObjectSlotAbsent, other) -> pure other
      (other, ObjectSlotAbsent) -> pure other
      -- NOTE: all keys are kept; a field only present on one side is unioned with the other side's
      -- `rest` (usually unknown). A field is optional if it is optional on either side, and a
      -- one-sided field becomes optional because the other side's `rest` may be absent.
      -- Ex) {x: number, y: number} | {y: number, z: number} ~> {x?: unknown, y: number, z?: unknown}
      (ObjectSlotOf leftNormalizedObject, ObjectSlotOf rightNormalizedObject) ->
        ObjectSlotOf <$> mergeObject unionType (||) leftNormalizedObject rightNormalizedObject

-- | Union of attributes:
--   private, private -> private
--   private, public -> private :  Values with private or public attributes should be treated as private values.
--   public, public -> public
--   Generics -> Union of generics
unionAttribute :: NormalizedAttribute -> NormalizedAttribute -> Normalizer NormalizedAttribute
unionAttribute left right =
  pure $
    NormalizedAttribute
      { private = left.private || right.private,
        generic = Set.union left.generic right.generic
      }

unionEffect :: NormalizedEffect -> NormalizedEffect -> Normalizer NormalizedEffect
unionEffect left right = case (left, right) of
  (NormalizedEffectAny, _) -> pure NormalizedEffectAny
  (_, NormalizedEffectAny) -> pure NormalizedEffectAny
  (NormalizedEffectRow leftRow, NormalizedEffectRow rightRow) -> do
    unionedRequests <- unionWithKeyM unionGenericsWithKey leftRow.request rightRow.request
    pure $
      NormalizedEffectRow $
        EffectRow
          { request = unionedRequests,
            generic = Set.union leftRow.generic rightRow.generic,
            shadowed = Set.intersection leftRow.shadowed rightRow.shadowed -- NOTE: if either left or right has a request, the request is not shadowed
          }
  where
    -- \| Note : Variance
    --    Invaliant : cannot be unioned
    --    Covariant : union of generics
    --    Contravariant : intersection of generics
    --    Bivariant : union of generics
    --  Ex) req1[T, U] is covariant in T and contravariant in U  ~>  req1[int, string] | req1[string, number] ~> req1[int | string, string & number]
    unionGenericsWithKey :: QualifiedName -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer (Map Text NormalizedGenericArgument)
    unionGenericsWithKey requestQualifiedName leftGenerics rightGenerics = do
      maybeRequestInfo <- asks $ \environment -> Map.lookup requestQualifiedName environment.requestEnvironment
      case maybeRequestInfo of
        Nothing -> do
          tell [UnknownRequestError $ UnknownRequestErrorInfo {expected = requestQualifiedName, message = "Unknown request: " <> pack (show requestQualifiedName)}]
          pure $ Map.union leftGenerics rightGenerics
        Just requestInfo -> unionWithKeyM (unionGenericArgumentWithVariance requestInfo.variance) leftGenerics rightGenerics

unionGenericArgument :: NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
unionGenericArgument leftArgument rightArgument = case (leftArgument, rightArgument) of
  (NormalizedGenericArgumentType leftType, NormalizedGenericArgumentType rightType) -> do
    unionedType <- unionType leftType rightType
    pure $ NormalizedGenericArgumentType unionedType
  (NormalizedGenericArgumentEffect leftEffect, NormalizedGenericArgumentEffect rightEffect) -> do
    unionedEffect <- unionEffect leftEffect rightEffect
    pure $ NormalizedGenericArgumentEffect unionedEffect
  (NormalizedGenericArgumentAttribute leftAttribute, NormalizedGenericArgumentAttribute rightAttribute) -> do
    unionedAttribute <- unionAttribute leftAttribute rightAttribute
    pure $ NormalizedGenericArgumentAttribute unionedAttribute
  _ -> do
    tell [KindError $ KindErrorInfo {expected = kindOf leftArgument, actual = kindOf rightArgument, message = "Generic arguments with different kinds cannot be unioned"}]
    pure leftArgument -- NOTE: we can return either left or right argument because they are not unionable

unionGenericArgumentWithVariance :: Map Text Variance -> Text -> NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
unionGenericArgumentWithVariance variances genericArgumentName leftArgument rightArgument = do
  let maybeVariance = Map.lookup genericArgumentName variances
  case maybeVariance of
    Nothing -> do
      tell [UnknownGenericError $ UnknownGenericErrorInfo {expected = genericArgumentName, message = "Unknown generic argument: " <> genericArgumentName}]
      pure leftArgument -- NOTE: if the generic is not found in the variance map, we cannot determine how to union the generic arguments
    Just variance -> case variance of
      Invariant -> do
        if leftArgument == rightArgument
          then pure leftArgument
          else do
            tell [CannotBeUnionedError $ CannotBeUnionedErrorInfo {left = leftArgument, right = rightArgument, message = "Invariant generic arguments must be identical to be unioned"}]
            pure leftArgument -- NOTE: we can return either left or right argument because they are not unionable
      Covariant -> unionGenericArgument leftArgument rightArgument
      Contravariant -> intersectGenericArgument leftArgument rightArgument
      Bivariant -> unionGenericArgument leftArgument rightArgument

intersectType :: NormalizedType -> NormalizedType -> Normalizer NormalizedType
intersectType left right = do
  intersectedBaseType <- intersectBaseType left.baseType right.baseType
  intersectedAttribute <- intersectAttribute left.attribute right.attribute
  pure $ NormalizedType {baseType = intersectedBaseType, attribute = intersectedAttribute}

intersectBaseType :: NormalizedBaseType -> NormalizedBaseType -> Normalizer NormalizedBaseType
intersectBaseType left right = case (left, right) of
  -- NOTE: unknown base is the top of the base lattice, so meet(unknown, x) = x
  (NormalizedBaseTypeUnknown, other) -> pure other
  (other, NormalizedBaseTypeUnknown) -> pure other
  (NormalizedBaseTypeLayerd leftLayer, NormalizedBaseTypeLayerd rightLayer) -> do
    intersectedLayer <- intersectLayeredType leftLayer rightLayer
    pure $ NormalizedBaseTypeLayerd intersectedLayer
  where
    intersectLayeredType :: LayeredType -> LayeredType -> Normalizer LayeredType
    intersectLayeredType leftLayered rightLayered = do
      intersectedNumberLayer <- case (leftLayered.numberLayer, rightLayered.numberLayer) of
        -- NOTE: absent is the bottom of the number layer, so the meet with anything is absent
        (NumberSlotAbsent, _) -> pure NumberSlotAbsent
        (_, NumberSlotAbsent) -> pure NumberSlotAbsent
        (NumberSlotInteger, NumberSlotInteger) -> pure NumberSlotInteger
        (NumberSlotNumber, NumberSlotNumber) -> pure NumberSlotNumber
        -- NOTE: integer <: number, so the meet is the more specific integer
        (NumberSlotInteger, NumberSlotNumber) -> pure NumberSlotInteger
        (NumberSlotNumber, NumberSlotInteger) -> pure NumberSlotInteger
      intersectedFunctionLayer <- case (leftLayered.functionLayer, rightLayered.functionLayer) of
        -- NOTE: absent is the bottom of the function layer, so the meet with anything is absent
        (FunctionSlotAbsent, _) -> pure FunctionSlotAbsent
        (_, FunctionSlotAbsent) -> pure FunctionSlotAbsent
        (FunctionSlotOf leftArgument leftReturnType leftEffect, FunctionSlotOf rightArgument rightReturnType rightEffect) -> do
          -- NOTE: argument is contravariant, so the meet of functions unions the arguments
          intersectedArgument <- unionType leftArgument rightArgument
          intersectedReturnType <- intersectType leftReturnType rightReturnType
          intersectedEffect <- intersectEffect leftEffect rightEffect
          pure $ FunctionSlotOf intersectedArgument intersectedReturnType intersectedEffect
      intersectedSequenceLayer <- intersectSequenceLayer leftLayered.sequenceLayer rightLayered.sequenceLayer
      intersectedObjectLayer <- intersectObjectLayer leftLayered.objectLayer rightLayered.objectLayer
      intersectedDataLayer <- intersectWithKeyM intersectDataLayerWithKey leftLayered.dataLayer rightLayered.dataLayer
      pure $
        LayeredType
          { nullLayer = leftLayered.nullLayer && rightLayered.nullLayer,
            numberLayer = intersectedNumberLayer,
            stringLayer = leftLayered.stringLayer && rightLayered.stringLayer,
            booleanLayer = leftLayered.booleanLayer && rightLayered.booleanLayer,
            fileLayer = leftLayered.fileLayer && rightLayered.fileLayer,
            functionLayer = intersectedFunctionLayer,
            sequenceLayer = intersectedSequenceLayer,
            objectLayer = intersectedObjectLayer,
            dataLayer = intersectedDataLayer,
            -- NOTE: generics are intersected (only generics shared by both sides survive the meet)
            genericLayer = Set.intersection leftLayered.genericLayer rightLayered.genericLayer
          }

    -- NOTE: the outer data-layer keys are intersected (only nominal data types present in both
    -- sides survive the meet, since distinct nominal data types intersect to never), while the
    -- inner generic arguments are intersected per variance.
    intersectDataLayerWithKey :: QualifiedName -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer (Map Text NormalizedGenericArgument)
    intersectDataLayerWithKey qualifiedName leftGenerics rightGenerics = do
      maybeDataInfo <- asks $ \environment -> Map.lookup qualifiedName environment.dataEnvironment
      case maybeDataInfo of
        Nothing -> do
          tell [UnknownDataError $ UnknownDataErrorInfo {expected = qualifiedName, message = "Unknown data: " <> pack (show qualifiedName)}]
          pure $ Map.union leftGenerics rightGenerics
        Just dataInfo -> unionWithKeyM (intersectGenericArgumentWithVariance dataInfo.variance) leftGenerics rightGenerics

    intersectSequenceLayer :: SequenceSlot -> SequenceSlot -> Normalizer SequenceSlot
    intersectSequenceLayer leftSequence rightSequence = case (leftSequence, rightSequence) of
      -- NOTE: absent is the bottom of the sequence layer, so the meet with anything is absent
      (SequenceSlotAbsent, _) -> pure SequenceSlotAbsent
      (_, SequenceSlotAbsent) -> pure SequenceSlotAbsent
      -- NOTE: align to the longer length; a position only present on one side is intersected with
      -- the other side's `rest`.
      -- Ex) [number, string] & [boolean] ~> [number & boolean, string & unknown] ~> [number & boolean, string]
      (SequenceSlotOf leftNormalizedSequence, SequenceSlotOf rightNormalizedSequence) ->
        SequenceSlotOf <$> mergeSequence intersectType leftNormalizedSequence rightNormalizedSequence

    intersectObjectLayer :: ObjectSlot -> ObjectSlot -> Normalizer ObjectSlot
    intersectObjectLayer leftObject rightObject = case (leftObject, rightObject) of
      -- NOTE: absent is the bottom of the object layer, so the meet with anything is absent
      (ObjectSlotAbsent, _) -> pure ObjectSlotAbsent
      (_, ObjectSlotAbsent) -> pure ObjectSlotAbsent
      -- NOTE: all keys are kept; a field only present on one side is intersected with the other
      -- side's `rest`. A field is optional only if optional on both sides, and a one-sided field
      -- keeps its own optionality (the other side's `rest` is treated as optional).
      -- Ex) {x: number} & {y: number} ~> {x: number, y: number}
      (ObjectSlotOf leftNormalizedObject, ObjectSlotOf rightNormalizedObject) ->
        ObjectSlotOf <$> mergeObject intersectType (&&) leftNormalizedObject rightNormalizedObject

intersectEffect :: NormalizedEffect -> NormalizedEffect -> Normalizer NormalizedEffect
intersectEffect left right = case (left, right) of
  -- NOTE: Any is the top effect, so meet(Any, x) = x
  (NormalizedEffectAny, other) -> pure other
  (other, NormalizedEffectAny) -> pure other
  (NormalizedEffectRow leftRow, NormalizedEffectRow rightRow) -> do
    -- NOTE: requests are intersected (only requests present in both sides survive the meet)
    intersectedRequests <- intersectWithKeyM intersectGenericsWithKey leftRow.request rightRow.request
    pure $
      NormalizedEffectRow $
        EffectRow
          { request = intersectedRequests,
            -- NOTE: generics are intersected (only generics shared by both sides survive the meet)
            generic = Set.intersection leftRow.generic rightRow.generic,
            -- NOTE: dual of union (which intersects shadowed): a request is shadowed in the meet if shadowed in either side
            shadowed = Set.union leftRow.shadowed rightRow.shadowed
          }
  where
    -- \| Note : Variance
    --    Invariant : cannot be intersected
    --    Covariant : intersection of generics
    --    Contravariant : union of generics
    --    Bivariant : intersection of generics
    --  Ex) req1[T, U] is covariant in T and contravariant in U  ~>  req1[int, string] & req1[string, number] ~> req1[int & string, string | number]
    intersectGenericsWithKey :: QualifiedName -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer (Map Text NormalizedGenericArgument)
    intersectGenericsWithKey requestQualifiedName leftGenerics rightGenerics = do
      maybeRequestInfo <- asks $ \environment -> Map.lookup requestQualifiedName environment.requestEnvironment
      case maybeRequestInfo of
        Nothing -> do
          tell [UnknownRequestError $ UnknownRequestErrorInfo {expected = requestQualifiedName, message = "Unknown request: " <> pack (show requestQualifiedName)}]
          pure $ Map.union leftGenerics rightGenerics
        Just requestInfo -> unionWithKeyM (intersectGenericArgumentWithVariance requestInfo.variance) leftGenerics rightGenerics

-- | Intersection of attributes:
--   private, private -> private
--   private, public -> public :  Ex) agent (x : number of private) -> r | agent (x : number of public) -> r  ~>  argument x must be public.
--   public, public -> public
intersectAttribute :: NormalizedAttribute -> NormalizedAttribute -> Normalizer NormalizedAttribute
intersectAttribute left right =
  pure $
    NormalizedAttribute
      { private = left.private && right.private,
        generic = Set.intersection left.generic right.generic
      }

intersectGenericArgument :: NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
intersectGenericArgument leftArgument rightArgument = case (leftArgument, rightArgument) of
  (NormalizedGenericArgumentType leftType, NormalizedGenericArgumentType rightType) -> do
    intersectedType <- intersectType leftType rightType
    pure $ NormalizedGenericArgumentType intersectedType
  (NormalizedGenericArgumentEffect leftEffect, NormalizedGenericArgumentEffect rightEffect) -> do
    intersectedEffect <- intersectEffect leftEffect rightEffect
    pure $ NormalizedGenericArgumentEffect intersectedEffect
  (NormalizedGenericArgumentAttribute leftAttribute, NormalizedGenericArgumentAttribute rightAttribute) -> do
    intersectedAttribute <- intersectAttribute leftAttribute rightAttribute
    pure $ NormalizedGenericArgumentAttribute intersectedAttribute
  _ -> do
    tell [KindError $ KindErrorInfo {expected = kindOf leftArgument, actual = kindOf rightArgument, message = "Generic arguments with different kinds cannot be intersected"}]
    pure leftArgument -- NOTE: we can return either left or right argument because they are not intersectable

intersectGenericArgumentWithVariance :: Map Text Variance -> Text -> NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
intersectGenericArgumentWithVariance variances genericArgumentName leftArgument rightArgument = do
  let maybeVariance = Map.lookup genericArgumentName variances
  case maybeVariance of
    Nothing -> do
      tell [UnknownGenericError $ UnknownGenericErrorInfo {expected = genericArgumentName, message = "Unknown generic argument: " <> genericArgumentName}]
      pure leftArgument
    Just variance -> case variance of
      Invariant -> do
        if leftArgument == rightArgument
          then pure leftArgument
          else do
            tell [CannotBeIntersectedError $ CannotBeIntersectedErrorInfo {left = leftArgument, right = rightArgument, message = "Invariant generic arguments must be identical to be intersected"}]
            pure leftArgument -- NOTE: we can return either left or right argument because they are not intersectable
      Covariant -> intersectGenericArgument leftArgument rightArgument
      Contravariant -> unionGenericArgument leftArgument rightArgument
      Bivariant -> intersectGenericArgument leftArgument rightArgument

-- |
--   union        (combineType = unionType,     combineOptional = ||): leftover = field | other.rest, optional = True
--   intersection (combineType = intersectType, combineOptional = &&): leftover = field & other.rest, optional = present side's optional
mergeObject ::
  (NormalizedType -> NormalizedType -> Normalizer NormalizedType) ->
  (Bool -> Bool -> Bool) ->
  NormalizedObject ->
  NormalizedObject ->
  Normalizer NormalizedObject
mergeObject combineType combineOptional leftObject rightObject = do
  let keys = Set.union (Map.keysSet leftObject.fields) (Map.keysSet rightObject.fields)
  mergedFields <-
    Map.fromList
      <$> mapM
        ( \key -> do
            let leftField = effectiveField leftObject.rest $ Map.lookup key leftObject.fields
                rightField = effectiveField rightObject.rest $ Map.lookup key rightObject.fields
            mergedFieldType <- combineType leftField.normalizedType rightField.normalizedType
            pure (key, NormalizedFieldInformation {normalizedType = mergedFieldType, optional = combineOptional leftField.optional rightField.optional})
        )
        (Set.toList keys)
  mergedRest <- combineType leftObject.rest rightObject.rest
  pure $ NormalizedObject {fields = mergedFields, rest = mergedRest}
  where
    -- NOTE: Rest   ~>   optional = true
    effectiveField :: NormalizedType -> Maybe NormalizedFieldInformation -> NormalizedFieldInformation
    effectiveField objectRest = \case
      Just fieldInformation -> fieldInformation
      Nothing -> NormalizedFieldInformation {normalizedType = objectRest, optional = True}

-- | leftover ~> field | other.rest (for union) or field & other.rest (for intersection)
mergeSequence ::
  (NormalizedType -> NormalizedType -> Normalizer NormalizedType) ->
  NormalizedSequence ->
  NormalizedSequence ->
  Normalizer NormalizedSequence
mergeSequence combineType leftSequence rightSequence = do
  let maxLength = max (length leftSequence.items) (length rightSequence.items)
  mergedItems <-
    mapM
      ( \index -> do
          let leftItem = effectiveItem leftSequence.rest (leftSequence.items `atMay` index)
              rightItem = effectiveItem rightSequence.rest (rightSequence.items `atMay` index)
          combineType leftItem rightItem
      )
      [0 .. maxLength - 1]
  mergedRest <- combineType leftSequence.rest rightSequence.rest
  pure $ NormalizedSequence {items = mergedItems, rest = mergedRest}
  where
    -- NOTE: Rest   ~>   unknown
    effectiveItem :: NormalizedType -> Maybe NormalizedType -> NormalizedType
    effectiveItem sequenceRest = \case
      Just itemType -> itemType
      Nothing -> sequenceRest

-- | Check if the first type is a subtype of the second type. (first <: second)
-- NOTE: Attribute
-- public <: private, private /<: public
-- Attribute distribution rule:
--   private {x : number of public} <: public {x : number of private} -- OK
subtypeType ::
  NormalizedType ->
  NormalizedType ->
  Normalizer ()
subtypeType left right = do
  subtypeBaseType left.baseType right.baseType
  subtypeAttribute left.attribute right.attribute

subtypeAttribute :: NormalizedAttribute -> NormalizedAttribute -> Normalizer ()
subtypeAttribute left right = do
  -- 1. Collect generic bounds of left only generics, and union them to rest of left attribute
  -- 2. Compare non-generic parts
  genricBoundsEnvironment <- asks $ \environment -> environment.genericBoundEnvironment
  let leftOnlyGenerics = Set.difference left.generic right.generic
  leftOnlyGenericBounds <-
    mapMaybeM
      ( \case
          NormalizedGenericArgumentAttribute attribute -> pure $ Just attribute
          NormalizedGenericArgumentType argumentType -> do
            tell [KindError $ KindErrorInfo {expected = "attribute", actual = "type", message = "Expected an attribute, but got a type: " <> pack (show argumentType)}]
            pure Nothing
          NormalizedGenericArgumentEffect argumentEffect -> do
            tell [KindError $ KindErrorInfo {expected = "attribute", actual = "effect", message = "Expected an attribute, but got an effect: " <> pack (show argumentEffect)}]
            pure Nothing
      )
      $ Map.restrictKeys genricBoundsEnvironment leftOnlyGenerics
  effectiveLeftAttribute <- foldM unionAttribute left $ Map.elems leftOnlyGenericBounds
  when (effectiveLeftAttribute.private && not right.private) $
    tell
      [ SubtypeError $
          SubtypeErrorInfo
            { expected = NormalizedGenericArgumentAttribute $ NormalizedAttribute {private = False, generic = Set.empty},
              actual = NormalizedGenericArgumentAttribute $ NormalizedAttribute {private = True, generic = Set.empty},
              message = "Private attribute cannot be a subtype of public attribute"
            }
      ]

subtypeBaseType :: NormalizedBaseType -> NormalizedBaseType -> Normalizer ()
subtypeBaseType left right = case (left, right) of
  (NormalizedBaseTypeUnknown, NormalizedBaseTypeUnknown) -> pure ()
  (NormalizedBaseTypeUnknown, expected) ->
    tell
      [ SubtypeError $
          SubtypeErrorInfo
            { expected = NormalizedGenericArgumentType $ NormalizedType {baseType = expected, attribute = bottomAttribute},
              actual = NormalizedGenericArgumentType $ NormalizedType {baseType = left, attribute = bottomAttribute},
              message = "Unknown type cannot be a subtype of a known type"
            }
      ]
  (_, NormalizedBaseTypeUnknown) -> pure ()
  (NormalizedBaseTypeLayerd leftLayer, NormalizedBaseTypeLayerd rightLayer) -> subtypeLayeredType leftLayer rightLayer

subtypeLayeredType :: LayeredType -> LayeredType -> Normalizer ()
subtypeLayeredType leftLayered rightLayered = do
  let tellLayeredTypeError message =
        tell
          [ SubtypeError $
              SubtypeErrorInfo
                { expected = NormalizedGenericArgumentType $ NormalizedType {baseType = NormalizedBaseTypeLayerd rightLayered, attribute = bottomAttribute},
                  actual = NormalizedGenericArgumentType $ NormalizedType {baseType = NormalizedBaseTypeLayerd leftLayered, attribute = bottomAttribute},
                  message = message
                }
          ]
  -- Resolve the generic layer the same way as 'subtypeAttribute': take the upper bound of every
  -- generic that occurs only on the left (common generics cancel; nested generics introduced by the
  -- bounds are not resolved further), union those bounds into the left type, and then compare only
  -- the non-generic layers.
  genericBoundEnvironmentValue <- asks (\environment -> environment.genericBoundEnvironment)
  let leftOnlyGenerics = Set.difference leftLayered.genericLayer rightLayered.genericLayer
  leftOnlyGenericBoundTypes <-
    mapMaybeM
      ( \case
          NormalizedGenericArgumentType boundType -> pure (Just boundType)
          NormalizedGenericArgumentEffect boundEffect -> do
            tell [KindError $ KindErrorInfo {expected = "type", actual = "effect", message = "Expected a type bound, but got an effect: " <> pack (show boundEffect)}]
            pure Nothing
          NormalizedGenericArgumentAttribute boundAttribute -> do
            tell [KindError $ KindErrorInfo {expected = "type", actual = "attribute", message = "Expected a type bound, but got an attribute: " <> pack (show boundAttribute)}]
            pure Nothing
      )
      (Map.restrictKeys genericBoundEnvironmentValue leftOnlyGenerics)
  effectiveLeftBaseType <- foldM unionBaseType (NormalizedBaseTypeLayerd leftLayered) (map (\boundType -> boundType.baseType) (Map.elems leftOnlyGenericBoundTypes))
  case effectiveLeftBaseType of
    -- A left-only generic has no usable upper bound, so the effective left type is unknown (top)
    -- and cannot be a subtype of a known layered type.
    NormalizedBaseTypeUnknown -> tellLayeredTypeError "A left-only generic is unbounded, so the left type is effectively unknown"
    NormalizedBaseTypeLayerd effectiveLeftLayered -> do
      case (effectiveLeftLayered.numberLayer, rightLayered.numberLayer) of
        (NumberSlotInteger, NumberSlotInteger) -> pure ()
        (NumberSlotNumber, NumberSlotNumber) -> pure ()
        (NumberSlotAbsent, NumberSlotAbsent) -> pure ()
        (NumberSlotInteger, NumberSlotNumber) -> pure () -- integer <: number
        (NumberSlotAbsent, NumberSlotInteger) -> pure () -- absent <: integer
        (NumberSlotAbsent, NumberSlotNumber) -> pure () -- absent <: number
        _ -> tellLayeredTypeError "Number layers are incompatible"
      case (effectiveLeftLayered.stringLayer, rightLayered.stringLayer) of
        (False, False) -> pure ()
        (True, True) -> pure ()
        (False, True) -> pure () -- absent <: string
        _ -> tellLayeredTypeError "String layers are incompatible"
      case (effectiveLeftLayered.booleanLayer, rightLayered.booleanLayer) of
        (False, False) -> pure ()
        (True, True) -> pure ()
        (False, True) -> pure () -- absent <: boolean
        _ -> tellLayeredTypeError "Boolean layers are incompatible"
      case (effectiveLeftLayered.fileLayer, rightLayered.fileLayer) of
        (False, False) -> pure ()
        (True, True) -> pure ()
        (False, True) -> pure () -- absent <: file
        _ -> tellLayeredTypeError "File layers are incompatible"
      case (effectiveLeftLayered.functionLayer, rightLayered.functionLayer) of
        (FunctionSlotAbsent, FunctionSlotAbsent) -> pure ()
        (FunctionSlotOf leftArgument leftReturnType leftEffect, FunctionSlotOf rightArgument rightReturnType rightEffect) -> do
          subtypeType rightArgument leftArgument -- NOTE: function argument is contravariant
          subtypeType leftReturnType rightReturnType
          subtypeEffect leftEffect rightEffect
        (FunctionSlotAbsent, FunctionSlotOf {}) -> pure () -- absent <: function
        _ -> tellLayeredTypeError "Function layers are incompatible"
      case (effectiveLeftLayered.sequenceLayer, rightLayered.sequenceLayer) of
        (SequenceSlotAbsent, SequenceSlotAbsent) -> pure ()
        (SequenceSlotAbsent, SequenceSlotOf _) -> pure () -- absent <: sequence
        (SequenceSlotOf leftSequence, SequenceSlotOf rightSequence) -> subtypeSequence leftSequence rightSequence
        _ -> tellLayeredTypeError "Sequence layers are incompatible"
      case (effectiveLeftLayered.objectLayer, rightLayered.objectLayer) of
        (ObjectSlotAbsent, ObjectSlotAbsent) -> pure ()
        (ObjectSlotAbsent, ObjectSlotOf _) -> pure () -- absent <: object
        (ObjectSlotOf leftObject, ObjectSlotOf rightObject) -> subtypeObject leftObject rightObject
        _ -> tellLayeredTypeError "Object layers are incompatible"
      -- NOTE: the data layer is a union of nominal types; every nominal type on the left must also
      -- appear on the right, and its generic arguments are compared by the declared variance.
      dataEnvironmentValue <- asks (\environment -> environment.dataEnvironment)
      mapM_
        ( \(qualifiedName, leftArguments) ->
            case Map.lookup qualifiedName rightLayered.dataLayer of
              Nothing -> tellLayeredTypeError $ "Data type is not present in the supertype: " <> renderQualifiedName qualifiedName
              Just rightArguments ->
                case Map.lookup qualifiedName dataEnvironmentValue of
                  Nothing -> tell [UnknownDataError $ UnknownDataErrorInfo {expected = qualifiedName, message = "Unknown data: " <> pack (show qualifiedName)}]
                  Just dataInfo -> subtypeGenericArguments dataInfo.variance leftArguments rightArguments
        )
        (Map.toList effectiveLeftLayered.dataLayer)

subtypeEffect :: NormalizedEffect -> NormalizedEffect -> Normalizer ()
subtypeEffect left right = case (left, right) of
  (NormalizedEffectAny, NormalizedEffectAny) -> pure ()
  (NormalizedEffectAny, NormalizedEffectRow rightRow) ->
    tell
      [ SubtypeError $
          SubtypeErrorInfo
            { expected = NormalizedGenericArgumentEffect $ NormalizedEffectRow rightRow,
              actual = NormalizedGenericArgumentEffect NormalizedEffectAny,
              message = "Any effect cannot be a subtype of a known effect"
            }
      ]
  (NormalizedEffectRow _, NormalizedEffectAny) -> pure ()
  (NormalizedEffectRow leftRow, NormalizedEffectRow rightRow) -> do
    -- NOTE: requests are covariant; every request the left effect performs must also be present in the right effect
    let tellEffectRowError message =
          tell
            [ SubtypeError $
                SubtypeErrorInfo
                  { expected = NormalizedGenericArgumentEffect $ NormalizedEffectRow rightRow,
                    actual = NormalizedGenericArgumentEffect $ NormalizedEffectRow leftRow,
                    message = message
                  }
            ]
    requestEnvironmentValue <- asks (\environment -> environment.requestEnvironment)
    mapM_
      ( \(requestQualifiedName, leftArguments) ->
          case Map.lookup requestQualifiedName rightRow.request of
            Nothing -> tellEffectRowError $ "Left effect performs a request not present in the right effect: " <> renderQualifiedName requestQualifiedName
            Just rightArguments ->
              case Map.lookup requestQualifiedName requestEnvironmentValue of
                Nothing -> tell [UnknownRequestError $ UnknownRequestErrorInfo {expected = requestQualifiedName, message = "Unknown request: " <> pack (show requestQualifiedName)}]
                Just requestInfo -> subtypeGenericArguments requestInfo.variance leftArguments rightArguments
      )
      (Map.toList leftRow.request)
    -- NOTE: generics are covariant
    if leftRow.generic `Set.isSubsetOf` rightRow.generic
      then pure ()
      else tellEffectRowError "Effect generics are incompatible"
    -- NOTE: shadowing is contravariant, so the left's shadowed set must be a superset of the right's shadowed set
    if rightRow.shadowed `Set.isSubsetOf` leftRow.shadowed
      then pure ()
      else tellEffectRowError "Effect shadowed requests are incompatible"

-- | Sequences are covariant: every position's element type must be a subtype, including the tail
-- (rest). A position present on only one side is compared against the other side's rest.
subtypeSequence :: NormalizedSequence -> NormalizedSequence -> Normalizer ()
subtypeSequence leftSequence rightSequence = do
  let maximumLength = max (length leftSequence.items) (length rightSequence.items)
  mapM_
    ( \index ->
        subtypeType
          (effectiveItem leftSequence.rest (leftSequence.items `atMay` index))
          (effectiveItem rightSequence.rest (rightSequence.items `atMay` index))
    )
    [0 .. maximumLength - 1]
  subtypeType leftSequence.rest rightSequence.rest
  where
    effectiveItem :: NormalizedType -> Maybe NormalizedType -> NormalizedType
    effectiveItem = Data.Maybe.fromMaybe

-- | Object field types are covariant. A field present on only one side is compared against the
-- other side's rest (treated as optional). A required field on the right must be required on the
-- left, otherwise the left value may omit a field the right guarantees.
subtypeObject :: NormalizedObject -> NormalizedObject -> Normalizer ()
subtypeObject leftObject rightObject = do
  let fieldNames = Set.union (Map.keysSet leftObject.fields) (Map.keysSet rightObject.fields)
  mapM_
    ( \fieldName -> do
        let leftField = effectiveField leftObject.rest (Map.lookup fieldName leftObject.fields)
            rightField = effectiveField rightObject.rest (Map.lookup fieldName rightObject.fields)
        subtypeType leftField.normalizedType rightField.normalizedType
        case (leftField.optional, rightField.optional) of
          (True, False) ->
            tell
              [ SubtypeError $
                  SubtypeErrorInfo
                    { expected = NormalizedGenericArgumentType rightField.normalizedType,
                      actual = NormalizedGenericArgumentType leftField.normalizedType,
                      message = "Optional field cannot be a subtype of a required field: " <> fieldName
                    }
              ]
          _ -> pure ()
    )
    (Set.toList fieldNames)
  subtypeType leftObject.rest rightObject.rest
  where
    effectiveField :: NormalizedType -> Maybe NormalizedFieldInformation -> NormalizedFieldInformation
    effectiveField objectRest =
      fromMaybe
        NormalizedFieldInformation
          { normalizedType = objectRest,
            optional = True
          }

-- | Compare two generic-argument maps (of a data type or request) pointwise, using the declared
-- variance of each parameter.
subtypeGenericArguments :: Map Text Variance -> Map Text NormalizedGenericArgument -> Map Text NormalizedGenericArgument -> Normalizer ()
subtypeGenericArguments varianceMap leftArguments rightArguments =
  mapM_
    ( \genericArgumentName ->
        case (Map.lookup genericArgumentName leftArguments, Map.lookup genericArgumentName rightArguments) of
          (Just leftArgument, Just rightArgument) -> subtypeGenericArgument varianceMap genericArgumentName leftArgument rightArgument
          _ -> pure ()
    )
    (Set.toList $ Set.union (Map.keysSet leftArguments) (Map.keysSet rightArguments))

-- | Compare a single generic argument by its variance, mirroring the dispatch used by
-- 'unionGenericArgument' / 'intersectGenericArgument':
--   covariant     -> left <: right
--   contravariant -> right <: left
--   invariant     -> both directions
--   bivariant     -> no constraint
subtypeGenericArgument :: Map Text Variance -> Text -> NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer ()
subtypeGenericArgument varianceMap genericArgumentName leftArgument rightArgument =
  case Map.lookup genericArgumentName varianceMap of
    Nothing ->
      tell [UnknownGenericError $ UnknownGenericErrorInfo {expected = genericArgumentName, message = "Unknown generic argument: " <> genericArgumentName}]
    Just variance -> case variance of
      Covariant -> subtypeCovariantArgument leftArgument rightArgument
      Contravariant -> subtypeCovariantArgument rightArgument leftArgument
      Invariant -> do
        subtypeCovariantArgument leftArgument rightArgument
        subtypeCovariantArgument rightArgument leftArgument
      Bivariant -> pure ()
  where
    subtypeCovariantArgument :: NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer ()
    subtypeCovariantArgument lowerArgument upperArgument = case (lowerArgument, upperArgument) of
      (NormalizedGenericArgumentType lowerType, NormalizedGenericArgumentType upperType) -> subtypeType lowerType upperType
      (NormalizedGenericArgumentEffect lowerEffect, NormalizedGenericArgumentEffect upperEffect) -> subtypeEffect lowerEffect upperEffect
      (NormalizedGenericArgumentAttribute lowerAttribute, NormalizedGenericArgumentAttribute upperAttribute) -> subtypeAttribute lowerAttribute upperAttribute
      _ ->
        tell
          [ KindError $
              KindErrorInfo
                { expected = genericArgumentKindName upperArgument,
                  actual = genericArgumentKindName lowerArgument,
                  message = "Generic argument kinds are incompatible: " <> genericArgumentName
                }
          ]
    genericArgumentKindName :: NormalizedGenericArgument -> Text
    genericArgumentKindName argument = case argument of
      NormalizedGenericArgumentType _ -> "type"
      NormalizedGenericArgumentEffect _ -> "effect"
      NormalizedGenericArgumentAttribute _ -> "attribute"
