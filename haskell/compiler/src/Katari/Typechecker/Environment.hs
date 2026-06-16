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
import Katari.Data.Environment (DataEnvironment, DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestEnvironment, RequestInformation (..), SynonymEnvironment, SynonymInformation (..), namesByGenericId, parameterKinds)
import Katari.Data.Id (GenericId, TypeResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.NormalizedType (NormalizedKindedType (..), bottomAttribute, bottomType)
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
  { dataEnvironment :: DataEnvironment,
    requestEnvironment :: RequestEnvironment,
    synonymEnvironment :: SynonymEnvironment
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

-- | The 'GenericParameterInformation' of one declared generic, paired with its (still syntactic) @extends@
-- bound if it has one. Both 'variance' ('Bivariant') and 'upperBound' ('Nothing') start as
-- placeholders that the env-build's later stages fill (variance by the fixed point, the bound by
-- elaborating + normalizing it). 'Nothing' for the whole result if the identifier left the parameter
-- unresolved, which should not happen for a declaration's own generics.
collectGenericParameter :: GenericParameter Identified -> Maybe ((Text, GenericParameterInformation), Maybe (GenericId, SyntacticTypeExpression Identified))
collectGenericParameter parameter = case parameter.typeReference.resolution of
  Just (TypeResolutionGeneric genericId) ->
    Just
      ( (parameter.name, GenericParameterInformation {genericId = genericId, kind = parameter.kind, variance = Bivariant, upperBound = Nothing}),
        (,) genericId <$> parameter.upperBound
      )
  _ -> Nothing

-- | A declaration's collected generic parameters (in declaration order, by name) and the syntactic
-- @extends@ bounds among them, keyed by generic id. The bounds are elaborated + normalized and
-- stamped back onto the parameters' 'upperBound' once the normalizer environment is available.
collectGenericParameters :: List (GenericParameter Identified) -> (GenericParameters, Map GenericId (SyntacticTypeExpression Identified))
collectGenericParameters parameters =
  let collected = mapMaybe collectGenericParameter parameters
      named = map fst collected
   in ( GenericParameters {parameterNames = map fst named, parameterInformation = Map.fromList named},
        Map.fromList (mapMaybe snd collected)
      )

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
        let (genericParameters, genericBounds) = collectGenericParameters declaration.genericParameters
         in ( [ CollectedData
                  { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
                    genericParameters = genericParameters,
                    genericBounds = genericBounds,
                    parameters = declaration.parameters,
                    sourceSpan = declaration.sourceSpan
                  }
              ],
              [],
              []
            )
      DeclarationRequest declaration ->
        let (genericParameters, genericBounds) = collectGenericParameters declaration.genericParameters
         in ( [],
              [ CollectedRequest
                  { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
                    genericParameters = genericParameters,
                    genericBounds = genericBounds,
                    parameters = declaration.parameters,
                    returnType = declaration.returnType,
                    sourceSpan = declaration.sourceSpan
                  }
              ],
              []
            )
      DeclarationTypeSynonym declaration ->
        let (genericParameters, genericBounds) = collectGenericParameters declaration.genericParameters
         in ( [],
              [],
              [ CollectedSynonym
                  { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
                    genericParameters = genericParameters,
                    genericBounds = genericBounds,
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

-- | Re-stamp a declaration's parameters with each parameter's inferred variance (keyed by the
-- parameter name, which is its key in 'parameterInformation'). Rebuilt rather than record-updated
-- because @variance@ / @upperBound@ are shared field names, making a duplicate-field update ambiguous.
applyVariance :: Map VarianceVariable Variance -> QualifiedName -> GenericParameters -> GenericParameters
applyVariance variances qualifiedName parameters =
  GenericParameters
    { parameterNames = parameters.parameterNames,
      parameterInformation =
        Map.mapWithKey
          ( \name parameter ->
              GenericParameterInformation
                { genericId = parameter.genericId,
                  kind = parameter.kind,
                  variance = Map.findWithDefault Bivariant (qualifiedName, name) variances,
                  upperBound = parameter.upperBound
                }
          )
          parameters.parameterInformation
    }

-- | Stamp a parameter's normalized @extends@ upper bound (looked up by its generic id) onto its
-- 'upperBound'; an unbounded parameter keeps 'Nothing'. Rebuilt rather than record-updated because
-- @upperBound@ is also a field of the AST 'GenericParameter', making a record update an ambiguous
-- (and now deprecated) duplicate-field update.
stampBound :: Map GenericId NormalizedKindedType -> GenericParameterInformation -> GenericParameterInformation
stampBound bounds parameter =
  GenericParameterInformation
    { genericId = parameter.genericId,
      kind = parameter.kind,
      variance = parameter.variance,
      upperBound = Map.lookup parameter.genericId bounds
    }

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
        genericKinds

    -- The declared kind of every generic in the program, by id (ids are globally unique once stamped
    -- with their module), so the elaborator can wrap a generic leaf at the kind its declaration gave it.
    genericKinds =
      Map.unions $
        [parameterKinds item.genericParameters | item <- collectedData]
          <> [parameterKinds item.genericParameters | item <- collectedRequests]
          <> [parameterKinds item.genericParameters | item <- collectedSynonyms]

    -- Every declaration's syntactic @extends@ bounds, keyed by declaration then generic id, so the
    -- elaborate / normalize stages process them alongside the constructor / request / definition shapes.
    allGenericBounds =
      Map.fromList
        ( [(item.qualifiedName, item.genericBounds) | item <- collectedData]
            <> [(item.qualifiedName, item.genericBounds) | item <- collectedRequests]
            <> [(item.qualifiedName, item.genericBounds) | item <- collectedSynonyms]
        )

    ((dataShapesSemantic, requestShapesSemantic, synonymShapesSemantic, boundShapesSemantic), elaborateDiagnostics) =
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
        -- A bound is kind-agnostic (a type / effect / attribute), so it elaborates with 'elaborate'
        -- (the same kind-agnostic elaborator synonyms use), not 'elaborateAsType'.
        boundShapes <- traverse (traverse elaborate) allGenericBounds
        pure (dataShapes, requestShapes, synonymShapes, boundShapes)

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
              [(item.qualifiedName, DataInformation {name = item.qualifiedName, genericParameters = parameters, constructor = bottomType}) | (item, parameters, _) <- dataStamped],
          requestEnvironment =
            Map.fromList
              [(item.qualifiedName, RequestInformation {name = item.qualifiedName, genericParameters = parameters, request = (bottomType, bottomType)}) | (item, parameters, _) <- requestStamped],
          -- Normalization never resolves a generic's bound (that is a subtyping-time concern), so no
          -- in-scope generics are needed to normalize the declarations themselves.
          genericsInScope = mempty,
          world = bottomAttribute
        }

    (dataInfos, dataNormalizeDiagnostics) =
      unzipDiagnostics
        [ let (constructor, constructorDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType semantic)
              (boundedParameters, boundDiagnostics) = stampBoundsAt item.qualifiedName item.sourceSpan parameters
           in (DataInformation {name = item.qualifiedName, genericParameters = boundedParameters, constructor = constructor}, constructorDiagnostics <> boundDiagnostics)
          | (item, parameters, semantic) <- dataStamped
        ]

    (requestInfos, requestNormalizeDiagnostics) =
      unzipDiagnostics
        [ let (parameterType, parameterDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType parameterObject)
              (returnType, returnDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeType returnSemantic)
              (boundedParameters, boundDiagnostics) = stampBoundsAt item.qualifiedName item.sourceSpan parameters
           in ( RequestInformation {name = item.qualifiedName, genericParameters = boundedParameters, request = (parameterType, returnType)},
                parameterDiagnostics <> returnDiagnostics <> boundDiagnostics
              )
          | (item, parameters, (parameterObject, returnSemantic)) <- requestStamped
        ]

    (synonymInfos, synonymNormalizeDiagnostics) =
      unzipDiagnostics
        [ let semantic = fromMaybe (SemanticGenericArgumentType SemanticTypeNever) maybeSemantic
              (definition, definitionDiagnostics) = runNormalize normalizerEnvironment item.sourceSpan (normalizeGenericArgument semantic)
              (boundedParameters, boundDiagnostics) = stampBoundsAt item.qualifiedName item.sourceSpan parameters
           in (SynonymInformation {name = item.qualifiedName, genericParameters = boundedParameters, definition = definition}, definitionDiagnostics <> boundDiagnostics)
          | (item, parameters, maybeSemantic) <- synonymStamped
        ]

    -- Normalize a declaration's collected @extends@ bounds and stamp each onto its parameter's
    -- 'upperBound' (the parameters already carry their inferred variance from 'applyVariance'); an
    -- unbounded parameter keeps 'Nothing'. The bounds normalize in the same environment as the rest of
    -- the declaration so they see the same data / request / synonym types.
    stampBoundsAt qualifiedName sourceSpan parameters =
      let -- A bound that failed to elaborate is 'Nothing' (its diagnostic was already emitted at the
          -- elaborate stage); drop those, so an unresolved bound leaves its parameter unbounded.
          semanticBounds = Map.mapMaybe id (Map.findWithDefault mempty qualifiedName boundShapesSemantic)
          (normalizedBounds, diagnostics) = runNormalize normalizerEnvironment sourceSpan (traverse normalizeGenericArgument semanticBounds)
       in ( GenericParameters {parameterNames = parameters.parameterNames, parameterInformation = stampBound normalizedBounds <$> parameters.parameterInformation},
            diagnostics
          )

    normalizeDiagnostics = dataNormalizeDiagnostics <> requestNormalizeDiagnostics <> synonymNormalizeDiagnostics

    environment =
      TypeEnvironment
        { dataEnvironment = Map.fromList [(info.name, info) | info <- dataInfos],
          requestEnvironment = Map.fromList [(info.name, info) | info <- requestInfos],
          synonymEnvironment = Map.fromList [(info.name, info) | info <- synonymInfos]
        }

unzipDiagnostics :: List (a, Diagnostics) -> (List a, Diagnostics)
unzipDiagnostics items = (map fst items, foldMap snd items)
