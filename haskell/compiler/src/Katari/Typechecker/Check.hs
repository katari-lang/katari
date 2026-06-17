-- | Bidirectional checking that produces the 'Typed' AST. Every walker returns the corresponding
-- typed node alongside the normalized type it computed; the 'typeOf' field on every typed
-- expression / pattern is the denormalized semantic type of that node.
--
-- The public entry points are 'synthExpression' / 'checkExpression' / 'synthBlock' / 'checkBlock' /
-- 'walkStatements' / 'checkPattern' / 'synthAgent' / 'prepareAgent' / 'seedAgentType' /
-- 'checkAgentBody'.
-- Convenience wrappers ('synthExpressionType', 'synthAgentType') drop the typed AST and yield just
-- the normalized type — used by tests that only need the type-level result.
module Katari.Typechecker.Check where

import Control.Monad (foldM, unless, when, zipWithM)
import Control.Monad.RWS.Class (asks, tell)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestInformation (..), Scheme (..), monoScheme)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId, LocalVariableId, TypeResolution (..), VariableResolution (..))
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName (..), renderQualifiedName)
import Katari.Data.SemanticType (SemanticType)
import Katari.Data.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Diagnostics (diagnosticAt)
import Katari.Error
  ( ApplicationArityErrorInfo (..),
    CompilerError (..),
    ExpectedShapeErrorInfo (..),
    MalformedTypeErrorInfo (..),
    MisplacedJumpErrorInfo (..),
    MissingAnnotationErrorInfo (..),
    TypeError (..),
  )
import Katari.Panic (panic)
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment (..),
    ForContext (..),
    HandleContext (..),
    JumpContexts (..),
    getEffectAccumulator,
    getForBodyAccumulator,
    pushForContext,
    pushHandleContext,
    runElaborator,
    runNormalizer,
    setEffectAccumulator,
    setForBodyAccumulator,
    withEffectInference,
    withForInference,
    withGeneric,
    withLocal,
    withParameters,
    withReturnTarget,
    withWorld,
  )
import Katari.Typechecker.Elaborate (elaborateAsAttribute, elaborateAsEffect, elaborateAsType, schemeVariableFor)
import Katari.Typechecker.Environment (TypeEnvironment (..), collectGenericParameters)
import Katari.Typechecker.Normalizer (denormalize, intersect, joinAttribute, normalizeAttribute, normalizeEffect, normalizeGenericArgument, normalizeType, substituteType, subtype, union)

------------------------------------------------------------------------------------------------
-- Bidirectional entry points
------------------------------------------------------------------------------------------------

-- | Synthesize an expression's normalized type /and/ build its typed AST counterpart. Unsupported
-- expression kinds emit a diagnostic and synthesize to 'bottomType', so the surrounding context
-- still produces a well-formed shape.
synthExpression :: Expression Identified -> Checker (Expression Typed, NormalizedType)
synthExpression = \case
  ExpressionLiteral expression -> synthLiteralExpression expression
  ExpressionVariable expression -> synthVariableExpression expression
  ExpressionQualifiedReference expression -> synthQualifiedReferenceExpression expression
  ExpressionTuple expression -> synthTupleExpression expression
  ExpressionRecord expression -> synthRecordExpression expression
  ExpressionCall expression -> synthCallExpression expression
  ExpressionBinaryOperator expression -> synthBinaryExpression expression
  ExpressionUnaryOperator expression -> synthUnaryExpression expression
  ExpressionIf expression -> synthIfExpression expression
  ExpressionMatch expression -> synthMatchExpression expression
  ExpressionFor expression -> synthForExpression expression
  ExpressionHandler expression -> synthHandlerExpression expression
  ExpressionBlock expression -> synthBlockExpression expression
  ExpressionFieldAccess expression -> synthFieldAccessExpression expression
  ExpressionTypeApplication expression -> synthTypeApplicationExpression expression
  ExpressionTemplate expression -> synthTemplateExpression expression

-- | Convenience for callers (tests) that only want the normalized type.
synthExpressionType :: Expression Identified -> Checker NormalizedType
synthExpressionType = fmap snd . synthExpression

-- | Check an expression against an expected type; return its typed AST. @synth then subtype@.
checkExpression :: Expression Identified -> NormalizedType -> Checker (Expression Typed)
checkExpression expression expected = do
  (typed, actual) <- synthExpression expression
  runNormalizer (sourceSpanOf expression) (subtype actual expected)
  pure typed

------------------------------------------------------------------------------------------------
-- Blocks
------------------------------------------------------------------------------------------------

-- | A block's type is its return expression's type, or @null@ if absent. The typed block carries
-- the typed statements and the typed return expression.
synthBlock :: Block Identified -> Checker (Block Typed, NormalizedType)
synthBlock block = do
  ((typedReturn, returnType), typedStatements) <-
    walkStatements block.statements $ case block.returnExpression of
      Just expression -> do
        (typedExpr, nt) <- synthExpression expression
        pure (Just typedExpr, nt)
      Nothing -> pure (Nothing, nullType)
  pure
    ( Block
        { statements = typedStatements,
          returnExpression = typedReturn,
          sourceSpan = block.sourceSpan
        },
      returnType
    )

checkBlock :: Block Identified -> NormalizedType -> Checker (Block Typed)
checkBlock block expected = do
  (typedReturn, typedStatements) <-
    walkStatements block.statements $ case block.returnExpression of
      Just expression -> Just <$> checkExpression expression expected
      Nothing -> do
        runNormalizer block.sourceSpan (subtype nullType expected)
        pure Nothing
  pure
    Block
      { statements = typedStatements,
        returnExpression = typedReturn,
        sourceSpan = block.sourceSpan
      }

------------------------------------------------------------------------------------------------
-- Statements
--
-- 'walkStatements' is the CPS-style walker: it accepts a continuation that produces the block's
-- tail value (e.g. the trailing return expression's type-check result) in the extended scope,
-- and returns @(continuation result, typed statements in source order)@.
------------------------------------------------------------------------------------------------

walkStatements ::
  List (Statement Identified) ->
  Checker a ->
  Checker (a, List (Statement Typed))
walkStatements [] continuation = do
  result <- continuation
  pure (result, [])
walkStatements (statement : rest) continuation = case statement of
  StatementLet letStmt -> runLetStatement letStmt rest continuation
  StatementExpression expression -> do
    (typedExpr, _) <- synthExpression expression
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementExpression typedExpr : restTyped)
  StatementAgent agentDeclaration -> runLocalAgentStatement agentDeclaration rest continuation
  StatementUse useStmt -> do
    typedUse <- handleUseStatement useStmt
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementUse typedUse : restTyped)
  StatementReturn returnStmt -> do
    typedReturn <- checkReturnStatement returnStmt
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementReturn typedReturn : restTyped)
  StatementForNext forNextStmt -> do
    typedStmt <- checkForNextStatement forNextStmt
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementForNext typedStmt : restTyped)
  StatementForBreak forBreakStmt -> do
    typedStmt <- checkForBreakStatement forBreakStmt
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementForBreak typedStmt : restTyped)
  StatementBreak breakStmt -> do
    typedStmt <- checkBreakStatement breakStmt
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementBreak typedStmt : restTyped)
  StatementNext nextStmt -> do
    typedStmt <- checkNextStatement nextStmt
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementNext typedStmt : restTyped)
  StatementError s -> do
    (result, restTyped) <- walkStatements rest continuation
    pure (result, StatementError s : restTyped)

-- | A @let@ binding: compute the value's type (against an annotation if present), bind, walk the
-- rest in the extended scope, and produce the typed let statement.
runLetStatement ::
  LetStatement Identified ->
  List (Statement Identified) ->
  Checker a ->
  Checker (a, List (Statement Typed))
runLetStatement letStmt rest continuation = case letStmt.pattern of
  PatternVariable variablePattern -> case variablePattern.variableReference.resolution of
    Just (VariableResolutionLocalVariable localId) ->
      case variablePattern.typeAnnotation of
        Just annotation -> do
          annotatedType <- elaborateAndNormalizeType annotation
          typedValue <- checkExpression letStmt.value annotatedType
          (typedPattern, _, _) <- checkPattern letStmt.pattern annotatedType
          (result, restTyped) <-
            withLocal localId (monoScheme annotatedType) $
              walkStatements rest continuation
          let typedLetStmt =
                LetStatement
                  { pattern = typedPattern,
                    value = typedValue,
                    sourceSpan = letStmt.sourceSpan
                  }
          pure (result, StatementLet typedLetStmt : restTyped)
        Nothing -> do
          (typedValue, bindingType) <- synthExpression letStmt.value
          (typedPattern, _, _) <- checkPattern letStmt.pattern bindingType
          (result, restTyped) <-
            withLocal localId (monoScheme bindingType) $
              walkStatements rest continuation
          let typedLetStmt =
                LetStatement
                  { pattern = typedPattern,
                    value = typedValue,
                    sourceSpan = letStmt.sourceSpan
                  }
          pure (result, StatementLet typedLetStmt : restTyped)
    _ -> panic "runLetStatement: let-bound variable is not resolved to a local"
  otherPattern -> do
    (typedValue, valueType) <- synthExpression letStmt.value
    (typedPattern, _, bindings) <- checkPattern otherPattern valueType
    (result, restTyped) <- withParameters bindings (walkStatements rest continuation)
    let typedLetStmt =
          LetStatement
            { pattern = typedPattern,
              value = typedValue,
              sourceSpan = letStmt.sourceSpan
            }
    pure (result, StatementLet typedLetStmt : restTyped)

-- | A local agent declaration: bind its type as a local for the remainder of the block.
runLocalAgentStatement ::
  AgentDeclaration Identified ->
  List (Statement Identified) ->
  Checker a ->
  Checker (a, List (Statement Typed))
runLocalAgentStatement declaration rest continuation = case declaration.variableReference.resolution of
  Just (VariableResolutionLocalVariable localId) -> do
    -- A local agent binds its full scheme (its generics included), so explicit application works on
    -- it exactly as on a top-level value.
    (typedDeclaration, scheme) <- synthAgent declaration
    (result, restTyped) <-
      withLocal localId scheme $
        walkStatements rest continuation
    pure (result, StatementAgent typedDeclaration : restTyped)
  _ -> panic "runLocalAgentStatement: local agent is not resolved to a local"

------------------------------------------------------------------------------------------------
-- @use@ statement
--
-- @{ stmts_before; let x : A = use h; stmts_after; return e }@ is typed as if it desugared into
-- @{ stmts_before; h(continuation = agent({value: A}) -> R with E' { stmts_after; return e }) }@.
-- Per Q1, @x@'s annotation is required, R is the enclosing return target, and E' is the
-- continuation body's /inferred/ effect (so the subtype check against the provider's expected
-- continuation effect enforces "body effects ⊆ what the handler expects").
------------------------------------------------------------------------------------------------

handleUseStatement :: UseStatement Identified -> Checker (UseStatement Typed)
handleUseStatement useStmt = do
  -- The binder declares the continuation's value type A (required per Q1); without a binder the
  -- continuation receives null.
  (bindingType, typedBinder, bindings) <- case useStmt.binder of
    Nothing -> pure (nullType, Nothing, [])
    Just patternNode -> do
      (declaredType, typedPattern, binderBindings) <-
        checkAnnotatedBinder "`use` binder requires an explicit type annotation" patternNode
      pure (declaredType, Just typedPattern, binderBindings)
  contexts <- asks (.jumps)
  let resultType = fromMaybe topType contexts.returnTarget
  (inferredContinuationEffect, typedBody) <-
    withEffectInference
      $ withParameters bindings
        . withReturnTarget resultType
      $ checkBlock useStmt.body resultType
  let continuationParam = namedObjectType [("value", bindingType)]
      continuationAgent =
        layeredOf
          neverLayer
            { functionLayer =
                Just
                  NormalizedFunction
                    { argumentType = continuationParam,
                      returnType = resultType,
                      effect = inferredContinuationEffect
                    }
            }
      providerExpectedArgument = namedObjectType [("continuation", continuationAgent)]
  (typedProvider, providerType) <- synthExpression useStmt.provider
  case extractFunction providerType of
    Just (_, function) -> do
      runNormalizer useStmt.sourceSpan (subtype providerExpectedArgument function.argumentType)
      emitEffect useStmt.sourceSpan function.effect
    Nothing -> reportExpectedShape useStmt.sourceSpan "a callable agent" providerType
  pure
    UseStatement
      { binder = typedBinder,
        provider = typedProvider,
        body = typedBody,
        sourceSpan = useStmt.sourceSpan
      }

------------------------------------------------------------------------------------------------
-- Per-expression synthesis (produces Typed AST + NormalizedType)
------------------------------------------------------------------------------------------------

synthLiteralExpression :: LiteralExpression Identified -> Checker (Expression Typed, NormalizedType)
synthLiteralExpression expression = do
  let nt = synthLiteralValue expression.value
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionLiteral
        LiteralExpression
          { value = expression.value,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthLiteralValue :: LiteralValue -> NormalizedType
synthLiteralValue = \case
  LiteralValueInteger _ -> integerType
  LiteralValueNumber _ -> numberType
  LiteralValueString _ -> stringType
  LiteralValueBoolean _ -> booleanType
  LiteralValueNull -> nullType

synthVariableExpression :: VariableExpression Identified -> Checker (Expression Typed, NormalizedType)
synthVariableExpression expression = do
  scheme <- lookupScheme expression.sourceSpan expression.variableReference.resolution
  nt <- instantiateBare expression.sourceSpan scheme
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionVariable
        VariableExpression
          { name = expression.name,
            variableReference = retagReference expression.variableReference,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthQualifiedReferenceExpression ::
  QualifiedReferenceExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthQualifiedReferenceExpression expression = do
  scheme <- lookupScheme expression.sourceSpan expression.variableReference.resolution
  nt <- instantiateBare expression.sourceSpan scheme
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionQualifiedReference
        QualifiedReferenceExpression
          { moduleQualifier = retagModuleQualifier expression.moduleQualifier,
            name = expression.name,
            variableReference = retagReference expression.variableReference,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthTupleExpression :: TupleExpression Identified -> Checker (Expression Typed, NormalizedType)
synthTupleExpression expression = do
  results <- traverse synthExpression expression.elements
  let (typedElements, elementTypes) = unzip results
      nt =
        layeredOf
          neverLayer
            { sequenceLayer = Just NormalizedSequence {items = elementTypes, rest = nullType}
            }
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionTuple
        TupleExpression
          { parallel = expression.parallel,
            elements = typedElements,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthRecordExpression :: RecordExpression Identified -> Checker (Expression Typed, NormalizedType)
synthRecordExpression expression = do
  (typedEntries, fields) <- foldM combineEntry ([], Map.empty) expression.entries
  let nt =
        layeredOf
          neverLayer
            { objectLayer = Just NormalizedObject {fields = fields, rest = unknownType}
            }
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionRecord
        RecordExpression
          { entries = reverse typedEntries,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )
  where
    combineEntry (typedAcc, fieldsAcc) entry = do
      (typedValue, fieldType) <- synthExpression entry.value
      let typedEntry =
            RecordEntry
              { name = entry.name,
                value = typedValue,
                sourceSpan = entry.sourceSpan
              }
          newFields =
            Map.insert
              entry.name
              NormalizedFieldInformation {normalizedType = fieldType, optional = False}
              fieldsAcc
      pure (typedEntry : typedAcc, newFields)

synthIfExpression :: IfExpression Identified -> Checker (Expression Typed, NormalizedType)
synthIfExpression expression = do
  typedCondition <- checkExpression expression.condition booleanType
  (typedThen, thenType) <- synthBlock expression.thenBlock
  (typedElse, elseType) <- case expression.elseBlock of
    Just block -> do
      (b, t) <- synthBlock block
      pure (Just b, t)
    Nothing -> pure (Nothing, nullType)
  nt <- runNormalizer expression.sourceSpan (union thenType elseType)
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionIf
        IfExpression
          { condition = typedCondition,
            thenBlock = typedThen,
            elseBlock = typedElse,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthBlockExpression :: BlockExpression Identified -> Checker (Expression Typed, NormalizedType)
synthBlockExpression expression = do
  (typedBlock, nt) <- synthBlock expression.block
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionBlock
        BlockExpression
          { block = typedBlock,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthFieldAccessExpression ::
  FieldAccessExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthFieldAccessExpression expression = do
  (typedObject, objectType) <- synthExpression expression.object
  nt <- case objectType.baseType of
    NormalizedBaseTypeLayered layer | Just normalizedObject <- layer.objectLayer ->
      case Map.lookup expression.fieldName normalizedObject.fields of
        Just field -> pure field.normalizedType
        Nothing -> pure normalizedObject.rest
    _ -> do
      reportExpectedShape expression.sourceSpan "an object" objectType
      pure bottomType
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionFieldAccess
        FieldAccessExpression
          { object = typedObject,
            fieldName = expression.fieldName,
            labelReference = retagReference expression.labelReference,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

synthTypeApplicationExpression ::
  TypeApplicationExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthTypeApplicationExpression expression = do
  (typedCallee, scheme) <- synthApplicationCallee expression.callee
  -- Generic application is by position: the explicit arguments fill the callee's quantified
  -- parameters in declaration order ('buildGenericSubstitution' maps position -> name -> id), and
  -- 'substituteType' replaces those ids in the body, yielding a generics-free instantiation.
  substitution <- buildGenericSubstitution expression.sourceSpan "value" scheme.genericParameters expression.typeArguments
  instantiated <- runNormalizer expression.sourceSpan (substituteType substitution scheme.valueType)
  semantic <- denormalizeAt expression.sourceSpan instantiated
  pure
    ( ExpressionTypeApplication
        TypeApplicationExpression
          { callee = typedCallee,
            typeArguments = retagSyntacticTypeExpression <$> expression.typeArguments,
            instantiation = mempty,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      instantiated
    )

-- | The callee of a generic application paired with its (uninstantiated) scheme. A direct value
-- reference contributes its full scheme — the only source of a generic value — so its generics are
-- not flagged as an unapplied generic reference here (that check is 'instantiateBare', for bare
-- uses); any other callee is non-generic, and supplying type arguments to it is an arity error in
-- 'buildGenericSubstitution'.
synthApplicationCallee :: Expression Identified -> Checker (Expression Typed, Scheme)
synthApplicationCallee = \case
  ExpressionVariable variable -> do
    scheme <- lookupScheme variable.sourceSpan variable.variableReference.resolution
    semantic <- denormalizeAt variable.sourceSpan scheme.valueType
    pure
      ( ExpressionVariable
          VariableExpression
            { name = variable.name,
              variableReference = retagReference variable.variableReference,
              sourceSpan = variable.sourceSpan,
              typeOf = semantic
            },
        scheme
      )
  ExpressionQualifiedReference reference -> do
    scheme <- lookupScheme reference.sourceSpan reference.variableReference.resolution
    semantic <- denormalizeAt reference.sourceSpan scheme.valueType
    pure
      ( ExpressionQualifiedReference
          QualifiedReferenceExpression
            { moduleQualifier = retagModuleQualifier reference.moduleQualifier,
              name = reference.name,
              variableReference = retagReference reference.variableReference,
              sourceSpan = reference.sourceSpan,
              typeOf = semantic
            },
        scheme
      )
  other -> do
    (typedCallee, calleeType) <- synthExpression other
    pure (typedCallee, monoScheme calleeType)

synthTemplateExpression :: TemplateExpression Identified -> Checker (Expression Typed, NormalizedType)
synthTemplateExpression expression = do
  typedElements <- traverse synthElement expression.elements
  let nt = stringType
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionTemplate
        TemplateExpression
          { elements = typedElements,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )
  where
    synthElement = \case
      TemplateElementString stringElement ->
        pure (TemplateElementString stringElement)
      TemplateElementExpression element -> do
        (typedValue, _) <- synthExpression element.value
        pure
          ( TemplateElementExpression
              TemplateExpressionElement
                { value = typedValue,
                  sourceSpan = element.sourceSpan
                }
          )

------------------------------------------------------------------------------------------------
-- Calls (with pure-call lifting and the non-pure @T <: W@ rule)
------------------------------------------------------------------------------------------------

synthCallExpression :: CallExpression Identified -> Checker (Expression Typed, NormalizedType)
synthCallExpression expression = do
  (typedCallee, calleeType) <- synthExpression expression.callee
  case extractFunction calleeType of
    Nothing -> do
      reportExpectedShape expression.sourceSpan "a callable agent" calleeType
      typedArgs <- traverse retagCallArgument expression.arguments
      semantic <- denormalizeAt expression.sourceSpan bottomType
      pure
        ( ExpressionCall
            CallExpression
              { callee = typedCallee,
                arguments = typedArgs,
                sourceSpan = expression.sourceSpan,
                typeOf = semantic
              },
          bottomType
        )
    Just (functionAttribute, function) -> do
      (typedArgs, argumentType, liftAttribute) <- synthCallArguments expression.arguments
      let pureCall = isPureEffect function.effect
          (effectiveParameter, effectiveReturn) =
            if pureCall
              then
                ( liftByAttribute liftAttribute function.argumentType,
                  liftByAttribute liftAttribute function.returnType
                )
              else (function.argumentType, function.returnType)
      runNormalizer expression.sourceSpan (subtype argumentType effectiveParameter)
      unless pureCall $ do
        runNormalizer expression.sourceSpan (subtype functionAttribute bottomAttribute)
        emitEffect expression.sourceSpan function.effect
      semantic <- denormalizeAt expression.sourceSpan effectiveReturn
      pure
        ( ExpressionCall
            CallExpression
              { callee = typedCallee,
                arguments = typedArgs,
                sourceSpan = expression.sourceSpan,
                typeOf = semantic
              },
          effectiveReturn
        )

-- | Retag a call argument when no typing is performed (the non-callable callee fallback).
retagCallArgument :: CallArgument Identified -> Checker (CallArgument Typed)
retagCallArgument argument = do
  (typedValue, _) <- synthExpression argument.value
  pure
    CallArgument
      { name = argument.name,
        labelReference = retagReference argument.labelReference,
        value = typedValue,
        sourceSpan = argument.sourceSpan
      }

extractFunction :: NormalizedType -> Maybe (NormalizedAttribute, NormalizedFunction)
extractFunction normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeLayered layer
    | Just function <- layer.functionLayer,
      isLoneFunctionLayer layer,
      Set.null normalizedType.generics ->
        Just (normalizedType.attribute, function)
  _ -> Nothing
  where
    isLoneFunctionLayer layer =
      not layer.nullLayer
        && layer.numberLayer == NumberSlotAbsent
        && not layer.stringLayer
        && not layer.booleanLayer
        && not layer.fileLayer
        && layerSequenceEmpty layer
        && layerObjectEmpty layer
        && Map.null layer.dataLayer
    layerSequenceEmpty layer = case layer.sequenceLayer of
      Nothing -> True
      Just _ -> False
    layerObjectEmpty layer = case layer.objectLayer of
      Nothing -> True
      Just _ -> False

synthCallArguments ::
  List (CallArgument Identified) ->
  Checker (List (CallArgument Typed), NormalizedType, NormalizedAttribute)
synthCallArguments arguments = do
  entries <- traverse synthEntry arguments
  let typedArguments = [typedArg | (typedArg, _, _) <- entries]
      object =
        layeredOf
          neverLayer
            { objectLayer =
                Just
                  NormalizedObject
                    { fields =
                        Map.fromList
                          [ (name, NormalizedFieldInformation {normalizedType = normalizedType, optional = False})
                            | (_, name, normalizedType) <- entries
                          ],
                      rest = unknownType
                    }
            }
      liftAmount =
        foldr
          joinAttribute
          bottomAttribute
          [collectAttributeUnion normalizedType | (_, _, normalizedType) <- entries]
  pure (typedArguments, object, liftAmount)
  where
    synthEntry argument = do
      (typedValue, normalizedType) <- synthExpression argument.value
      let typedArg =
            CallArgument
              { name = argument.name,
                labelReference = retagReference argument.labelReference,
                value = typedValue,
                sourceSpan = argument.sourceSpan
              }
      pure (typedArg, argument.name, normalizedType)

collectAttributeUnion :: NormalizedType -> NormalizedAttribute
collectAttributeUnion normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeUnknown -> normalizedType.attribute
  NormalizedBaseTypeLayered layer ->
    joinAttribute normalizedType.attribute (collectLayerAttributes layer)

collectLayerAttributes :: LayeredType -> NormalizedAttribute
collectLayerAttributes layer =
  foldr
    joinAttribute
    bottomAttribute
    [ maybe bottomAttribute collectFunctionAttributes layer.functionLayer,
      maybe bottomAttribute collectSequenceAttributes layer.sequenceLayer,
      maybe bottomAttribute collectObjectAttributes layer.objectLayer,
      collectDataAttributes layer.dataLayer
    ]

-- | A function value's observable privacy flows only from what it can produce — its result. The
-- argument is contravariant (the caller supplies it), so a private parameter does not make a pure
-- call's result private and must not be collected.
collectFunctionAttributes :: NormalizedFunction -> NormalizedAttribute
collectFunctionAttributes function = collectAttributeUnion function.returnType

collectSequenceAttributes :: NormalizedSequence -> NormalizedAttribute
collectSequenceAttributes normalizedSequence =
  joinAttribute
    (foldr (joinAttribute . collectAttributeUnion) bottomAttribute normalizedSequence.items)
    (collectAttributeUnion normalizedSequence.rest)

collectObjectAttributes :: NormalizedObject -> NormalizedAttribute
collectObjectAttributes normalizedObject =
  joinAttribute
    (foldr joinAttribute bottomAttribute [collectAttributeUnion field.normalizedType | field <- Map.elems normalizedObject.fields])
    (collectAttributeUnion normalizedObject.rest)

collectDataAttributes :: Map QualifiedName (Map Text NormalizedKindedType) -> NormalizedAttribute
collectDataAttributes =
  foldr joinAttribute bottomAttribute
    . concatMap (fmap collectKindedAttribute . Map.elems)
    . Map.elems

collectKindedAttribute :: NormalizedKindedType -> NormalizedAttribute
collectKindedAttribute = \case
  NormalizedKindedTypeType normalizedType -> collectAttributeUnion normalizedType
  NormalizedKindedTypeAttribute attribute -> attribute
  NormalizedKindedTypeEffect _ -> bottomAttribute

isPureEffect :: NormalizedEffect -> Bool
isPureEffect = \case
  NormalizedEffectAny -> False
  NormalizedEffectRow row -> Map.null row.request && Map.null row.tails

liftByAttribute :: NormalizedAttribute -> NormalizedType -> NormalizedType
liftByAttribute attribute normalizedType =
  NormalizedType
    { baseType = normalizedType.baseType,
      generics = normalizedType.generics,
      attribute = joinAttribute normalizedType.attribute attribute
    }

------------------------------------------------------------------------------------------------
-- Operators
------------------------------------------------------------------------------------------------

synthBinaryExpression ::
  BinaryOperatorExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthBinaryExpression expression = do
  (typedLeft, typedRight, nt) <- case expression.operator of
    BinaryOperatorAdd -> arithmetic
    BinaryOperatorSubtract -> arithmetic
    BinaryOperatorMultiply -> arithmetic
    BinaryOperatorDivide -> arithmeticReturningNumber
    BinaryOperatorModulo -> arithmeticReturningNumber
    BinaryOperatorEqual -> booleanResultAnyPair
    BinaryOperatorNotEqual -> booleanResultAnyPair
    BinaryOperatorLessThan -> booleanResultNumericPair
    BinaryOperatorLessOrEqual -> booleanResultNumericPair
    BinaryOperatorGreaterThan -> booleanResultNumericPair
    BinaryOperatorGreaterOrEqual -> booleanResultNumericPair
    BinaryOperatorAnd -> booleanResultBooleanPair
    BinaryOperatorOr -> booleanResultBooleanPair
    BinaryOperatorConcat -> do
      l <- checkExpression expression.left stringType
      r <- checkExpression expression.right stringType
      pure (l, r, stringType)
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionBinaryOperator
        BinaryOperatorExpression
          { operator = expression.operator,
            left = typedLeft,
            right = typedRight,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )
  where
    arithmetic = do
      (typedLeft, leftType) <- synthExpression expression.left
      runNormalizer (sourceSpanOf expression.left) (subtype leftType numberType)
      (typedRight, rightType) <- synthExpression expression.right
      runNormalizer (sourceSpanOf expression.right) (subtype rightType numberType)
      joined <- runNormalizer expression.sourceSpan (union leftType rightType)
      pure (typedLeft, typedRight, joined)
    arithmeticReturningNumber = do
      l <- checkExpression expression.left numberType
      r <- checkExpression expression.right numberType
      pure (l, r, numberType)
    booleanResultAnyPair = do
      (l, _) <- synthExpression expression.left
      (r, _) <- synthExpression expression.right
      pure (l, r, booleanType)
    booleanResultNumericPair = do
      l <- checkExpression expression.left numberType
      r <- checkExpression expression.right numberType
      pure (l, r, booleanType)
    booleanResultBooleanPair = do
      l <- checkExpression expression.left booleanType
      r <- checkExpression expression.right booleanType
      pure (l, r, booleanType)

synthUnaryExpression ::
  UnaryOperatorExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthUnaryExpression expression = do
  (typedOperand, nt) <- case expression.operator of
    UnaryOperatorNegate -> do
      (typed, operandType) <- synthExpression expression.operand
      runNormalizer (sourceSpanOf expression.operand) (subtype operandType numberType)
      pure (typed, operandType)
    UnaryOperatorNot -> do
      typed <- checkExpression expression.operand booleanType
      pure (typed, booleanType)
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionUnaryOperator
        UnaryOperatorExpression
          { operator = expression.operator,
            operand = typedOperand,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )

------------------------------------------------------------------------------------------------
-- Jump statements
------------------------------------------------------------------------------------------------

checkReturnStatement :: ReturnStatement Identified -> Checker (ReturnStatement Typed)
checkReturnStatement returnStmt = do
  contexts <- asks (.jumps)
  typedValue <- case contexts.returnTarget of
    Just target -> checkExpression returnStmt.value target
    Nothing -> do
      reportMisplacedJump returnStmt.sourceSpan "return" "an agent body"
      (typed, _) <- synthExpression returnStmt.value
      pure typed
  pure ReturnStatement {value = typedValue, sourceSpan = returnStmt.sourceSpan}

checkForNextStatement :: ForNextStatement Identified -> Checker (ForNextStatement Typed)
checkForNextStatement forNextStmt = do
  contexts <- asks (.jumps)
  (typedValue, typedModifiers) <- case contexts.forContexts of
    (frame : _) -> do
      (typedValue, valueType) <- synthExpression forNextStmt.value
      runNormalizer forNextStmt.sourceSpan (subtype valueType frame.nextElementType)
      emitForNextType forNextStmt.sourceSpan valueType
      typedModifiers <- checkModifiers forNextStmt.modifiers
      pure (typedValue, typedModifiers)
    [] -> do
      reportMisplacedJump forNextStmt.sourceSpan "next" "a `for` body"
      (typed, _) <- synthExpression forNextStmt.value
      typedModifiers <- traverse retagModifier forNextStmt.modifiers
      pure (typed, typedModifiers)
  pure
    ForNextStatement
      { value = typedValue,
        modifiers = typedModifiers,
        sourceSpan = forNextStmt.sourceSpan
      }

checkForBreakStatement :: ForBreakStatement Identified -> Checker (ForBreakStatement Typed)
checkForBreakStatement forBreakStmt = do
  contexts <- asks (.jumps)
  typedValue <- case contexts.forContexts of
    (frame : _) -> do
      -- A `break` value is the loop's early-exit result, checked against the frame's break-result
      -- type; it is not a `next` element, so it must not feed the element accumulator.
      (typed, valueType) <- synthExpression forBreakStmt.value
      runNormalizer forBreakStmt.sourceSpan (subtype valueType frame.breakResultType)
      pure typed
    [] -> do
      reportMisplacedJump forBreakStmt.sourceSpan "break" "a `for` body"
      (typed, _) <- synthExpression forBreakStmt.value
      pure typed
  pure ForBreakStatement {value = typedValue, sourceSpan = forBreakStmt.sourceSpan}

emitForNextType :: SourceSpan -> NormalizedType -> Checker ()
emitForNextType sourceSpan valueType = do
  current <- getForBodyAccumulator
  joined <- runNormalizer sourceSpan (union current valueType)
  setForBodyAccumulator joined

emitEffect :: SourceSpan -> NormalizedEffect -> Checker ()
emitEffect sourceSpan effectToEmit = do
  current <- getEffectAccumulator
  joined <- runNormalizer sourceSpan (union current effectToEmit)
  setEffectAccumulator joined

-- | Check @with x = e@ modifiers against the state variable's type. The identifier resolves every
-- modifier target to an enclosing @for@ / handler state variable (K2007 covers the rest), and that
-- variable is in scope while its body is walked, so an unresolved or out-of-scope target here is a
-- compiler bug.
checkModifiers :: List (Modifier Identified) -> Checker (List (Modifier Typed))
checkModifiers = traverse checkOneModifier
  where
    checkOneModifier modifier = case modifier.variableReference.resolution of
      Just (VariableResolutionLocalVariable localId) -> do
        maybeBinding <- asks (\environment -> Map.lookup localId environment.locals)
        case maybeBinding of
          Just binding -> do
            typedValue <- checkExpression modifier.value binding.valueType
            pure
              Modifier
                { name = modifier.name,
                  variableReference = retagReference modifier.variableReference,
                  value = typedValue,
                  sourceSpan = modifier.sourceSpan
                }
          Nothing -> panic "checkModifiers: modifier target local is not in scope"
      _ -> panic "checkModifiers: modifier target is not resolved to a local variable"

retagModifier :: Modifier Identified -> Checker (Modifier Typed)
retagModifier modifier = do
  (typed, _) <- synthExpression modifier.value
  pure
    Modifier
      { name = modifier.name,
        variableReference = retagReference modifier.variableReference,
        value = typed,
        sourceSpan = modifier.sourceSpan
      }

checkBreakStatement :: BreakStatement Identified -> Checker (BreakStatement Typed)
checkBreakStatement breakStmt = do
  contexts <- asks (.jumps)
  typedValue <- case contexts.handleContexts of
    (frame : _) -> checkExpression breakStmt.value frame.handlerResultType
    [] -> do
      reportMisplacedJump breakStmt.sourceSpan "break" "a request handler body"
      (typed, _) <- synthExpression breakStmt.value
      pure typed
  pure BreakStatement {value = typedValue, sourceSpan = breakStmt.sourceSpan}

checkNextStatement :: NextStatement Identified -> Checker (NextStatement Typed)
checkNextStatement nextStmt = do
  contexts <- asks (.jumps)
  (typedValue, typedModifiers) <- case contexts.handleContexts of
    (frame : _) -> do
      typedValue <- checkExpression nextStmt.value frame.currentRequestReturnType
      typedModifiers <- checkModifiers nextStmt.modifiers
      pure (typedValue, typedModifiers)
    [] -> do
      reportMisplacedJump nextStmt.sourceSpan "next" "a request handler body"
      (typed, _) <- synthExpression nextStmt.value
      typedModifiers <- traverse retagModifier nextStmt.modifiers
      pure (typed, typedModifiers)
  pure
    NextStatement
      { value = typedValue,
        modifiers = typedModifiers,
        sourceSpan = nextStmt.sourceSpan
      }

------------------------------------------------------------------------------------------------
-- Patterns
------------------------------------------------------------------------------------------------

checkPattern ::
  Pattern Identified ->
  NormalizedType ->
  Checker (Pattern Typed, NormalizedType, List (LocalVariableId, Scheme))
checkPattern pattern scrutinee = case pattern of
  PatternWildcard wildcardPattern -> do
    (coverType, retagged) <- case wildcardPattern.typeAnnotation of
      Nothing -> pure (topType, Nothing)
      Just annotation -> do
        c <- elaborateAndNormalizeType annotation
        pure (c, Just (retagSyntacticTypeExpression annotation))
    semantic <- denormalizeAt wildcardPattern.sourceSpan coverType
    pure
      ( PatternWildcard
          WildcardPattern
            { typeAnnotation = retagged,
              sourceSpan = wildcardPattern.sourceSpan,
              typeOf = semantic
            },
        coverType,
        []
      )
  PatternVariable variablePattern -> do
    let maybeLocal = case variablePattern.variableReference.resolution of
          Just (VariableResolutionLocalVariable localId) -> Just localId
          _ -> Nothing
    (coverType, bindingType, retaggedAnnotation) <- case variablePattern.typeAnnotation of
      Nothing -> pure (topType, scrutinee, Nothing)
      Just annotation -> do
        annotatedType <- elaborateAndNormalizeType annotation
        pure (annotatedType, annotatedType, Just (retagSyntacticTypeExpression annotation))
    semantic <- denormalizeAt variablePattern.sourceSpan bindingType
    pure
      ( PatternVariable
          VariablePattern
            { name = variablePattern.name,
              variableReference = retagReference variablePattern.variableReference,
              typeAnnotation = retaggedAnnotation,
              defaultValue = variablePattern.defaultValue,
              sourceSpan = variablePattern.sourceSpan,
              typeOf = semantic
            },
        coverType,
        bindingsFor maybeLocal bindingType
      )
  PatternLiteral literalPattern -> do
    let nt = synthLiteralValue literalPattern.value
    semantic <- denormalizeAt literalPattern.sourceSpan nt
    pure
      ( PatternLiteral
          LiteralPattern
            { value = literalPattern.value,
              sourceSpan = literalPattern.sourceSpan,
              typeOf = semantic
            },
        nt,
        []
      )
  PatternTypeFilter typeFilterPattern -> do
    matchedType <- elaborateAndNormalizeType typeFilterPattern.matchedType
    (typedInner, innerCover, innerBindings) <- checkPattern typeFilterPattern.inner matchedType
    -- The cover (what this arm matches) is @matchedType ∧ innerCover@. 'intersect' under-approximates
    -- the meet on generics, which is exactly the sound direction here: covers are used only for the
    -- exhaustiveness lower bound @scrutinee <: ⋃ covers@, never to narrow a bound variable (the inner
    -- pattern is checked against @matchedType@ directly above), so the Normalizer's narrowing caveat
    -- does not apply.
    cover <- runNormalizer (sourceSpanOf typeFilterPattern) (intersect matchedType innerCover)
    semantic <- denormalizeAt typeFilterPattern.sourceSpan cover
    pure
      ( PatternTypeFilter
          TypeFilterPattern
            { matchedType = retagSyntacticTypeExpression typeFilterPattern.matchedType,
              inner = typedInner,
              sourceSpan = typeFilterPattern.sourceSpan,
              typeOf = semantic
            },
        cover,
        innerBindings
      )
  PatternTuple tuplePattern -> do
    let elementTypes = extractTupleElementTypes scrutinee (length tuplePattern.elements)
    pairResults <- zipWithM checkPattern tuplePattern.elements elementTypes
    let typedElements = [t | (t, _, _) <- pairResults]
        elementCovers = [c | (_, c, _) <- pairResults]
        allBindings = concatMap (\(_, _, b) -> b) pairResults
        cover =
          layeredOf
            neverLayer
              { sequenceLayer = Just NormalizedSequence {items = elementCovers, rest = nullType}
              }
    semantic <- denormalizeAt tuplePattern.sourceSpan cover
    pure
      ( PatternTuple
          TuplePattern
            { elements = typedElements,
              sourceSpan = tuplePattern.sourceSpan,
              typeOf = semantic
            },
        cover,
        allBindings
      )
  PatternRecord recordPattern -> do
    fieldResults <- traverse (checkFieldPattern scrutinee) recordPattern.fields
    let typedFields = [tp | (_, _, _, tp) <- fieldResults]
        fields =
          Map.fromList
            [ (fieldName, NormalizedFieldInformation {normalizedType = fieldCover, optional = False})
              | (fieldName, fieldCover, _, _) <- fieldResults
            ]
        allBindings = concatMap (\(_, _, b, _) -> b) fieldResults
        cover =
          layeredOf
            neverLayer
              { objectLayer = Just NormalizedObject {fields = fields, rest = unknownType}
              }
    semantic <- denormalizeAt recordPattern.sourceSpan cover
    pure
      ( PatternRecord
          RecordPattern
            { fields = typedFields,
              sourceSpan = recordPattern.sourceSpan,
              typeOf = semantic
            },
        cover,
        allBindings
      )
  PatternConstructor constructorPattern -> case constructorPattern.constructorReference.resolution of
    Just (VariableResolutionQualifiedName qualifiedName) -> do
      dataEnvironment <- asks (\environment -> environment.typeEnvironment.dataEnvironment)
      case Map.lookup qualifiedName dataEnvironment of
        Just dataInfo -> do
          substitution <-
            buildGenericSubstitution
              constructorPattern.sourceSpan
              (renderQualifiedName qualifiedName)
              dataInfo.genericParameters
              constructorPattern.genericArguments
          instantiatedConstructor <-
            runNormalizer constructorPattern.sourceSpan (substituteType substitution dataInfo.constructor)
          fieldResults <- traverse (checkFieldPattern instantiatedConstructor) constructorPattern.fields
          let typedFields = [tp | (_, _, _, tp) <- fieldResults]
              allBindings = concatMap (\(_, _, b, _) -> b) fieldResults
              argumentsByName =
                Map.fromList
                  [ (paramName, argument)
                    | (paramName, info) <- Map.toList dataInfo.genericParameters.parameterInformation,
                      Just argument <- [Map.lookup info.genericId substitution]
                  ]
              cover =
                layeredOf
                  neverLayer
                    { dataLayer = Map.singleton qualifiedName argumentsByName
                    }
          semantic <- denormalizeAt constructorPattern.sourceSpan cover
          pure
            ( PatternConstructor
                ConstructorPattern
                  { moduleQualifier = retagModuleQualifier <$> constructorPattern.moduleQualifier,
                    name = constructorPattern.name,
                    constructorReference = retagReference constructorPattern.constructorReference,
                    genericArguments = retagSyntacticTypeExpression <$> constructorPattern.genericArguments,
                    instantiation = mempty,
                    fields = typedFields,
                    sourceSpan = constructorPattern.sourceSpan,
                    typeOf = semantic
                  },
              cover,
              allBindings
            )
        -- The identifier resolved this constructor and the env-build registered every data type, so
        -- a resolved constructor name absent from the data environment is a compiler bug.
        Nothing -> panic ("checkPattern: data type not registered: " <> renderQualifiedName qualifiedName)
    _ -> panic "checkPattern: constructor pattern is not resolved to a data type"
  where
    bindingsFor maybeLocal bindingType = case maybeLocal of
      Just localId -> [(localId, monoScheme bindingType)]
      Nothing -> []

extractTupleElementTypes :: NormalizedType -> Int -> List NormalizedType
extractTupleElementTypes scrutinee count = case scrutinee.baseType of
  NormalizedBaseTypeLayered layer
    | Just normalizedSequence <- layer.sequenceLayer ->
        take count (normalizedSequence.items <> repeat normalizedSequence.rest)
  _ -> replicate count topType

extractFieldType :: NormalizedType -> Text -> NormalizedType
extractFieldType scrutinee fieldName = case scrutinee.baseType of
  NormalizedBaseTypeLayered layer | Just normalizedObject <- layer.objectLayer ->
    case Map.lookup fieldName normalizedObject.fields of
      Just field -> field.normalizedType
      Nothing -> normalizedObject.rest
  _ -> topType

checkFieldPattern ::
  NormalizedType ->
  FieldPattern Identified ->
  Checker (Text, NormalizedType, List (LocalVariableId, Scheme), FieldPattern Typed)
checkFieldPattern scrutinee fieldPattern = do
  let fieldName = fieldPattern.name
      fieldScrutinee = extractFieldType scrutinee fieldName
  (typedInner, cover, bindings) <- checkPattern fieldPattern.bindPattern fieldScrutinee
  let typedFieldPattern =
        FieldPattern
          { name = fieldPattern.name,
            labelReference = retagReference fieldPattern.labelReference,
            bindPattern = typedInner,
            sourceSpan = fieldPattern.sourceSpan
          }
  pure (fieldName, cover, bindings, typedFieldPattern)

------------------------------------------------------------------------------------------------
-- Match expressions
------------------------------------------------------------------------------------------------

synthMatchExpression :: MatchExpression Identified -> Checker (Expression Typed, NormalizedType)
synthMatchExpression expression = do
  (typedSubject, scrutineeType) <- synthExpression expression.subject
  results <- traverse (processCase scrutineeType) expression.cases
  -- The arm covers union to a sound lower bound of what the match accepts; exhaustiveness is then
  -- @scrutinee <: ⋃ covers@. Folding from 'bottomType' makes an empty match (covers union to never)
  -- fail this check for any inhabited scrutinee, with no special case.
  unionCover <- foldM combineUnion bottomType [cover | (cover, _, _) <- results]
  nt <- foldM combineUnion bottomType [body | (_, body, _) <- results]
  runNormalizer expression.sourceSpan (subtype scrutineeType unionCover)
  let typedCases = [arm | (_, _, arm) <- results]
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionMatch
        MatchExpression
          { subject = typedSubject,
            cases = typedCases,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )
  where
    processCase scrutType arm = do
      (typedPattern, cover, bindings) <- checkPattern arm.pattern scrutType
      (typedBody, bodyType) <- withParameters bindings (synthBlock arm.body)
      let typedArm =
            CaseArm
              { pattern = typedPattern,
                body = typedBody,
                sourceSpan = arm.sourceSpan
              }
      pure (cover, bodyType, typedArm)
    combineUnion accumulator next = runNormalizer expression.sourceSpan (union accumulator next)

------------------------------------------------------------------------------------------------
-- For expressions
------------------------------------------------------------------------------------------------

synthForExpression :: ForExpression Identified -> Checker (Expression Typed, NormalizedType)
synthForExpression expression = do
  (typedSource, sourceType) <- synthExpression expression.inBinding.source
  elementType <- extractIterableElementType (sourceSpanOf expression.inBinding.source) sourceType
  (typedPattern, _, patternBindings) <- checkPattern expression.inBinding.pattern elementType
  let placeholderFrame =
        ForContext {nextElementType = topType, breakResultType = topType}
  (inferredNextType, (typedBody, typedVarBindings)) <-
    withForInference $
      pushForContext placeholderFrame $
        withParameters patternBindings $
          withVarBindingsTyped expression.varBindings $
            \tvbs -> do
              (tb, _) <- synthBlock expression.body
              pure (tb, tvbs)
  let arrayType = arrayOf (orNullType inferredNextType)
  (typedThen, finalType) <- case expression.thenClause of
    Nothing -> pure (Nothing, arrayType)
    Just thenClause -> do
      (typedBinder, thenBindings) <- case thenClause.binder of
        Just binder -> do
          (typedPat, _, bs) <- checkPattern binder arrayType
          pure (Just typedPat, bs)
        Nothing -> pure (Nothing, [])
      (typedThenBody, thenBodyType) <- withParameters thenBindings (synthBlock thenClause.body)
      let typedThen =
            ThenClause
              { binder = typedBinder,
                body = typedThenBody,
                sourceSpan = thenClause.sourceSpan
              }
      pure (Just typedThen, thenBodyType)
  semantic <- denormalizeAt expression.sourceSpan finalType
  pure
    ( ExpressionFor
        ForExpression
          { parallel = expression.parallel,
            inBinding =
              ForInBinding
                { pattern = typedPattern,
                  source = typedSource,
                  sourceSpan = expression.inBinding.sourceSpan
                },
            varBindings = typedVarBindings,
            body = typedBody,
            thenClause = typedThen,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      finalType
    )

extractIterableElementType :: SourceSpan -> NormalizedType -> Checker NormalizedType
extractIterableElementType sourceSpan source = case source.baseType of
  NormalizedBaseTypeLayered layer | Just normalizedSequence <- layer.sequenceLayer ->
    case normalizedSequence.items of
      [] -> pure normalizedSequence.rest
      (firstItem : restItems) -> foldM combineUnion firstItem restItems
  _ -> do
    reportExpectedShape sourceSpan "a sequence (array or tuple)" source
    pure bottomType
  where
    combineUnion accumulator next = runNormalizer sourceSpan (union accumulator next)

-- | Bring var bindings into scope and run a continuation; return the typed bindings.
withVarBindingsTyped ::
  List (VariableBinding Identified) ->
  (List (VariableBinding Typed) -> Checker a) ->
  Checker a
withVarBindingsTyped bindings continuation = go bindings []
  where
    go [] acc = continuation (reverse acc)
    go (b : rest) acc = withVarBindingTyped b $ \typedB -> go rest (typedB : acc)

withVarBindingTyped ::
  VariableBinding Identified ->
  (VariableBinding Typed -> Checker a) ->
  Checker a
withVarBindingTyped binding continuation = do
  let maybeLocalId = case binding.variableReference.resolution of
        Just (VariableResolutionLocalVariable localId) -> Just localId
        _ -> Nothing
  (typedInitial, initialType) <- case binding.typeAnnotation of
    Just annotation -> do
      annotatedType <- elaborateAndNormalizeType annotation
      typed <- checkExpression binding.initial annotatedType
      pure (typed, annotatedType)
    Nothing -> synthExpression binding.initial
  let typedBinding =
        VariableBinding
          { name = binding.name,
            variableReference = retagReference binding.variableReference,
            typeAnnotation = retagSyntacticTypeExpression <$> binding.typeAnnotation,
            initial = typedInitial,
            sourceSpan = binding.sourceSpan
          }
  case maybeLocalId of
    Just localId -> withLocal localId (monoScheme initialType) (continuation typedBinding)
    Nothing -> panic "withVarBindingTyped: state variable binding is not resolved to a local"

arrayOf :: NormalizedType -> NormalizedType
arrayOf elementType =
  layeredOf
    neverLayer
      { sequenceLayer = Just NormalizedSequence {items = [], rest = elementType}
      }

orNullType :: NormalizedType -> NormalizedType
orNullType normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeUnknown -> normalizedType
  NormalizedBaseTypeLayered layer ->
    NormalizedType
      { baseType = NormalizedBaseTypeLayered layer {nullLayer = True},
        generics = normalizedType.generics,
        attribute = normalizedType.attribute
      }

------------------------------------------------------------------------------------------------
-- Handler expressions
------------------------------------------------------------------------------------------------

synthHandlerExpression ::
  HandlerExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthHandlerExpression expression = do
  (resultType, residualEffect) <- elaborateHandlerGenerics expression
  (typedVarBindings, (handledNames, typedHandlers)) <-
    withVarBindingsTypedReturning expression.stateVariables $ do
      (handlerBodyEffect, results) <-
        withEffectInference $
          traverse (walkRequestHandler resultType residualEffect) expression.handlers
      -- Every request body runs inside the handler, so the effects it performs must lie within the
      -- handler's declared residual effect E.
      runNormalizer expression.sourceSpan (subtype handlerBodyEffect residualEffect)
      pure (fst <$> results, snd <$> results)
  continuationEffect <-
    foldM (joinRequestIntoEffect expression.sourceSpan) residualEffect handledNames
  let continuationAgent =
        layeredOf
          neverLayer
            { functionLayer =
                Just
                  NormalizedFunction
                    { argumentType = namedObjectType [("value", nullType)],
                      returnType = resultType,
                      effect = continuationEffect
                    }
            }
      outerParameter = namedObjectType [("continuation", continuationAgent)]
      handlerType =
        NormalizedType
          { baseType =
              NormalizedBaseTypeLayered
                neverLayer
                  { functionLayer =
                      Just
                        NormalizedFunction
                          { argumentType = outerParameter,
                            returnType = resultType,
                            effect = residualEffect
                          }
                  },
            generics = mempty,
            attribute = bottomAttribute
          }
  typedThen <- case expression.thenClause of
    Nothing -> pure Nothing
    Just thenClause -> do
      (typedBinder, thenBindings) <- case thenClause.binder of
        Just binder -> do
          (typedPat, _, bs) <- checkPattern binder resultType
          pure (Just typedPat, bs)
        Nothing -> pure (Nothing, [])
      (thenEffect, typedBody) <-
        withEffectInference $
          withParameters thenBindings $ do
            (tb, nt) <- synthBlock thenClause.body
            runNormalizer thenClause.sourceSpan (subtype nt resultType)
            pure tb
      -- The then clause runs as the handler's finalizer, so its effects are also bounded by E.
      runNormalizer thenClause.sourceSpan (subtype thenEffect residualEffect)
      pure
        ( Just
            ThenClause
              { binder = typedBinder,
                body = typedBody,
                sourceSpan = thenClause.sourceSpan
              }
        )
  semantic <- denormalizeAt expression.sourceSpan handlerType
  pure
    ( ExpressionHandler
        HandlerExpression
          { parallel = expression.parallel,
            genericArguments = retagSyntacticTypeExpression <$> expression.genericArguments,
            instantiation = mempty,
            stateVariables = typedVarBindings,
            handlers = typedHandlers,
            thenClause = typedThen,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      handlerType
    )

-- | Bring var bindings into scope and run a continuation; return the typed bindings paired with
-- the continuation's result.
withVarBindingsTypedReturning ::
  List (VariableBinding Identified) ->
  Checker a ->
  Checker (List (VariableBinding Typed), a)
withVarBindingsTypedReturning bindings continuation = go bindings []
  where
    go [] acc = do
      result <- continuation
      pure (reverse acc, result)
    go (b : rest) acc = withVarBindingTyped b $ \typedB -> go rest (typedB : acc)

elaborateHandlerGenerics ::
  HandlerExpression Identified ->
  Checker (NormalizedType, NormalizedEffect)
elaborateHandlerGenerics expression = case expression.genericArguments of
  [resultArgument, effectArgument] -> do
    resolvedResult <- elaborateAndNormalizeType resultArgument
    resolvedEffect <- elaborateAndNormalizeEffect effectArgument
    pure (resolvedResult, resolvedEffect)
  _ -> do
    reportApplicationArity expression.sourceSpan "handler" 2 (length expression.genericArguments)
    pure (bottomType, bottomEffect)

-- | Walk one request handler: instantiate the request's parameter / return type with the handler's
-- generic arguments, check the handler's parameters accept the request's argument object, then walk
-- the body. The body's tail is an implicit @break@ to the handler result @R@, so its type must be a
-- subtype of @R@. Returns the handled request name (for the continuation effect) and the typed node.
walkRequestHandler ::
  NormalizedType ->
  NormalizedEffect ->
  RequestHandler Identified ->
  Checker (QualifiedName, RequestHandler Typed)
walkRequestHandler resultType residualEffect handler = do
  requestName <- case handler.typeReference.resolution of
    Just (TypeResolutionQualifiedName name) -> pure name
    _ -> panic "walkRequestHandler: request handler is not resolved to a request"
  requestEnv <- asks (\environment -> environment.typeEnvironment.requestEnvironment)
  requestInfo <- case Map.lookup requestName requestEnv of
    Just info -> pure info
    Nothing -> panic ("walkRequestHandler: request not registered: " <> renderQualifiedName requestName)
  substitution <-
    buildGenericSubstitution
      handler.sourceSpan
      (renderQualifiedName requestName)
      requestInfo.genericParameters
      handler.genericArguments
  let (rawParam, rawReturn) = requestInfo.request
  instantiatedParam <- runNormalizer handler.sourceSpan (substituteType substitution rawParam)
  instantiatedReturn <- runNormalizer handler.sourceSpan (substituteType substitution rawReturn)
  (paramObject, paramBindings, typedParams) <- buildParameterScopeTyped handler.parameters
  runNormalizer handler.sourceSpan (subtype instantiatedParam paramObject)
  let interceptedArguments =
        Map.fromList
          [ (paramName, argument)
            | (paramName, info) <- Map.toList requestInfo.genericParameters.parameterInformation,
              Just argument <- [Map.lookup info.genericId substitution]
          ]
      context =
        HandleContext
          { handlerResultType = resultType,
            handlerResidualEffect = residualEffect,
            handledRequests = Map.singleton requestName interceptedArguments,
            currentRequestReturnType = instantiatedReturn
          }
  (typedBlock, bodyType) <-
    pushHandleContext context $
      withParameters paramBindings $
        synthBlock handler.body
  runNormalizer handler.sourceSpan (subtype bodyType resultType)
  let typedHandler =
        RequestHandler
          { moduleQualifier = retagModuleQualifier <$> handler.moduleQualifier,
            name = handler.name,
            typeReference = retagReference handler.typeReference,
            genericArguments = retagSyntacticTypeExpression <$> handler.genericArguments,
            instantiation = mempty,
            parameters = typedParams,
            returnType = retagSyntacticTypeExpression <$> handler.returnType,
            body = typedBlock,
            sourceSpan = handler.sourceSpan
          }
  pure (requestName, typedHandler)

buildGenericSubstitution ::
  SourceSpan ->
  Text ->
  GenericParameters ->
  List (SyntacticTypeExpression Identified) ->
  Checker (Map GenericId NormalizedKindedType)
buildGenericSubstitution sourceSpan headName parameters argumentExpressions = do
  let parameterNames = parameters.parameterNames
      parameterInfo = parameters.parameterInformation
  if length parameterNames /= length argumentExpressions
    then do
      reportApplicationArity sourceSpan headName (length parameterNames) (length argumentExpressions)
      pure mempty
    else
      Map.fromList . catMaybes
        <$> zipWithM (elaborateArgument parameterInfo) parameterNames argumentExpressions
  where
    elaborateArgument parameterInfo parameterName argument = case Map.lookup parameterName parameterInfo of
      Nothing -> pure Nothing
      Just info -> do
        kinded <- case info.kind of
          GenericKindType -> NormalizedKindedTypeType <$> elaborateAndNormalizeType argument
          GenericKindEffect -> NormalizedKindedTypeEffect <$> elaborateAndNormalizeEffect argument
          GenericKindAttribute -> do
            semantic <- runElaborator (elaborateAsAttribute argument)
            normalized <- runNormalizer (sourceSpanOf argument) (normalizeAttribute semantic)
            pure (NormalizedKindedTypeAttribute normalized)
        pure (Just (info.genericId, kinded))

joinRequestIntoEffect ::
  SourceSpan ->
  NormalizedEffect ->
  QualifiedName ->
  Checker NormalizedEffect
joinRequestIntoEffect sourceSpan baseEffect requestName = do
  let addition =
        NormalizedEffectRow
          EffectRow {request = Map.singleton requestName mempty, tails = mempty}
  runNormalizer sourceSpan (union baseEffect addition)

namedObjectType :: List (Text, NormalizedType) -> NormalizedType
namedObjectType fieldList =
  layeredOf
    neverLayer
      { objectLayer =
          Just
            NormalizedObject
              { fields =
                  Map.fromList
                    [ (fieldName, NormalizedFieldInformation {normalizedType = fieldType, optional = False})
                      | (fieldName, fieldType) <- fieldList
                    ],
                rest = unknownType
              }
      }

------------------------------------------------------------------------------------------------
-- Agent declarations
------------------------------------------------------------------------------------------------

-- | Everything an agent's body walk needs that does not depend on the body itself: the outer /
-- declared attributes, the parameter object type and per-parameter scope, and the elaborated return
-- / effect annotations. Computed once per agent (also reused across the two-pass cyclic walk) so
-- parameter annotations are never elaborated — nor their diagnostics emitted — twice.
data AgentPreparation = AgentPreparation
  { genericParameters :: GenericParameters,
    outerAttribute :: NormalizedAttribute,
    declaredAttribute :: NormalizedAttribute,
    parameterObject :: NormalizedType,
    parameterBindings :: List (LocalVariableId, Scheme),
    typedParameters :: List (ParameterBinding Typed),
    annotatedReturnType :: Maybe NormalizedType,
    annotatedEffect :: Maybe NormalizedEffect
  }

-- | The agent's own generic parameters are in scope ('withGenerics') while its parameter / return /
-- effect annotations are elaborated, since those may reference them. The same generics are brought
-- back into scope when the body is walked (in 'synthAgent' / 'checkAgentBody').
prepareAgent :: AgentDeclaration Identified -> Checker AgentPreparation
prepareAgent declaration = do
  (outerAttribute, declaredAttribute) <- agentAttributes declaration
  let (genericParameters, _genericBounds) = collectGenericParameters declaration.genericParameters
  withGenerics genericParameters $ do
    (parameterObject, parameterBindings, typedParameters) <- buildParameterScopeTyped declaration.parameters
    annotatedReturnType <- traverse elaborateAndNormalizeType declaration.returnType
    annotatedEffect <- traverse elaborateAndNormalizeEffect declaration.effects
    pure
      AgentPreparation
        { genericParameters = genericParameters,
          outerAttribute = outerAttribute,
          declaredAttribute = declaredAttribute,
          parameterObject = parameterObject,
          parameterBindings = parameterBindings,
          typedParameters = typedParameters,
          annotatedReturnType = annotatedReturnType,
          annotatedEffect = annotatedEffect
        }

-- | Build the 'Typed' agent declaration; every field but the parameters and body is a mechanical
-- retag of the identified declaration.
assembleTypedAgentDeclaration ::
  AgentDeclaration Identified ->
  List (ParameterBinding Typed) ->
  Block Typed ->
  AgentDeclaration Typed
assembleTypedAgentDeclaration declaration typedParameters typedBody =
  AgentDeclaration
    { annotation = declaration.annotation,
      private = declaration.private,
      name = declaration.name,
      variableReference = retagReference declaration.variableReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      parameters = typedParameters,
      returnType = retagSyntacticTypeExpression <$> declaration.returnType,
      effects = retagSyntacticTypeExpression <$> declaration.effects,
      body = typedBody,
      sourceSpan = declaration.sourceSpan
    }

-- | Check one acyclic agent, producing its 'Scheme' (its generics plus the function type). The
-- annotation policy is optional: a missing return type is synthesized from the body, a missing
-- effect defaults to the body's inferred effect.
synthAgent :: AgentDeclaration Identified -> Checker (AgentDeclaration Typed, Scheme)
synthAgent declaration = do
  preparation <- prepareAgent declaration
  (inferredEffect, (typedBody, bodyReturnType)) <-
    withEffectInference
      $ withGenerics preparation.genericParameters
        . withWorld preparation.declaredAttribute
        . withParameters preparation.parameterBindings
      $ case preparation.annotatedReturnType of
        Just expected -> do
          typedB <- withReturnTarget expected (checkBlock declaration.body expected)
          pure (typedB, expected)
        Nothing -> withReturnTarget topType (synthBlock declaration.body)
  finalEffect <- case preparation.annotatedEffect of
    Just declared -> do
      runNormalizer declaration.sourceSpan (subtype inferredEffect declared)
      pure declared
    Nothing -> pure inferredEffect
  pure
    ( assembleTypedAgentDeclaration declaration preparation.typedParameters typedBody,
      Scheme
        { genericParameters = preparation.genericParameters,
          valueType = assembleAgent preparation.outerAttribute preparation.parameterObject bodyReturnType finalEffect
        }
    )

-- | The function type of an acyclic agent, for tests that only need the synthesized type.
synthAgentType :: AgentDeclaration Identified -> Checker NormalizedType
synthAgentType = fmap ((.valueType) . snd) . synthAgent

-- | The seed scheme of one member of a recursive group, from its (required) return / effect
-- annotations. Takes the member's 'prepareAgent' result so the parameters are not elaborated twice
-- (the body pass reuses the same preparation).
seedAgentType :: AgentDeclaration Identified -> AgentPreparation -> Checker Scheme
seedAgentType declaration preparation = do
  when (isNothing declaration.returnType) $
    reportMissingAnnotation declaration.sourceSpan ("agent `" <> declaration.name <> "` in a recursive group requires an explicit return type")
  when (isNothing declaration.effects) $
    reportMissingAnnotation declaration.sourceSpan ("agent `" <> declaration.name <> "` in a recursive group requires an explicit effect annotation")
  pure
    Scheme
      { genericParameters = preparation.genericParameters,
        valueType =
          assembleAgent
            preparation.outerAttribute
            preparation.parameterObject
            (fromMaybe bottomType preparation.annotatedReturnType)
            (fromMaybe bottomEffect preparation.annotatedEffect)
      }

-- | Check one recursive-group member's body against its seed scheme (built by 'seedAgentType' and
-- carried as the function extracted from that seed), reusing its 'prepareAgent' result.
checkAgentBody :: AgentDeclaration Identified -> AgentPreparation -> NormalizedType -> Checker (AgentDeclaration Typed)
checkAgentBody declaration preparation seed = do
  function <- case extractFunction seed of
    Just (_, fn) -> pure fn
    Nothing -> panic "checkAgentBody: agent seed is not a function type"
  (inferredEffect, typedBody) <-
    withEffectInference
      $ withGenerics preparation.genericParameters
        . withWorld preparation.declaredAttribute
        . withParameters preparation.parameterBindings
        . withReturnTarget function.returnType
      $ checkBlock declaration.body function.returnType
  runNormalizer declaration.sourceSpan (subtype inferredEffect function.effect)
  pure (assembleTypedAgentDeclaration declaration preparation.typedParameters typedBody)

------------------------------------------------------------------------------------------------
-- Signature-determined value schemes (data constructor / external / primitive / request)
--
-- These have no body to infer from; their scheme is built from their signature, quantified over
-- their generics. The driver seeds them into the value environment alongside agent schemes.
------------------------------------------------------------------------------------------------

-- | The value scheme of an @external@ / @primitive@ agent: @agent(params) -> return with effects@,
-- quantified over its generics. (Both kinds share these fields, so the driver passes them in.)
signatureValueScheme ::
  List (GenericParameter Identified) ->
  List (ParameterSignature Identified) ->
  SyntacticTypeExpression Identified ->
  Maybe (SyntacticTypeExpression Identified) ->
  Checker Scheme
signatureValueScheme genericDeclarations parameters returnType effectExpression = do
  let (genericParameters, _genericBounds) = collectGenericParameters genericDeclarations
  withGenerics genericParameters $ do
    fields <- traverse (\signature -> (,) signature.name <$> elaborateAndNormalizeType signature.parameterType) parameters
    returnNormalized <- elaborateAndNormalizeType returnType
    effectNormalized <- maybe (pure bottomEffect) elaborateAndNormalizeEffect effectExpression
    pure
      Scheme
        { genericParameters = genericParameters,
          valueType = assembleAgent bottomAttribute (namedObjectType fields) returnNormalized effectNormalized
        }

-- | The value scheme of a data constructor: @agent(constructorObject) -> Data[generics]@ (pure),
-- read from the already-normalized 'DataInformation'. The constructor's parameters are a required
-- field object; the return is the nominal data type applied to the data type's own generics.
dataValueScheme :: SourceSpan -> QualifiedName -> Checker Scheme
dataValueScheme sourceSpan qualifiedName = do
  dataEnvironment <- asks (\environment -> environment.typeEnvironment.dataEnvironment)
  case Map.lookup qualifiedName dataEnvironment of
    Just info -> do
      arguments <- ownGenericArguments sourceSpan info.genericParameters
      let returnType = layeredOf neverLayer {dataLayer = Map.singleton qualifiedName arguments}
      pure Scheme {genericParameters = info.genericParameters, valueType = assembleAgent bottomAttribute info.constructor returnType bottomEffect}
    Nothing -> panic ("dataValueScheme: data type not registered: " <> renderQualifiedName qualifiedName)

-- | The value scheme of a request performed as a value: @agent(param) -> return with {request}@,
-- read from the already-normalized 'RequestInformation'. The effect is the request applied to its
-- own generics.
requestValueScheme :: SourceSpan -> QualifiedName -> Checker Scheme
requestValueScheme sourceSpan qualifiedName = do
  requestEnvironment <- asks (\environment -> environment.typeEnvironment.requestEnvironment)
  case Map.lookup qualifiedName requestEnvironment of
    Just info -> do
      arguments <- ownGenericArguments sourceSpan info.genericParameters
      let (parameterType, returnType) = info.request
          effect = NormalizedEffectRow EffectRow {request = Map.singleton qualifiedName arguments, tails = mempty}
      pure Scheme {genericParameters = info.genericParameters, valueType = assembleAgent bottomAttribute parameterType returnType effect}
    Nothing -> panic ("requestValueScheme: request not registered: " <> renderQualifiedName qualifiedName)

-- | A nominal declaration applied to its own generic parameters as arguments (keyed by parameter
-- name): the @[a, b]@ of a data type's @Data[a, b]@ return or a request's @{req[a, b]}@ effect.
ownGenericArguments :: SourceSpan -> GenericParameters -> Checker (Map Text NormalizedKindedType)
ownGenericArguments sourceSpan parameters =
  Map.fromList
    <$> traverse
      (\(name, info) -> (,) name <$> runNormalizer sourceSpan (normalizeGenericArgument (schemeVariableFor info.kind info.genericId)))
      (Map.toList parameters.parameterInformation)

agentAttributes ::
  AgentDeclaration Identified ->
  Checker (NormalizedAttribute, NormalizedAttribute)
agentAttributes declaration = do
  closureWorld <- asks (.world)
  let declaredAttribute = if declaration.private then privateAttribute else bottomAttribute
      agentOuterAttribute = joinAttribute closureWorld declaredAttribute
  pure (agentOuterAttribute, declaredAttribute)

assembleAgent ::
  NormalizedAttribute ->
  NormalizedType ->
  NormalizedType ->
  NormalizedEffect ->
  NormalizedType
assembleAgent agentOuterAttribute parameterObject returnType effect =
  NormalizedType
    { baseType =
        NormalizedBaseTypeLayered
          neverLayer
            { functionLayer =
                Just
                  NormalizedFunction
                    { argumentType = parameterObject,
                      returnType = returnType,
                      effect = effect
                    }
            },
      generics = mempty,
      attribute = agentOuterAttribute
    }

-- | The declared type of a binding-site pattern (an agent parameter, a @use@ binder): a variable /
-- wildcard pattern's annotation, or a type filter's matched type. Other shapes (a bare tuple /
-- record destructuring) carry no annotation of their own, so the binder must wrap them in a type
-- filter — @label => ((x, y) : T)@.
patternTypeAnnotation :: Pattern Identified -> Maybe (SyntacticTypeExpression Identified)
patternTypeAnnotation = \case
  PatternVariable variablePattern -> variablePattern.typeAnnotation
  PatternWildcard wildcardPattern -> wildcardPattern.typeAnnotation
  PatternTypeFilter typeFilterPattern -> Just typeFilterPattern.matchedType
  _ -> Nothing

-- | Check a binding-site pattern that must declare its own type. 'checkPattern' against 'topType'
-- both produces the typed pattern + bindings (destructuring included) and computes the pattern's
-- cover, which — because the pattern pins its type via an annotation — is exactly the declared type.
-- A missing annotation is reported and the cover degrades to 'topType'.
checkAnnotatedBinder ::
  Text ->
  Pattern Identified ->
  Checker (NormalizedType, Pattern Typed, List (LocalVariableId, Scheme))
checkAnnotatedBinder reason pattern = do
  when (isNothing (patternTypeAnnotation pattern)) $
    reportMissingAnnotation (sourceSpanOf pattern) reason
  (typedPattern, declaredType, bindings) <- checkPattern pattern topType
  pure (declaredType, typedPattern, bindings)

-- | Build the parameter object type, per-parameter bindings, and per-parameter Typed nodes. Each
-- parameter's @label => pattern@ is checked as an annotated binder, so destructuring parameters are
-- supported uniformly with simple @label : T@ ones.
buildParameterScopeTyped ::
  List (ParameterBinding Identified) ->
  Checker
    ( NormalizedType,
      List (LocalVariableId, Scheme),
      List (ParameterBinding Typed)
    )
buildParameterScopeTyped parameters = do
  entries <- traverse buildOne parameters
  let parameterObject =
        layeredOf
          neverLayer
            { objectLayer =
                Just
                  NormalizedObject
                    { fields =
                        Map.fromList
                          [ (name, NormalizedFieldInformation {normalizedType = parameterType, optional = False})
                            | (name, parameterType, _, _) <- entries
                          ],
                      rest = unknownType
                    }
            }
      bindings = concat [bs | (_, _, bs, _) <- entries]
      typedParameters = [tp | (_, _, _, tp) <- entries]
  pure (parameterObject, bindings, typedParameters)
  where
    buildOne parameter = do
      (parameterType, typedPattern, bindings) <-
        checkAnnotatedBinder ("agent parameter `" <> parameter.name <> "` requires a type annotation") parameter.bindPattern
      let typedBinding =
            ParameterBinding
              { annotation = parameter.annotation,
                name = parameter.name,
                labelReference = retagReference parameter.labelReference,
                bindPattern = typedPattern,
                sourceSpan = parameter.sourceSpan
              }
      pure (parameter.name, parameterType, bindings, typedBinding)

------------------------------------------------------------------------------------------------
-- Annotation elaboration
------------------------------------------------------------------------------------------------

elaborateAndNormalizeType :: SyntacticTypeExpression Identified -> Checker NormalizedType
elaborateAndNormalizeType expression = do
  semantic <- runElaborator (elaborateAsType expression)
  runNormalizer (sourceSpanOf expression) (normalizeType semantic)

elaborateAndNormalizeEffect :: SyntacticTypeExpression Identified -> Checker NormalizedEffect
elaborateAndNormalizeEffect expression = do
  semantic <- runElaborator (elaborateAsEffect expression)
  runNormalizer (sourceSpanOf expression) (normalizeEffect semantic)

privateAttribute :: NormalizedAttribute
privateAttribute = NormalizedAttribute {private = True, generic = mempty}

------------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------------

reportType :: SourceSpan -> TypeError -> Checker ()
reportType sourceSpan typeError = tell (diagnosticAt sourceSpan (CompilerErrorType typeError))

-- | A @return@ / @break@ / @next@ used where its target context does not exist.
reportMisplacedJump :: SourceSpan -> Text -> Text -> Checker ()
reportMisplacedJump sourceSpan keyword requiredContext =
  reportType sourceSpan (TypeErrorMisplacedJump MisplacedJumpErrorInfo {keyword = keyword, requiredContext = requiredContext})

-- | A required type / effect annotation the checker does not infer is absent.
reportMissingAnnotation :: SourceSpan -> Text -> Checker ()
reportMissingAnnotation sourceSpan reason =
  reportType sourceSpan (TypeErrorMissingAnnotation MissingAnnotationErrorInfo {reason = reason})

-- | An expression is used where a particular shape (callable / sequence / object) is needed but its
-- type does not provide it. The actual type is denormalized for the message.
reportExpectedShape :: SourceSpan -> Text -> NormalizedType -> Checker ()
reportExpectedShape sourceSpan expected actualType = do
  actual <- denormalizeAt sourceSpan actualType
  reportType sourceSpan (TypeErrorExpectedShape ExpectedShapeErrorInfo {expected = expected, actual = actual})

-- | The wrong number of explicit type arguments for an application head (e.g. @handler[R, E]@ or a
-- request / data type's generics).
reportApplicationArity :: SourceSpan -> Text -> Int -> Int -> Checker ()
reportApplicationArity sourceSpan headName expected actual =
  reportType sourceSpan (TypeErrorApplicationArity ApplicationArityErrorInfo {head = headName, expected = expected, actual = actual})

-- | A construct the checker does not yet handle (distinct from a user error). The only remaining
-- case is a reference to a top-level value whose scheme the checker does not build — an external /
-- primitive agent or a data constructor; their value schemes are signature-determined but not yet
-- seeded into the value environment.
reportUnsupported :: SourceSpan -> Text -> Checker ()
reportUnsupported sourceSpan reason =
  reportType sourceSpan (TypeErrorMalformedType MalformedTypeErrorInfo {reason = reason})

-- | The 'Scheme' a resolved value reference denotes, without instantiating it. A resolved local not
-- in scope is a compiler bug; an unresolved reference (the identifier already reported it) and an
-- unregistered top-level value (the external / primitive / constructor gap, reported via
-- 'reportUnsupported') degrade to a non-generic bottom.
lookupScheme :: SourceSpan -> Maybe VariableResolution -> Checker Scheme
lookupScheme sourceSpan = \case
  Just (VariableResolutionLocalVariable localId) -> do
    maybeScheme <- asks (\environment -> Map.lookup localId environment.locals)
    case maybeScheme of
      Just scheme -> pure scheme
      Nothing -> panic "lookupScheme: resolved local variable is not in scope"
  Just (VariableResolutionQualifiedName qualifiedName) -> do
    maybeScheme <- asks (\environment -> Map.lookup qualifiedName environment.valueEnvironment)
    case maybeScheme of
      Just scheme -> pure scheme
      Nothing -> do
        reportUnsupported sourceSpan ("Top-level value not yet typed by the checker: " <> renderQualifiedName qualifiedName)
        pure (monoScheme bottomType)
  Nothing -> pure (monoScheme bottomType)

-- | The bare type of a value used where it is not explicitly applied. A generic value must be
-- applied first (generic inference is not supported), so a generic scheme here is an error; the
-- result degrades to bottom so no dangling generic leaks into the surrounding type.
instantiateBare :: SourceSpan -> Scheme -> Checker NormalizedType
instantiateBare sourceSpan scheme = case scheme.genericParameters.parameterNames of
  [] -> pure scheme.valueType
  _ -> do
    reportMissingAnnotation sourceSpan "a generic value must be applied to explicit type arguments (generic inference is not supported)"
    pure bottomType

-- | Bring a declaration's own generic parameters into scope (by id) while its body is checked, so
-- the normalizer consults each generic's bound and a body reference to a generic resolves.
withGenerics :: GenericParameters -> Checker a -> Checker a
withGenerics parameters action =
  foldr (\info -> withGeneric info.genericId info) action (Map.elems parameters.parameterInformation)

denormalizeAt :: SourceSpan -> NormalizedType -> Checker SemanticType
denormalizeAt sourceSpan normalizedType = runNormalizer sourceSpan (denormalize normalizedType)

------------------------------------------------------------------------------------------------
-- Primitive normalized-type literals
------------------------------------------------------------------------------------------------

layeredOf :: LayeredType -> NormalizedType
layeredOf layer = NormalizedType {baseType = NormalizedBaseTypeLayered layer, generics = Set.empty, attribute = bottomAttribute}

unknownType :: NormalizedType
unknownType = NormalizedType {baseType = NormalizedBaseTypeUnknown, generics = Set.empty, attribute = bottomAttribute}

nullType :: NormalizedType
nullType = layeredOf neverLayer {nullLayer = True}

booleanType :: NormalizedType
booleanType = layeredOf neverLayer {booleanLayer = True}

stringType :: NormalizedType
stringType = layeredOf neverLayer {stringLayer = True}

integerType :: NormalizedType
integerType = layeredOf neverLayer {numberLayer = NumberSlotInteger}

numberType :: NormalizedType
numberType = layeredOf neverLayer {numberLayer = NumberSlotNumber}
