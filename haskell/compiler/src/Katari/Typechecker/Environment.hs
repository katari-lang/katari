-- | The Build-Environment step (Phase B of the checker): a single global pass that collects every
-- module's data / request / synonym declarations into the read-only environment the per-module
-- checker consults. Global because variance is inferred by a cross-module fixed point and type-shape
-- normalization needs the arity / kind of declarations made in other modules.
--
-- Only the /type-level/ world lives here. The value world (an @agent@'s scheme, whose return / effect
-- may be inferred from its body) is built demand-driven by the checker (Phase C) as it recurses
-- through definitions, so it is deliberately absent from 'TypeEnvironment'.
--
-- The pass runs in four stages ('buildEnvironment' chains them top to bottom):
--
--   1. collect ('collectDeclarations') — gather the data / request / synonym declarations;
--   2. elaborate ('elaborateAll') — turn each declaration's annotated types into semantic form
--      ("Katari.Typechecker.Elaborate"), expanding synonyms;
--   3. variance ('inferVariance') — infer each generic parameter's variance by a fixed point over the
--      elaborated (pre-normalized) shapes;
--   4. normalize ('normalizeAll') — with variance in hand, normalize the shapes into the lattice's
--      internal form.
module Katari.Typechecker.Environment where

import Control.Monad.RWS.CPS (runRWS)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (DataEnvironment, DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestEnvironment, RequestInformation (..), SynonymEnvironment, SynonymInformation (..))
import Katari.Data.Id (GenericId, TypeResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.NormalizedType (NormalizedKindedType, bottomAttribute, bottomType)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (FieldInformation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..))
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Data.Variance (Variance (..), composeVariance, joinVariance)
import Katari.Diagnostics (Diagnostics, diagnosticAt)
import Katari.Error (CompilerError (..))
import Katari.Typechecker.Elaborate (Elaborate, ElaborateContext, SynonymSignature (..), elaborate, elaborateAsType, emptyContext, runElaborate, withOwnGenerics)
import Katari.Typechecker.Normalizer (Normalizer, NormalizerEnvironment, SubtypingContext (..), normalizeGenericArgument, normalizeType)

-- | The read-only type-level environment the checker consults across the whole program:
--
--   * 'dataEnvironment' / 'requestEnvironment' — the normalized constructor / request shape and
--     inferred variance of every nominal data type and request;
--   * 'synonymEnvironment' — every type synonym's normalized definition and generics, so a per-module
--     checker can expand a synonym defined elsewhere.
--
-- Per-module generic bounds and the subtyping @world@ are added locally by the checker (see
-- "Katari.Typechecker.Normalizer"), so they are not here. The value scheme of each @agent@ /
-- @external@ / @primitive@ is built on demand by the checker, so it is not here either.
data TypeEnvironment = TypeEnvironment
  { dataEnvironment :: DataEnvironment,
    requestEnvironment :: RequestEnvironment,
    synonymEnvironment :: SynonymEnvironment,
    -- | The elaborator's signature registry over every declaration. Built once here so the checker
    -- (Phase C) can elaborate annotations written inside agent bodies without re-collecting the
    -- declarations.
    elaborateContext :: ElaborateContext
  }
  deriving stock (Eq, Show)

emptyTypeEnvironment :: TypeEnvironment
emptyTypeEnvironment =
  TypeEnvironment
    { dataEnvironment = mempty,
      requestEnvironment = mempty,
      synonymEnvironment = mempty,
      elaborateContext = emptyContext mempty mempty mempty
    }

------------------------------------------------------------------------------------------------
-- Stage 1: collect the declarations
------------------------------------------------------------------------------------------------

-- | A data declaration reduced to what the env-build needs: its name, generics, constructor
-- parameters and span (for error anchoring).
data CollectedData = CollectedData
  { qualifiedName :: QualifiedName,
    genericParameters :: GenericParameters,
    genericBounds :: Map GenericId (SyntacticTypeExpression Identified),
    parameters :: List (ParameterSignature Identified),
    sourceSpan :: SourceSpan
  }

data CollectedRequest = CollectedRequest
  { qualifiedName :: QualifiedName,
    genericParameters :: GenericParameters,
    genericBounds :: Map GenericId (SyntacticTypeExpression Identified),
    parameters :: List (ParameterSignature Identified),
    returnType :: SyntacticTypeExpression Identified,
    sourceSpan :: SourceSpan
  }

data CollectedSynonym = CollectedSynonym
  { qualifiedName :: QualifiedName,
    genericParameters :: GenericParameters,
    genericBounds :: Map GenericId (SyntacticTypeExpression Identified),
    body :: SyntacticTypeExpression Identified,
    sourceSpan :: SourceSpan
  }

-- | One declared generic reduced to its 'GenericParameterInformation' (whose 'variance' / 'upperBound'
-- start as placeholders the later stages fill) and its still-syntactic @extends@ bound, if any.
-- 'Nothing' if the identifier left the parameter unresolved, which should not happen for a
-- declaration's own generic.
collectGenericParameter :: GenericParameter Identified -> Maybe (Text, GenericParameterInformation, Maybe (SyntacticTypeExpression Identified))
collectGenericParameter parameter = case parameter.typeReference.resolution of
  Just (TypeResolutionGeneric genericId) ->
    Just
      ( parameter.name,
        GenericParameterInformation {genericId = genericId, kind = parameter.kind, variance = Bivariant, upperBound = Nothing},
        parameter.upperBound
      )
  _ -> Nothing

-- | A declaration's collected generic parameters (in declaration order, by name) and its syntactic
-- @extends@ bounds, keyed by generic id. The bounds are elaborated + normalized and stamped onto the
-- parameters' 'upperBound' once the normalizer environment is available.
collectGenericParameters :: List (GenericParameter Identified) -> (GenericParameters, Map GenericId (SyntacticTypeExpression Identified))
collectGenericParameters parameters =
  let collected = mapMaybe collectGenericParameter parameters
   in ( GenericParameters
          { parameterNames = [name | (name, _, _) <- collected],
            parameterInformation = Map.fromList [(name, info) | (name, info, _) <- collected]
          },
        Map.fromList [(info.genericId, bound) | (_, info, Just bound) <- collected]
      )

-- | Split every module's declarations into the data / request / synonym lists, keyed by qualified
-- name. Other declarations (agents / externals / primitives / imports) belong to the value world and
-- are dropped here. Each kind is filtered out by its constructor in the comprehension generator.
collectDeclarations :: Map ModuleName (Module Identified) -> (List CollectedData, List CollectedRequest, List CollectedSynonym)
collectDeclarations modules =
  ( [collectData declaration | DeclarationData declaration <- declarations],
    [collectRequest declaration | DeclarationRequest declaration <- declarations],
    [collectSynonym declaration | DeclarationTypeSynonym declaration <- declarations]
  )
  where
    declarations = [declaration | module' <- Map.elems modules, declaration <- module'.declarations]
    collectData declaration =
      let (genericParameters, genericBounds) = collectGenericParameters declaration.genericParameters
       in CollectedData
            { qualifiedName = referencedVariableName declaration.variableReference,
              genericParameters = genericParameters,
              genericBounds = genericBounds,
              parameters = declaration.parameters,
              sourceSpan = declaration.sourceSpan
            }
    collectRequest declaration =
      let (genericParameters, genericBounds) = collectGenericParameters declaration.genericParameters
       in CollectedRequest
            { qualifiedName = referencedTypeName declaration.typeReference,
              genericParameters = genericParameters,
              genericBounds = genericBounds,
              parameters = declaration.parameters,
              returnType = declaration.returnType,
              sourceSpan = declaration.sourceSpan
            }
    collectSynonym declaration =
      let (genericParameters, genericBounds) = collectGenericParameters declaration.genericParameters
       in CollectedSynonym
            { qualifiedName = referencedTypeName declaration.typeReference,
              genericParameters = genericParameters,
              genericBounds = genericBounds,
              body = declaration.definition,
              sourceSpan = declaration.sourceSpan
            }

------------------------------------------------------------------------------------------------
-- Stage 2: elaborate each declaration's annotated types
------------------------------------------------------------------------------------------------

-- | The elaborated (pre-normalized) shape of every declaration, carried from the elaborate stage to
-- the variance and normalize stages. A synonym body / generic bound is 'Nothing' (poison) when it
-- rests on an unresolved name.
data ElaboratedShapes = ElaboratedShapes
  { dataShapes :: List (CollectedData, SemanticType),
    requestShapes :: List (CollectedRequest, (SemanticType, SemanticType)),
    synonymShapes :: List (CollectedSynonym, Maybe SemanticGenericArgument),
    boundShapes :: Map QualifiedName (Map GenericId (Maybe SemanticGenericArgument))
  }

-- | A data type's / request's constructor object: each parameter becomes a required field (a value's
-- fields are always present once constructed; a parameter default is a call-site concern, not part of
-- the read shape).
constructorObject :: List (ParameterSignature Identified) -> Elaborate SemanticType
constructorObject parameters = SemanticTypeObject . Map.fromList <$> traverse field parameters
  where
    field signature = do
      fieldType <- elaborateAsType signature.parameterType
      pure (signature.name, FieldInformation {semanticType = fieldType, optional = False})

-- | The elaborator's signature registry over every collected declaration.
elaborateContextFor :: List CollectedData -> List CollectedRequest -> List CollectedSynonym -> ElaborateContext
elaborateContextFor collectedData collectedRequests collectedSynonyms =
  emptyContext
    (Map.fromList [(item.qualifiedName, item.genericParameters) | item <- collectedData])
    (Map.fromList [(item.qualifiedName, item.genericParameters) | item <- collectedRequests])
    (Map.fromList [(item.qualifiedName, SynonymSignature {genericParameters = item.genericParameters, body = item.body}) | item <- collectedSynonyms])

-- | Elaborate every declaration's annotated types in one run (sharing the registry, accumulating
-- diagnostics). Each declaration's body is elaborated with its own generics in scope ('withOwnGenerics').
elaborateAll :: ElaborateContext -> (List CollectedData, List CollectedRequest, List CollectedSynonym) -> (ElaboratedShapes, Diagnostics)
elaborateAll context (collectedData, collectedRequests, collectedSynonyms) =
  runElaborate context $ do
    dataShapes <-
      traverse (\item -> (,) item <$> withOwnGenerics item.genericParameters (constructorObject item.parameters)) collectedData
    requestShapes <-
      traverse
        ( \item ->
            (,) item
              <$> withOwnGenerics
                item.genericParameters
                ((,) <$> constructorObject item.parameters <*> elaborateAsType item.returnType)
        )
        collectedRequests
    synonymShapes <-
      traverse (\item -> (,) item <$> withOwnGenerics item.genericParameters (elaborate item.body)) collectedSynonyms
    -- A bound elaborates with the same kind-agnostic 'elaborate' synonyms use (a bound is a type /
    -- effect / attribute), with its declaration's generics in scope.
    boundShapes <-
      Map.fromList
        <$> traverse
          (\(qualifiedName, generics, bounds) -> (,) qualifiedName <$> withOwnGenerics generics (traverse elaborate bounds))
          boundedDeclarations
    pure ElaboratedShapes {dataShapes = dataShapes, requestShapes = requestShapes, synonymShapes = synonymShapes, boundShapes = boundShapes}
  where
    boundedDeclarations =
      [(item.qualifiedName, item.genericParameters, item.genericBounds) | item <- collectedData]
        <> [(item.qualifiedName, item.genericParameters, item.genericBounds) | item <- collectedRequests]
        <> [(item.qualifiedName, item.genericParameters, item.genericBounds) | item <- collectedSynonyms]

------------------------------------------------------------------------------------------------
-- Stage 3: variance inference
--
-- A variance variable is just a 'GenericId' (globally unique once paired with its module). Inference
-- starts every parameter at 'Bivariant' and joins in each occurrence's polarity to a fixed point.
------------------------------------------------------------------------------------------------

-- | What the variance walk needs: the name -> id map of every declaration's parameters (so an
-- argument named at an application site resolves to the generic id whose variance it constrains) and
-- the current estimate being iterated.
data VarianceContext = VarianceContext
  { parameterIdsByName :: Map QualifiedName (Map Text GenericId),
    estimate :: Map GenericId Variance
  }

mergeVariances :: List (Map GenericId Variance) -> Map GenericId Variance
mergeVariances = Map.unionsWith joinVariance

-- | The variance of a nested declaration's parameter (looked up by the argument's name through the
-- declaration's name -> id map), defaulting to 'Bivariant' (unconstrained / not yet seen).
nestedVariance :: VarianceContext -> QualifiedName -> Text -> Variance
nestedVariance context qualifiedName parameterName =
  case Map.lookup qualifiedName context.parameterIdsByName >>= Map.lookup parameterName of
    Just genericId -> Map.findWithDefault Bivariant genericId context.estimate
    Nothing -> Bivariant

-- | Collect each generic's variance contribution within a type, observed at the outer polarity
-- @sign@. Joined across every occurrence.
walkType :: VarianceContext -> Variance -> SemanticType -> Map GenericId Variance
walkType context sign = \case
  SemanticTypeGeneric genericId -> Map.singleton genericId sign
  SemanticTypeAgent parameterType returnType effect ->
    mergeVariances
      [ walkType context (composeVariance sign Contravariant) parameterType,
        walkType context sign returnType,
        walkEffect context sign effect
      ]
  SemanticTypeArray itemType -> walkType context sign itemType
  SemanticTypeTuple itemTypes -> mergeVariances (map (walkType context sign) itemTypes)
  SemanticTypeObject fields -> mergeVariances [walkType context sign field.semanticType | field <- Map.elems fields]
  SemanticTypeRecord itemType -> walkType context sign itemType
  SemanticTypeData qualifiedName arguments -> walkApplicationArguments context sign qualifiedName arguments
  SemanticTypeUnion types -> mergeVariances (map (walkType context sign) types)
  SemanticTypeAttribute baseType attribute -> mergeVariances [walkType context sign baseType, walkAttribute context sign attribute]
  -- Primitive / never / unknown / null carry no generics.
  _ -> Map.empty

walkEffect :: VarianceContext -> Variance -> SemanticEffect -> Map GenericId Variance
walkEffect context sign = \case
  SemanticEffectGeneric genericId -> Map.singleton genericId sign
  SemanticEffectRequest qualifiedName arguments -> walkApplicationArguments context sign qualifiedName arguments
  SemanticEffectUnion effects -> mergeVariances (map (walkEffect context sign) effects)
  SemanticEffectOverwrite baseEffect overrides ->
    mergeVariances
      ( walkEffect context sign baseEffect
          : [walkApplicationArguments context sign qualifiedName arguments | (qualifiedName, arguments) <- overrides]
      )
  SemanticEffectPure -> Map.empty
  SemanticEffectAny -> Map.empty

-- | Walk a nested data / request application's arguments. Both a data type's @SemanticTypeData@ and a
-- request's @SemanticEffectRequest@ are applications of a declaration's parameters, so each argument is
-- observed at the outer polarity composed with the applied parameter's (currently estimated) variance.
walkApplicationArguments :: VarianceContext -> Variance -> QualifiedName -> Map Text SemanticGenericArgument -> Map GenericId Variance
walkApplicationArguments context sign qualifiedName arguments =
  mergeVariances
    [ walkArgument context (composeVariance sign (nestedVariance context qualifiedName parameterName)) argument
      | (parameterName, argument) <- Map.toList arguments
    ]

walkAttribute :: VarianceContext -> Variance -> SemanticAttribute -> Map GenericId Variance
walkAttribute context sign = \case
  SemanticAttributeGeneric genericId -> Map.singleton genericId sign
  SemanticAttributeUnion attributes -> mergeVariances (map (walkAttribute context sign) attributes)
  SemanticAttributePublic -> Map.empty
  SemanticAttributePrivate -> Map.empty

walkArgument :: VarianceContext -> Variance -> SemanticGenericArgument -> Map GenericId Variance
walkArgument context sign = \case
  SemanticGenericArgumentType semanticType -> walkType context sign semanticType
  SemanticGenericArgumentEffect effect -> walkEffect context sign effect
  SemanticGenericArgumentAttribute attribute -> walkAttribute context sign attribute

-- | One shape whose generics' variance is being inferred: its own parameter ids (which the result is
-- keyed by) and the (rooted) sub-shapes contributing usage. A data constructor is a sole covariant
-- root; a request's parameter object is covariant and its return type contravariant (dual to a
-- function, because the performer supplies the parameter and consumes the return through the handler).
data VarianceShape = VarianceShape
  { ownParameterIds :: List GenericId,
    roots :: List (Variance, SemanticType)
  }

-- | The variance shapes of the data constructors and requests (synonyms are expanded away, so they
-- carry no variance of their own).
varianceShapesOf :: ElaboratedShapes -> List VarianceShape
varianceShapesOf shapes =
  [VarianceShape {ownParameterIds = ownParameterIdsOf item.genericParameters, roots = [(Covariant, constructor)]} | (item, constructor) <- shapes.dataShapes]
    <> [VarianceShape {ownParameterIds = ownParameterIdsOf item.genericParameters, roots = [(Covariant, parameterObject), (Contravariant, returnType)]} | (item, (parameterObject, returnType)) <- shapes.requestShapes]

ownParameterIdsOf :: GenericParameters -> List GenericId
ownParameterIdsOf parameters = [info.genericId | info <- Map.elems parameters.parameterInformation]

-- | Every data type's / request's parameter name -> id map, so a nested application's argument name
-- resolves to the generic id whose variance it constrains.
parameterIdsByNameOf :: ElaboratedShapes -> Map QualifiedName (Map Text GenericId)
parameterIdsByNameOf shapes =
  Map.fromList $
    [(item.qualifiedName, (.genericId) <$> item.genericParameters.parameterInformation) | (item, _) <- shapes.dataShapes]
      <> [(item.qualifiedName, (.genericId) <$> item.genericParameters.parameterInformation) | (item, _) <- shapes.requestShapes]

-- | One pass of the fixed point: recompute every variance variable from the current estimate. A
-- generic absent from its shape's usage is 'Bivariant'.
varianceIteration :: Map QualifiedName (Map Text GenericId) -> List VarianceShape -> Map GenericId Variance -> Map GenericId Variance
varianceIteration parameterIdsByName shapes currentEstimate =
  Map.fromList
    [ (genericId, Map.findWithDefault Bivariant genericId usage)
      | shape <- shapes,
        let context = VarianceContext {parameterIdsByName = parameterIdsByName, estimate = currentEstimate}
            usage = mergeVariances [walkType context sign root | (sign, root) <- shape.roots],
        genericId <- shape.ownParameterIds
    ]

-- | Iterate 'varianceIteration' to its (least) fixed point. The variance lattice is finite and the
-- step is monotone from the all-'Bivariant' bottom, so this terminates.
inferVariance :: Map QualifiedName (Map Text GenericId) -> List VarianceShape -> Map GenericId Variance
inferVariance parameterIdsByName shapes = settle Map.empty
  where
    settle current =
      let next = varianceIteration parameterIdsByName shapes current
       in if next == current then current else settle next

------------------------------------------------------------------------------------------------
-- Stage 4: normalize the elaborated shapes (with variance and bounds in hand)
------------------------------------------------------------------------------------------------

-- | Stamp each parameter with its inferred variance (an unconstrained parameter stays 'Bivariant').
applyVariance :: Map GenericId Variance -> GenericParameters -> GenericParameters
applyVariance variances parameters =
  parameters {parameterInformation = stamp <$> parameters.parameterInformation}
  where
    stamp parameter = parameter {variance = Map.findWithDefault Bivariant parameter.genericId variances}

-- | Stamp a parameter's normalized @extends@ upper bound (looked up by its generic id) onto its
-- 'upperBound'; an unbounded parameter keeps 'Nothing'. Rebuilt rather than record-updated because
-- 'upperBound' is shared with the AST 'GenericParameter', which makes a field update ambiguous (and
-- -XDuplicateRecordFields-deprecated); 'applyVariance' updates 'variance' in place because that field
-- is unique to 'GenericParameterInformation'.
stampBound :: Map GenericId NormalizedKindedType -> GenericParameterInformation -> GenericParameterInformation
stampBound bounds parameter =
  GenericParameterInformation
    { genericId = parameter.genericId,
      kind = parameter.kind,
      variance = parameter.variance,
      upperBound = Map.lookup parameter.genericId bounds
    }

-- | Run a normalization sub-computation, anchoring any type errors it emits at @sourceSpan@. The
-- normalizer is span-free, so a declaration's errors all anchor at the declaration as a whole.
runNormalize :: NormalizerEnvironment -> SourceSpan -> Normalizer a -> (a, Diagnostics)
runNormalize environment sourceSpan action =
  let (result, _, errors) = runRWS action environment ()
   in (result, foldMap (diagnosticAt sourceSpan . CompilerErrorType) errors)

-- | Normalize every elaborated shape into its 'TypeEnvironment' entry. The variance is already
-- inferred; the bounds are normalized here and stamped onto each parameter's 'upperBound'.
normalizeAll :: ElaborateContext -> Map GenericId Variance -> ElaboratedShapes -> (TypeEnvironment, Diagnostics)
normalizeAll elaborateContext variances shapes = (environment, dataDiagnostics <> requestDiagnostics <> synonymDiagnostics)
  where
    -- Stamp variance onto every declaration's parameters once, up front.
    stampedData = [(item, applyVariance variances item.genericParameters, semantic) | (item, semantic) <- shapes.dataShapes]
    stampedRequests = [(item, applyVariance variances item.genericParameters, payload) | (item, payload) <- shapes.requestShapes]
    stampedSynonyms = [(item, applyVariance variances item.genericParameters, body) | (item, body) <- shapes.synonymShapes]

    -- The normalizer reads only the parameter lists (for arity / variance), never the constructor, so
    -- a placeholder constructor / request shape is fine while the declarations normalize.
    normalizerEnvironment =
      SubtypingContext
        { dataEnvironment = Map.fromList [(item.qualifiedName, DataInformation {name = item.qualifiedName, genericParameters = parameters, constructor = bottomType}) | (item, parameters, _) <- stampedData],
          requestEnvironment = Map.fromList [(item.qualifiedName, RequestInformation {name = item.qualifiedName, genericParameters = parameters, request = (bottomType, bottomType)}) | (item, parameters, _) <- stampedRequests],
          -- Normalization never resolves a generic's bound (a subtyping-time concern), so no in-scope
          -- generics are needed to normalize the declarations themselves.
          genericsInScope = mempty,
          world = bottomAttribute
        }

    -- Normalize a declaration's collected @extends@ bounds and stamp each onto its parameters'
    -- 'upperBound' (the parameters already carry their inferred variance); an unbounded or
    -- failed-to-elaborate parameter keeps 'Nothing'.
    stampBoundsFor qualifiedName sourceSpan parameters =
      let semanticBounds = Map.mapMaybe id (Map.findWithDefault mempty qualifiedName shapes.boundShapes)
          (normalizedBounds, diagnostics) = runNormalize normalizerEnvironment sourceSpan (traverse normalizeGenericArgument semanticBounds)
       in (parameters {parameterInformation = stampBound normalizedBounds <$> parameters.parameterInformation}, diagnostics)

    normalizeData item parameters semantic =
      let (constructor, constructorDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType semantic)
          (boundedParameters, boundDiagnostics) = stampBoundsFor item.qualifiedName item.sourceSpan parameters
       in (DataInformation {name = item.qualifiedName, genericParameters = boundedParameters, constructor = constructor}, constructorDiagnostics <> boundDiagnostics)

    normalizeRequest item parameters (parameterObject, returnSemantic) =
      let (parameterType, parameterDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType parameterObject)
          (returnType, returnDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType returnSemantic)
          (boundedParameters, boundDiagnostics) = stampBoundsFor item.qualifiedName item.sourceSpan parameters
       in (RequestInformation {name = item.qualifiedName, genericParameters = boundedParameters, request = (parameterType, returnType)}, parameterDiagnostics <> returnDiagnostics <> boundDiagnostics)

    normalizeSynonym item parameters maybeSemantic =
      let semantic = fromMaybe (SemanticGenericArgumentType SemanticTypeNever) maybeSemantic
          (definition, definitionDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeGenericArgument semantic)
          (boundedParameters, boundDiagnostics) = stampBoundsFor item.qualifiedName item.sourceSpan parameters
       in (SynonymInformation {name = item.qualifiedName, genericParameters = boundedParameters, definition = definition}, definitionDiagnostics <> boundDiagnostics)

    (dataInfos, dataDiagnostics) = unzipDiagnostics [normalizeData item parameters semantic | (item, parameters, semantic) <- stampedData]
    (requestInfos, requestDiagnostics) = unzipDiagnostics [normalizeRequest item parameters payload | (item, parameters, payload) <- stampedRequests]
    (synonymInfos, synonymDiagnostics) = unzipDiagnostics [normalizeSynonym item parameters body | (item, parameters, body) <- stampedSynonyms]

    environment =
      TypeEnvironment
        { dataEnvironment = Map.fromList [(info.name, info) | info <- dataInfos],
          requestEnvironment = Map.fromList [(info.name, info) | info <- requestInfos],
          synonymEnvironment = Map.fromList [(info.name, info) | info <- synonymInfos],
          elaborateContext = elaborateContext
        }

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

-- | Build the global type-level environment from every identified module by chaining the four stages.
buildEnvironment :: Map ModuleName (Module Identified) -> (TypeEnvironment, Diagnostics)
buildEnvironment modules = (environment, elaborateDiagnostics <> normalizeDiagnostics)
  where
    collected@(collectedData, collectedRequests, collectedSynonyms) = collectDeclarations modules
    elaborateContext = elaborateContextFor collectedData collectedRequests collectedSynonyms
    (shapes, elaborateDiagnostics) = elaborateAll elaborateContext collected
    variances = inferVariance (parameterIdsByNameOf shapes) (varianceShapesOf shapes)
    (environment, normalizeDiagnostics) = normalizeAll elaborateContext variances shapes

unzipDiagnostics :: List (a, Diagnostics) -> (List a, Diagnostics)
unzipDiagnostics items = (map fst items, foldMap snd items)
