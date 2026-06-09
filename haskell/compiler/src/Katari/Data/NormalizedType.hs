module Katari.Data.NormalizedType where

import Control.Monad (foldM, (<=<))
import Control.Monad.RWS (RWS)
import Control.Monad.RWS.Class (MonadReader (..), MonadState (..), MonadWriter (..), asks)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text, pack)
import GHC.List (List)
import Katari.Data.Environment (DataEnvironment, GenericBoundEnvironment, RequestEnvironment (..), variance)
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
  deriving (Eq, Ord, Show)

data SubtypeErrorInfo where
  SubtypeErrorInfo ::
    { expected :: NormalizedType,
      actual :: NormalizedType,
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
    { expected :: GenericId,
      message :: Text
    } ->
    UnknownGenericErrorInfo
  deriving (Eq, Ord, Show)

data CannotBeUnionedErrorInfo where
  CannotBeUnionedErrorInfo ::
    { left :: NormalizedType,
      right :: NormalizedType,
      message :: Text
    } ->
    CannotBeUnionedErrorInfo
  deriving (Eq, Ord, Show)

data CannotBeIntersectedErrorInfo where
  CannotBeIntersectedErrorInfo ::
    { left :: NormalizedType,
      right :: NormalizedType,
      message :: Text
    } ->
    CannotBeIntersectedErrorInfo
  deriving (Eq, Ord, Show)

data NormalizerEnvironment = NormalizeEnvironment
  { dataEnvironment :: DataEnvironment NormalizedBaseType,
    requestEnvironment :: RequestEnvironment NormalizedBaseType,
    genericBoundEnvironment :: GenericBoundEnvironment NormalizedGenericArgument
  }
  deriving (Eq, Show)

type Normalizer a = RWS NormalizerEnvironment (List SubtypeError) () a

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
        Just dataInfo -> unionWithKeyM (unionGenericArgument dataInfo.variance) leftGenerics rightGenerics

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
        Just requestInfo -> unionWithKeyM (unionGenericArgument requestInfo.variance) leftGenerics rightGenerics

unionGenericArgument :: Map Text Variance -> Text -> NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
unionGenericArgument varianceMap genericArgumentName leftArgument rightArgument =
  case Map.lookup genericArgumentName varianceMap of
    Nothing -> do
      tell [SubtypeError $ SubtypeErrorInfo {expected = bottomType, actual = topType, message = "Unknown generic: " <> genericArgumentName}]
      pure leftArgument -- NOTE: if the generic is not found in the variance map, we cannot determine how to union the generic arguments
    Just variance -> case variance of
      Invariant -> do
        if leftArgument == rightArgument
          then pure leftArgument
          else do
            tell [CannotBeUnionedError $ CannotBeUnionedErrorInfo {left = bottomType, right = topType, message = "Invariant generic argument cannot be unioned: " <> genericArgumentName}]
            pure leftArgument -- NOTE: we can return either left or right argument because they are not unionable
      Covariant -> case (leftArgument, rightArgument) of
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
          tell [CannotBeUnionedError $ CannotBeUnionedErrorInfo {left = bottomType, right = topType, message = "Covariant generic argument with different kinds cannot be unioned: " <> genericArgumentName}]
          pure leftArgument -- NOTE: we can return either left or right argument because they are not unionable
      Contravariant -> case (leftArgument, rightArgument) of
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
          tell [CannotBeUnionedError $ CannotBeUnionedErrorInfo {left = bottomType, right = topType, message = "Contravariant generic argument with different kinds cannot be unioned: " <> genericArgumentName}]
          pure leftArgument -- NOTE: we can return either left or right argument because they are not unionable
      Bivariant -> case (leftArgument, rightArgument) of
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
          tell [CannotBeUnionedError $ CannotBeUnionedErrorInfo {left = bottomType, right = topType, message = "Bivariant generic argument with different kinds cannot be unioned: " <> genericArgumentName}]
          pure leftArgument -- NOTE: we can return either left or right argument because they are not unionable

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
        Just dataInfo -> unionWithKeyM (intersectGenericArgument dataInfo.variance) leftGenerics rightGenerics

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
        Just requestInfo -> unionWithKeyM (intersectGenericArgument requestInfo.variance) leftGenerics rightGenerics

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

intersectGenericArgument :: Map Text Variance -> Text -> NormalizedGenericArgument -> NormalizedGenericArgument -> Normalizer NormalizedGenericArgument
intersectGenericArgument varianceMap genericArgumentName leftArgument rightArgument =
  case Map.lookup genericArgumentName varianceMap of
    Nothing -> do
      tell [SubtypeError $ SubtypeErrorInfo {expected = bottomType, actual = topType, message = "Unknown generic: " <> genericArgumentName}]
      pure leftArgument -- NOTE: if the generic is not found in the variance map, we cannot determine how to intersect the generic arguments
    Just variance -> case variance of
      Invariant ->
        if leftArgument == rightArgument
          then pure leftArgument
          else do
            tell [CannotBeIntersectedError $ CannotBeIntersectedErrorInfo {left = bottomType, right = topType, message = "Invariant generic argument cannot be intersected: " <> genericArgumentName}]
            pure leftArgument -- NOTE: we can return either left or right argument because they are not intersectable
      Covariant -> case (leftArgument, rightArgument) of
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
          tell [CannotBeIntersectedError $ CannotBeIntersectedErrorInfo {left = bottomType, right = topType, message = "Covariant generic argument with different kinds cannot be intersected: " <> genericArgumentName}]
          pure leftArgument -- NOTE: we can return either left or right argument because they are not intersectable
      Contravariant -> case (leftArgument, rightArgument) of
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
          tell [CannotBeIntersectedError $ CannotBeIntersectedErrorInfo {left = bottomType, right = topType, message = "Contravariant generic argument with different kinds cannot be intersected: " <> genericArgumentName}]
          pure leftArgument -- NOTE: we can return either left or right argument because they are not intersectable
      Bivariant -> case (leftArgument, rightArgument) of
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
          tell [CannotBeIntersectedError $ CannotBeIntersectedErrorInfo {left = bottomType, right = topType, message = "Bivariant generic argument with different kinds cannot be intersected: " <> genericArgumentName}]
          pure leftArgument -- NOTE: we can return either left or right argument because they are not intersectable

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

-- \| right only or left only  ~>  keep
-- \| left and right  ~>  apply f
unionWithKeyM :: (Ord k, Monad m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
unionWithKeyM f leftMap rightMap = do
  let keys = Set.union (Map.keysSet leftMap) (Map.keysSet rightMap)
  Map.fromList . catMaybes
    <$> mapM
      ( \key -> case (Map.lookup key leftMap, Map.lookup key rightMap) of
          (Just leftValue, Just rightValue) -> do
            unionedValue <- f key leftValue rightValue
            pure $ Just (key, unionedValue)
          (Just leftValue, Nothing) -> pure $ Just (key, leftValue)
          (Nothing, Just rightValue) -> pure $ Just (key, rightValue)
          (Nothing, Nothing) -> pure Nothing
      )
      (Set.toList keys)

intersectWithKeyM :: (Ord k, Monad m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
intersectWithKeyM f leftMap rightMap = do
  let keys = Set.intersection (Map.keysSet leftMap) (Map.keysSet rightMap)
  Map.fromList . catMaybes
    <$> mapM
      ( \key -> case (Map.lookup key leftMap, Map.lookup key rightMap) of
          (Just leftValue, Just rightValue) -> do
            intersectedValue <- f key leftValue rightValue
            pure $ Just (key, intersectedValue)
          _ -> pure Nothing
      )
      (Set.toList keys)

-- | Check if the first type is a subtype of the second type. (first <: second)
-- NOTE: Attribute
-- private <: public, public /<: private
-- Attribute distribution rule:
--   private {x : number of public} <: public {x : number of private} -- OK
subtypeType ::
  NormalizedType ->
  NormalizedType ->
  Normalizer Bool
subtypeType left right = do
  isBaseSubtype <- subtypeBaseType left.baseType right.baseType
  isAttributeSubtype <- subtypeAttribute left.attribute right.attribute
  pure $ isBaseSubtype && isAttributeSubtype

subtypeAttribute :: NormalizedAttribute -> NormalizedAttribute -> Normalizer Bool
subtypeAttribute left right = do
  -- 1. Collect generic bounds of left only generics, and union them to rest of left attribute
  -- 2. Compare non-generic parts
  genricBoundsEnvironment <- asks $ \environment -> environment.genericBoundEnvironment
  let leftOnlyGenerics = Set.difference left.generic right.generic
      leftOnlyGenericBounds =
        Map.mapMaybe
          ( \case
              NormalizedGenericArgumentAttribute attribute -> Just attribute
              _ -> Nothing
          )
          $ Map.restrictKeys genricBoundsEnvironment leftOnlyGenerics
  effectiveLeftAttribute <- foldM unionAttribute left $ Map.elems leftOnlyGenericBounds
  pure $ not effectiveLeftAttribute.private || right.private -- NOTE: public <: private, private /<: public

subtypeBaseType :: NormalizedBaseType -> NormalizedBaseType -> Normalizer Bool
subtypeBaseType left right = case (left, right) of
  (NormalizedBaseTypeUnknown, NormalizedBaseTypeUnknown) -> pure True
  (NormalizedBaseTypeUnknown, _) -> pure False
  (_, NormalizedBaseTypeUnknown) -> pure True
  (NormalizedBaseTypeLayerd leftLayer, NormalizedBaseTypeLayerd rightLayer) -> subtypeLayeredType leftLayer rightLayer

subtypeLayeredType :: LayeredType -> LayeredType -> Normalizer Bool
subtypeLayeredType leftLayered rightLayered = undefined
