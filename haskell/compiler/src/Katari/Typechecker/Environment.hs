-- | The Build-Environment step (Phase B of the checker): a single global pass that collects every
-- module's data / request / synonym declarations into the read-only environment the per-module
-- checker consults. Global because variance is inferred by a cross-module fixed point and type-shape
-- normalization needs the arity / kind of declarations made in other modules.
--
-- Only the /type-level/ world lives here. The value world (an @agent@'s scheme, whose return / effect
-- may be inferred from its body) is built demand-driven by the checker (Phase C) as it recurses
-- through definitions, so it is deliberately absent from 'TypeEnvironment'.
--
-- The pass runs in four stages:
--
--   1. collect — gather the data / request / synonym declarations, keyed by qualified name;
--   2. elaborate — turn each declaration's annotated types into semantic form
--      ("Katari.Typechecker.Elaborate"), expanding synonyms;
--   3. variance — infer each generic parameter's variance by a fixed point over the elaborated
--      (pre-normalized) shapes;
--   4. normalize — with variance in hand, normalize the shapes into the lattice's internal form.
module Katari.Typechecker.Environment where

import Control.Monad.RWS.CPS (runRWS)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (DataEnvironment, DataInfo (..), GenericParameterInfo (..), RequestEnvironment, RequestInfo (..), SynonymEnvironment, SynonymInfo (..), namesByGenericId)
import Katari.Data.Id (GenericId, TypeResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.NormalizedType (NormalizedGenericArgument (..), NormalizedType, bottomAttribute, bottomType)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (FieldInformation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..))
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Data.Variance (Variance (..), composeVariance, joinVariance)
import Katari.Diagnostics (Diagnostics, diagnosticAt)
import Katari.Error (CompilerError (..))
import Katari.Typechecker.Elaborate (Elaborate, SynonymSignature (..), elaborate, elaborateAsType, emptyContext, runElaborate)
import Katari.Typechecker.Normalizer (Normalizer, NormalizerEnvironment (..), normalizeGenericArgument, normalizeType)

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
  { dataEnvironment :: DataEnvironment NormalizedType,
    requestEnvironment :: RequestEnvironment NormalizedType,
    synonymEnvironment :: SynonymEnvironment NormalizedGenericArgument
  }
  deriving stock (Eq, Show)

emptyTypeEnvironment :: TypeEnvironment
emptyTypeEnvironment =
  TypeEnvironment
    { dataEnvironment = mempty,
      requestEnvironment = mempty,
      synonymEnvironment = mempty
    }

------------------------------------------------------------------------------------------------
-- Stage 1: collect the declarations
------------------------------------------------------------------------------------------------

-- | A data declaration reduced to what the env-build needs: its name, generics, constructor
-- parameters and span (for error anchoring).
data CollectedData = CollectedData
  { qualifiedName :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    parameters :: List (ParameterSignature Identified),
    sourceSpan :: SourceSpan
  }

data CollectedRequest = CollectedRequest
  { qualifiedName :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    parameters :: List (ParameterSignature Identified),
    returnType :: SyntacticTypeExpression Identified,
    sourceSpan :: SourceSpan
  }

data CollectedSynonym = CollectedSynonym
  { qualifiedName :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    body :: SyntacticTypeExpression Identified,
    sourceSpan :: SourceSpan
  }

-- | The 'GenericParameterInfo' of one declared generic, with a placeholder 'Bivariant' (the variance
-- fixed point fills it in later). 'Nothing' if the identifier left the parameter unresolved, which
-- should not happen for a declaration's own generics.
collectGenericParameter :: GenericParameter Identified -> Maybe GenericParameterInfo
collectGenericParameter parameter = case parameter.typeReference.resolution of
  Just (TypeResolutionGenericType genericId) -> Just (build genericId)
  Just (TypeResolutionGenericEffect genericId) -> Just (build genericId)
  Just (TypeResolutionGenericAttribute genericId) -> Just (build genericId)
  _ -> Nothing
  where
    build genericId =
      GenericParameterInfo
        { name = parameter.name,
          genericId = genericId,
          kind = parameter.kind,
          variance = Bivariant
        }

collectGenericParameters :: List (GenericParameter Identified) -> List GenericParameterInfo
collectGenericParameters = mapMaybe collectGenericParameter

-- | Walk every module's declarations once, splitting out the data / request / synonym declarations
-- with their qualified names. Other declarations (agents / externals / primitives / imports) belong
-- to the value world and are ignored here.
collectDeclarations :: Map ModuleName (Module Identified) -> (List CollectedData, List CollectedRequest, List CollectedSynonym)
collectDeclarations modules =
  mconcat
    [ collectOne moduleName declaration
      | (moduleName, module') <- Map.toList modules,
        declaration <- module'.declarations
    ]
  where
    collectOne moduleName = \case
      DeclarationData declaration ->
        ( [ CollectedData
              { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
                genericParameters = collectGenericParameters declaration.genericParameters,
                parameters = declaration.parameters,
                sourceSpan = declaration.sourceSpan
              }
          ],
          [],
          []
        )
      DeclarationRequest declaration ->
        ( [],
          [ CollectedRequest
              { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
                genericParameters = collectGenericParameters declaration.genericParameters,
                parameters = declaration.parameters,
                returnType = declaration.returnType,
                sourceSpan = declaration.sourceSpan
              }
          ],
          []
        )
      DeclarationTypeSynonym declaration ->
        ( [],
          [],
          [ CollectedSynonym
              { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
                genericParameters = collectGenericParameters declaration.genericParameters,
                body = declaration.definition,
                sourceSpan = declaration.sourceSpan
              }
          ]
        )
      _ -> ([], [], [])

------------------------------------------------------------------------------------------------
-- Stage 2: elaborate each declaration's annotated types
------------------------------------------------------------------------------------------------

-- | A data type's / request's constructor object: each parameter becomes a required field (a value's
-- fields are always present once constructed; a parameter default is a call-site concern, not part of
-- the read shape).
constructorObject :: List (ParameterSignature Identified) -> Elaborate SemanticType
constructorObject parameters = do
  fields <- traverse field parameters
  pure (SemanticTypeObject (Map.fromList fields))
  where
    field signature = do
      fieldType <- elaborateAsType signature.parameterType
      pure (signature.name, FieldInformation {semanticType = fieldType, optional = False})

------------------------------------------------------------------------------------------------
-- Stage 3: variance inference
------------------------------------------------------------------------------------------------

-- | A variance variable the fixed point solves for: a declaration's qualified name paired with one of
-- its own generic parameter /names/. Keyed by name, not generic id, because generic ids are only
-- unique within a single module — a cross-module fixed point keyed by raw id would conflate two
-- modules' parameters that happen to share an id.
type VarianceVariable = (QualifiedName, Text)

-- | What the variance walk needs: the declaration whose shape is currently being walked (its name and
-- its own generic ids → names, so an occurrence of one of its generics resolves to a variance
-- variable) and the current estimate being iterated.
data VarianceContext = VarianceContext
  { currentName :: QualifiedName,
    currentParameterNames :: Map GenericId Text,
    estimate :: Map VarianceVariable Variance
  }

mergeVariances :: List (Map VarianceVariable Variance) -> Map VarianceVariable Variance
mergeVariances = Map.unionsWith joinVariance

-- | The variance contribution of an occurrence of one of the current declaration's own generics. A
-- declaration body only ever references its own generic parameters, so an id absent from the current
-- declaration contributes nothing (it should not arise).
occurrence :: VarianceContext -> GenericId -> Variance -> Map VarianceVariable Variance
occurrence context genericId sign =
  case Map.lookup genericId context.currentParameterNames of
    Just parameterName -> Map.singleton (context.currentName, parameterName) sign
    Nothing -> Map.empty

-- | The current variance of a nested declaration's parameter, defaulting to 'Bivariant' (unconstrained
-- / not yet seen). An unknown declaration likewise defaults to 'Bivariant'.
nestedVariance :: VarianceContext -> QualifiedName -> Text -> Variance
nestedVariance context qualifiedName parameterName =
  Map.findWithDefault Bivariant (qualifiedName, parameterName) context.estimate

-- | Collect each generic's variance contribution within a type, observed at the outer polarity
-- @sign@. Joined across every occurrence.
walkType :: VarianceContext -> Variance -> SemanticType -> Map VarianceVariable Variance
walkType context sign = \case
  SemanticTypeGeneric genericId -> occurrence context genericId sign
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

walkEffect :: VarianceContext -> Variance -> SemanticEffect -> Map VarianceVariable Variance
walkEffect context sign = \case
  SemanticEffectGeneric genericId -> occurrence context genericId sign
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
walkApplicationArguments :: VarianceContext -> Variance -> QualifiedName -> Map Text SemanticGenericArgument -> Map VarianceVariable Variance
walkApplicationArguments context sign qualifiedName arguments =
  mergeVariances
    [ walkArgument context (composeVariance sign (nestedVariance context qualifiedName parameterName)) argument
      | (parameterName, argument) <- Map.toList arguments
    ]

walkAttribute :: VarianceContext -> Variance -> SemanticAttribute -> Map VarianceVariable Variance
walkAttribute context sign = \case
  SemanticAttributeGeneric genericId -> occurrence context genericId sign
  SemanticAttributeUnion attributes -> mergeVariances (map (walkAttribute context sign) attributes)
  SemanticAttributePublic -> Map.empty
  SemanticAttributePrivate -> Map.empty

walkArgument :: VarianceContext -> Variance -> SemanticGenericArgument -> Map VarianceVariable Variance
walkArgument context sign = \case
  SemanticGenericArgumentType semanticType -> walkType context sign semanticType
  SemanticGenericArgumentEffect effect -> walkEffect context sign effect
  SemanticGenericArgumentAttribute attribute -> walkAttribute context sign attribute

-- | One shape whose generics' variance is being inferred: a data constructor (sole covariant root) or
-- a request, whose parameter object is covariant and return type contravariant (dual to a function,
-- because the performer supplies the parameter and consumes the return through the handler).
data VarianceShape = VarianceShape
  { qualifiedName :: QualifiedName,
    -- | This declaration's own generic ids → names, so the walk can key occurrences by variance variable.
    parameterNames :: Map GenericId Text,
    -- | The (rooted) sub-shapes contributing usage: each a (base polarity, type) pair.
    roots :: List (Variance, SemanticType)
  }

-- | One pass of the fixed point: recompute every variance variable from the current estimate. A
-- generic absent from its shape's usage is 'Bivariant'.
varianceIteration :: List VarianceShape -> Map VarianceVariable Variance -> Map VarianceVariable Variance
varianceIteration shapes currentEstimate =
  Map.fromList
    [ ((shape.qualifiedName, parameterName), Map.findWithDefault Bivariant (shape.qualifiedName, parameterName) usage)
      | shape <- shapes,
        let context = VarianceContext {currentName = shape.qualifiedName, currentParameterNames = shape.parameterNames, estimate = currentEstimate}
            usage = mergeVariances [walkType context sign root | (sign, root) <- shape.roots],
        parameterName <- Map.elems shape.parameterNames
    ]

-- | Iterate 'varianceIteration' to its (least) fixed point. The variance lattice is finite and the
-- step is monotone from the all-'Bivariant' bottom, so this terminates.
inferVariance :: List VarianceShape -> Map VarianceVariable Variance
inferVariance shapes = settle Map.empty
  where
    settle current =
      let next = varianceIteration shapes current
       in if next == current then current else settle next

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

-- | Re-stamp a declaration's parameter list with each parameter's inferred variance.
applyVariance :: Map VarianceVariable Variance -> QualifiedName -> List GenericParameterInfo -> List GenericParameterInfo
applyVariance variances qualifiedName =
  map (\parameter -> parameter {variance = Map.findWithDefault Bivariant (qualifiedName, parameter.name) variances})

-- | Run a normalization sub-computation, anchoring any type errors it emits at @sourceSpan@.
runNormalize :: NormalizerEnvironment -> SourceSpan -> Normalizer a -> (a, Diagnostics)
runNormalize environment sourceSpan action =
  let (result, _, errors) = runRWS action environment ()
   in (result, foldMap (diagnosticAt sourceSpan . CompilerErrorType) errors)

-- | Build the global type-level environment from every identified module (keyed by module name, so a
-- declaration's qualified name is the key joined with the declaration name). The data / request /
-- synonym declarations are filtered out of the identified ASTs, their annotated types elaborated and
-- normalized, variance inferred by a global fixed point, and synonyms expanded during elaboration.
buildEnvironment :: Map ModuleName (Module Identified) -> (TypeEnvironment, Diagnostics)
buildEnvironment modules = (environment, elaborateDiagnostics <> normalizeDiagnostics)
  where
    (collectedData, collectedRequests, collectedSynonyms) = collectDeclarations modules

    -- Stage 2: the elaborator's signature registry, then elaborate every declaration's annotated
    -- types in one run (sharing the registry, accumulating diagnostics).
    elaborateContext =
      emptyContext
        (Map.fromList [(item.qualifiedName, item.genericParameters) | item <- collectedData])
        (Map.fromList [(item.qualifiedName, item.genericParameters) | item <- collectedRequests])
        ( Map.fromList
            [ (item.qualifiedName, SynonymSignature {genericParameters = item.genericParameters, body = item.body})
              | item <- collectedSynonyms
            ]
        )

    ((dataShapesSemantic, requestShapesSemantic, synonymShapesSemantic), elaborateDiagnostics) =
      runElaborate elaborateContext $ do
        dataShapes <- traverse (\item -> (,) item <$> constructorObject item.parameters) collectedData
        requestShapes <-
          traverse
            ( \item -> do
                parameterObject <- constructorObject item.parameters
                returnType <- elaborateAsType item.returnType
                pure (item, (parameterObject, returnType))
            )
            collectedRequests
        synonymShapes <- traverse (\item -> (,) item <$> elaborate item.body) collectedSynonyms
        pure (dataShapes, requestShapes, synonymShapes)

    -- Stage 3: infer variance over the elaborated (pre-normalized) shapes.
    varianceShapes =
      [ VarianceShape {qualifiedName = item.qualifiedName, parameterNames = namesByGenericId item.genericParameters, roots = [(Covariant, constructor)]}
        | (item, constructor) <- dataShapesSemantic
      ]
        <> [ VarianceShape {qualifiedName = item.qualifiedName, parameterNames = namesByGenericId item.genericParameters, roots = [(Covariant, parameterObject), (Contravariant, returnType)]}
             | (item, (parameterObject, returnType)) <- requestShapesSemantic
           ]

    variances = inferVariance varianceShapes

    -- Stage 4: stamp the inferred variance onto each declaration's parameters once, then normalize
    -- the elaborated shapes. The normalizer reads only the parameter lists (for arity / variance),
    -- never the constructor, so a placeholder constructor is fine.
    dataStamped = [(item, applyVariance variances item.qualifiedName item.genericParameters, semantic) | (item, semantic) <- dataShapesSemantic]
    requestStamped = [(item, applyVariance variances item.qualifiedName item.genericParameters, shape) | (item, shape) <- requestShapesSemantic]
    synonymStamped = [(item, applyVariance variances item.qualifiedName item.genericParameters, maybeSemantic) | (item, maybeSemantic) <- synonymShapesSemantic]

    normalizerEnvironment =
      NormalizerEnvironment
        { dataEnvironment =
            Map.fromList
              [(item.qualifiedName, DataInfo {name = item.qualifiedName, genericParameters = parameters, constructor = bottomType}) | (item, parameters, _) <- dataStamped],
          requestEnvironment =
            Map.fromList
              [(item.qualifiedName, RequestInfo {name = item.qualifiedName, genericParameters = parameters, request = (bottomType, bottomType)}) | (item, parameters, _) <- requestStamped],
          genericBoundEnvironment = mempty,
          world = bottomAttribute
        }

    (dataInfos, dataNormalizeDiagnostics) =
      unzipDiagnostics
        [ let (constructor, diagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType semantic)
           in (DataInfo {name = item.qualifiedName, genericParameters = parameters, constructor = constructor}, diagnostics)
          | (item, parameters, semantic) <- dataStamped
        ]

    (requestInfos, requestNormalizeDiagnostics) =
      unzipDiagnostics
        [ let (parameterType, parameterDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType parameterObject)
              (returnType, returnDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType returnSemantic)
           in ( RequestInfo {name = item.qualifiedName, genericParameters = parameters, request = (parameterType, returnType)},
                parameterDiagnostics <> returnDiagnostics
              )
          | (item, parameters, (parameterObject, returnSemantic)) <- requestStamped
        ]

    (synonymInfos, synonymNormalizeDiagnostics) =
      unzipDiagnostics
        [ let semantic = fromMaybe (SemanticGenericArgumentType SemanticTypeNever) maybeSemantic
              (definition, diagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeGenericArgument semantic)
           in (SynonymInfo {name = item.qualifiedName, genericParameters = parameters, definition = definition}, diagnostics)
          | (item, parameters, maybeSemantic) <- synonymStamped
        ]

    normalizeDiagnostics = dataNormalizeDiagnostics <> requestNormalizeDiagnostics <> synonymNormalizeDiagnostics

    environment =
      TypeEnvironment
        { dataEnvironment = Map.fromList [(info.name, info) | info <- dataInfos],
          requestEnvironment = Map.fromList [(info.name, info) | info <- requestInfos],
          synonymEnvironment = Map.fromList [(info.name, info) | info <- synonymInfos]
        }

unzipDiagnostics :: List (a, Diagnostics) -> (List a, Diagnostics)
unzipDiagnostics items = (map fst items, foldMap snd items)
