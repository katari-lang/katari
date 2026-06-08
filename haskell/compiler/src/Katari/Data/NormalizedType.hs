module Katari.Data.NormalizedTypeBase where

import Control.Monad (foldM, zipWithM, (<=<))
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

-- | NOTE: Bottom & Top types
-- Bottom ... never of public
-- Top ... unknown of private  <--  unknown of public is not top
data NormalizedType where
  NormalizedType :: {baseType :: NormalizedTypeBase, attribute :: NormalizedAttribute} -> NormalizedType
  deriving (Eq, Ord, Show)

data NormalizedTypeBase where
  NormalizedTypeBaseUnknown :: NormalizedTypeBase
  NormalizedTypeBaseLayerd :: LayeredType -> NormalizedTypeBase
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
  SequenceSlotTuple :: List NormalizedType -> SequenceSlot
  SequenceSlotArray :: NormalizedType -> SequenceSlot
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
  { dataEnvironment :: DataEnvironment NormalizedTypeBase,
    requestEnvironment :: RequestEnvironment NormalizedTypeBase,
    genericBoundEnvironment :: GenericBoundEnvironment NormalizedTypeBase
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
bottomType = NormalizedType {baseType = NormalizedTypeBaseLayerd neverLayer, attribute = bottomAttribute}

bottomAttribute :: NormalizedAttribute
bottomAttribute = NormalizedAttribute {private = False, generic = Set.empty}

bottomEffect :: NormalizedEffect
bottomEffect = NormalizedEffectRow $ EffectRow {request = mempty, generic = mempty, shadowed = mempty}

topType :: NormalizedType
topType = NormalizedType {baseType = NormalizedTypeBaseUnknown, attribute = topAttribute}

topAttribute :: NormalizedAttribute
topAttribute = NormalizedAttribute {private = True, generic = Set.empty}

topEffect :: NormalizedEffect
topEffect = NormalizedEffectAny

normalizeType :: SemanticType -> Normalizer NormalizedType
normalizeType semanticTypeBase = case semanticTypeBase of
  SemanticTypeNever -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer
  SemanticTypeUnknown -> pure $ makeNormalizedTypeWithPublic NormalizedTypeBaseUnknown
  SemanticTypeAgent parameterType returnType effect -> do
    normalizedArgument <- normalizeType parameterType
    normalizedReturnType <- normalizeType returnType
    normalizedEffect <- normalizeEffect effect
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedTypeBaseLayerd $
          neverLayer
            { functionLayer = FunctionSlotOf normalizedArgument normalizedReturnType normalizedEffect
            }
  SemanticTypeNull -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {nullLayer = True}
  SemanticTypeBoolean -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {booleanLayer = True}
  SemanticTypeFile -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {fileLayer = True}
  SemanticTypeInteger -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {numberLayer = NumberSlotInteger}
  SemanticTypeNumber -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {numberLayer = NumberSlotNumber}
  SemanticTypeString -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {stringLayer = True}
  SemanticTypeArray itemType -> do
    normalizedItemType <- normalizeType itemType
    pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {sequenceLayer = SequenceSlotArray normalizedItemType}
  SemanticTypeTuple itemTypes -> do
    normalizedItemTypes <- mapM normalizeType itemTypes
    pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {sequenceLayer = SequenceSlotTuple normalizedItemTypes}
  SemanticTypeData qualifiedName genericArguments -> do
    normalizedGenericArguments <- mapM normalizeGenericArgument genericArguments
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedTypeBaseLayerd neverLayer {dataLayer = Map.singleton qualifiedName normalizedGenericArguments}
  SemanticTypeObject fields -> do
    normalizedFields <- mapM normalizeFieldInformation fields
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedTypeBaseLayerd
          neverLayer
            { objectLayer =
                ObjectSlotOf $
                  NormalizedObject
                    { fields = normalizedFields,
                      -- NOTE: Other fields must be "public"
                      -- then; {x: number, y: number of private} /<: {x: number}  <-- Error because field y is private in the left type but public in the right type.
                      --       {x: number, y: number of private} <: {x: number} of private   <-- OK.
                      rest = NormalizedType {baseType = NormalizedTypeBaseUnknown, attribute = bottomAttribute}
                    }
            }
  SemanticTypeRecord recordType -> do
    normalizedRecordType <- normalizeType recordType
    pure $
      makeNormalizedTypeWithPublic $
        NormalizedTypeBaseLayerd neverLayer {objectLayer = ObjectSlotOf $ NormalizedObject {fields = mempty, rest = normalizedRecordType}}
  SemanticTypeGeneric genericArgumentName -> pure $ makeNormalizedTypeWithPublic $ NormalizedTypeBaseLayerd neverLayer {genericLayer = Set.singleton genericArgumentName}
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
    makeNormalizedTypeWithPublic normalizedTypeBase =
      NormalizedType {baseType = normalizedTypeBase, attribute = bottomAttribute} -- default attribute is public

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

unionBaseType :: NormalizedTypeBase -> NormalizedTypeBase -> Normalizer NormalizedTypeBase
unionBaseType left right = case (left, right) of
  (NormalizedTypeBaseUnknown, _) -> pure NormalizedTypeBaseUnknown
  (_, NormalizedTypeBaseUnknown) -> pure NormalizedTypeBaseUnknown
  (NormalizedTypeBaseLayerd leftLayer, NormalizedTypeBaseLayerd rightLayer) -> do
    unionedLayer <- unionLayeredType leftLayer rightLayer
    pure $ NormalizedTypeBaseLayerd unionedLayer
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
      (SequenceSlotAbsent, other) -> pure other
      (other, SequenceSlotAbsent) -> pure other
      (SequenceSlotTuple leftItemTypes, SequenceSlotTuple rightItemTypes) -> do
        -- zip: [number, string] | [boolean]  ~> [number | boolean]
        unionedItemTypes <- zipWithM unionType leftItemTypes rightItemTypes
        pure $ SequenceSlotTuple unionedItemTypes
      (SequenceSlotArray leftItemType, SequenceSlotArray rightItemType) -> do
        unionedItemType <- unionType leftItemType rightItemType
        pure $ SequenceSlotArray unionedItemType
      (SequenceSlotTuple leftItemTypes, SequenceSlotArray rightItemType) -> do
        unionedItemType <- mapM (unionType rightItemType) leftItemTypes
        pure $ SequenceSlotTuple unionedItemType
      (SequenceSlotArray leftItemType, SequenceSlotTuple rightItemTypes) -> do
        unionedItemType <- mapM (unionType leftItemType) rightItemTypes
        pure $ SequenceSlotTuple unionedItemType

    unionObjectLayer :: ObjectSlot -> ObjectSlot -> Normalizer ObjectSlot
    unionObjectLayer leftObject rightObject = case (leftObject, rightObject) of
      (ObjectSlotAbsent, other) -> pure other
      (other, ObjectSlotAbsent) -> pure other
      (ObjectSlotOf leftNormalizedObject, ObjectSlotOf rightNormalizedObject) -> do
        -- NOTE: if a field is optional in either left or right, the field is optional in the unioned type
        -- Field keys are intersected because of width subtyping
        -- Ex) {x: number, y: number} | {y: number, z: number} ~> {y: number}
        unionedFields <- intersectWithKeyM unionField leftNormalizedObject.fields rightNormalizedObject.fields
        unionedRest <- unionType leftNormalizedObject.rest rightNormalizedObject.rest
        pure $ ObjectSlotOf $ NormalizedObject {fields = unionedFields, rest = unionedRest}

    unionField :: Text -> NormalizedFieldInformation -> NormalizedFieldInformation -> Normalizer NormalizedFieldInformation
    unionField _ leftFieldInformation rightFieldInformation = do
      unionedFieldType <- unionType leftFieldInformation.normalizedType rightFieldInformation.normalizedType
      pure (NormalizedFieldInformation {normalizedType = unionedFieldType, optional = leftFieldInformation.optional || rightFieldInformation.optional})

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

intersectType :: NormalizedType -> NormalizedType -> Normalizer NormalizedType
intersectType = undefined

intersectEffect :: NormalizedEffect -> NormalizedEffect -> Normalizer NormalizedEffect
intersectEffect = undefined

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

-- | Check if the first type is a subtype of the second type. (first <: second)
-- NOTE: Attribute
-- private <: public, public /<: private
-- Attribute distribution rule:
--   private {x : number of public} <: public {x : number of private} -- OK
subtypeType ::
  NormalizedType ->
  NormalizedType ->
  Normalizer Bool
subtypeType = undefined
