-- | Bidirectional checking that produces the 'Typed' AST. Every walker returns the corresponding
-- typed node alongside the normalized type it computed; the 'typeOf' field on every typed
-- expression / pattern is the denormalized semantic type of that node.
--
-- The public entry points are 'synthExpression' / 'checkExpression' / 'synthBlock' / 'checkBlock' /
-- 'walkStatements' / 'checkPattern' / 'synthAgent' / 'buildAgentSeed' / 'checkAgentBody'.
-- Convenience wrappers ('synthExpressionType', 'synthAgentType') drop the typed AST and yield just
-- the normalized type — used by tests that only need the type-level result.
module Katari.Typechecker.Check where

import Control.Monad (foldM, unless, when, zipWithM)
import Control.Monad.RWS.Class (asks, tell)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestInformation (..), ValueInformation (..))
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId, LocalVariableId, TypeResolution (..), VariableResolution (..))
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (SemanticType)
import Katari.Data.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Diagnostics (diagnosticAt)
import Katari.Error (CompilerError (..), MalformedTypeErrorInfo (..), TypeError (..))
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment (..),
    ForContext (..),
    HandleContext (..),
    JumpContexts (..),
    LocalBinding (..),
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
    withLocal,
    withParameters,
    withReturnTarget,
    withWorld,
  )
import Katari.Typechecker.Elaborate (elaborateAsAttribute, elaborateAsEffect, elaborateAsType)
import Katari.Typechecker.Environment (TypeEnvironment (..))
import Katari.Typechecker.Normalizer (denormalize, intersect, joinAttribute, normalizeAttribute, normalizeEffect, normalizeType, substituteType, subtype, union)

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
            withLocal localId LocalBinding {localType = annotatedType} $
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
            withLocal localId LocalBinding {localType = bindingType} $
              walkStatements rest continuation
          let typedLetStmt =
                LetStatement
                  { pattern = typedPattern,
                    value = typedValue,
                    sourceSpan = letStmt.sourceSpan
                  }
          pure (result, StatementLet typedLetStmt : restTyped)
    _ -> do
      reportNotYetSupported (sourceSpanOf letStmt) "Variable in `let` must resolve to a local"
      (typedValue, valueType) <- synthExpression letStmt.value
      (typedPattern, _, _) <- checkPattern letStmt.pattern valueType
      (result, restTyped) <- walkStatements rest continuation
      let typedLetStmt =
            LetStatement
              { pattern = typedPattern,
                value = typedValue,
                sourceSpan = letStmt.sourceSpan
              }
      pure (result, StatementLet typedLetStmt : restTyped)
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
    (typedDeclaration, agentType) <- synthAgent declaration
    (result, restTyped) <-
      withLocal localId LocalBinding {localType = agentType} $
        walkStatements rest continuation
    pure (result, StatementAgent typedDeclaration : restTyped)
  _ -> do
    reportNotYetSupported declaration.sourceSpan "Local agent must resolve to a local variable"
    (result, restTyped) <- walkStatements rest continuation
    -- Best-effort: still type-check the declaration's body and emit the typed declaration.
    (typedDeclaration, _) <- synthAgent declaration
    pure (result, StatementAgent typedDeclaration : restTyped)

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
  binderInfo <- extractUseBinder useStmt.binder useStmt.sourceSpan
  let bindingType = maybe nullType snd binderInfo
      bindings = case binderInfo of
        Just (localId, valueType) -> [(localId, LocalBinding {localType = valueType})]
        Nothing -> []
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
    Nothing ->
      reportNotYetSupported useStmt.sourceSpan "`use` provider must be a callable agent type"
  -- Retag the binder pattern (if any) to Typed by re-running checkPattern against the binder type.
  typedBinder <- case useStmt.binder of
    Nothing -> pure Nothing
    Just patternNode -> do
      (typedPat, _, _) <- checkPattern patternNode bindingType
      pure (Just typedPat)
  pure
    UseStatement
      { binder = typedBinder,
        provider = typedProvider,
        body = typedBody,
        sourceSpan = useStmt.sourceSpan
      }

extractUseBinder ::
  Maybe (Pattern Identified) ->
  SourceSpan ->
  Checker (Maybe (LocalVariableId, NormalizedType))
extractUseBinder Nothing _ = pure Nothing
extractUseBinder (Just patternNode) sourceSpan = case patternNode of
  PatternVariable variablePattern ->
    case (variablePattern.variableReference.resolution, variablePattern.typeAnnotation) of
      (Just (VariableResolutionLocalVariable localId), Just annotation) -> do
        valueType <- elaborateAndNormalizeType annotation
        pure (Just (localId, valueType))
      (Just (VariableResolutionLocalVariable localId), Nothing) -> do
        reportNotYetSupported sourceSpan "`let x = use ...` requires an explicit type annotation on x (Q1)"
        pure (Just (localId, bottomType))
      _ -> do
        reportNotYetSupported sourceSpan "`use` binder must resolve to a local variable"
        pure Nothing
  _ -> do
    reportNotYetSupported sourceSpan "Pattern destructuring in `use` binder is not yet supported"
    pure Nothing

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
  nt <- case expression.variableReference.resolution of
    Just (VariableResolutionLocalVariable localId) -> do
      maybeBinding <- asks (\environment -> Map.lookup localId environment.locals)
      case maybeBinding of
        Just binding -> pure binding.localType
        Nothing -> do
          reportNotYetSupported expression.sourceSpan "Local variable is not in scope (checker invariant)"
          pure bottomType
    Just (VariableResolutionQualifiedName qualifiedName) -> do
      maybeValue <- asks (\environment -> Map.lookup qualifiedName environment.valueEnvironment)
      case maybeValue of
        Just info -> pure info.valueType
        Nothing -> do
          reportNotYetSupported expression.sourceSpan ("Top-level value not yet registered: " <> qualifiedName.name)
          pure bottomType
    Nothing -> pure bottomType
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
  nt <- case expression.variableReference.resolution of
    Just (VariableResolutionQualifiedName qualifiedName) -> do
      maybeValue <- asks (\environment -> Map.lookup qualifiedName environment.valueEnvironment)
      case maybeValue of
        Just info -> pure info.valueType
        Nothing -> do
          reportNotYetSupported expression.sourceSpan ("Top-level value not yet registered: " <> qualifiedName.name)
          pure bottomType
    _ -> pure bottomType
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
      reportNotYetSupported expression.sourceSpan "Field access on a non-object type"
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
  mapM_ elaborateAndIgnore expression.typeArguments
  (typedCallee, nt) <- synthExpression expression.callee
  semantic <- denormalizeAt expression.sourceSpan nt
  pure
    ( ExpressionTypeApplication
        TypeApplicationExpression
          { callee = typedCallee,
            typeArguments = retagSyntacticTypeExpression <$> expression.typeArguments,
            instantiation = mempty,
            sourceSpan = expression.sourceSpan,
            typeOf = semantic
          },
      nt
    )
  where
    elaborateAndIgnore argument = do
      _ <- runElaborator (elaborateAsType argument)
      pure ()

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
      reportNotYetSupported
        expression.sourceSpan
        "Callee is not a single function type (multi-layer, generic, or non-function callees are not yet supported)"
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

collectFunctionAttributes :: NormalizedFunction -> NormalizedAttribute
collectFunctionAttributes function =
  joinAttribute
    (collectAttributeUnion function.argumentType)
    (collectAttributeUnion function.returnType)

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
      reportNotYetSupported returnStmt.sourceSpan "`return` is only allowed inside an agent body"
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
      reportNotYetSupported forNextStmt.sourceSpan "`next` outside a `for` body"
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
      (typed, valueType) <- synthExpression forBreakStmt.value
      runNormalizer forBreakStmt.sourceSpan (subtype valueType frame.breakResultType)
      emitForNextType forBreakStmt.sourceSpan valueType
      pure typed
    [] -> do
      reportNotYetSupported forBreakStmt.sourceSpan "`break` outside a `for` body"
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

checkModifiers :: List (Modifier Identified) -> Checker (List (Modifier Typed))
checkModifiers = traverse checkOneModifier
  where
    checkOneModifier modifier = case modifier.variableReference.resolution of
      Just (VariableResolutionLocalVariable localId) -> do
        maybeBinding <- asks (\environment -> Map.lookup localId environment.locals)
        case maybeBinding of
          Just binding -> do
            typedValue <- checkExpression modifier.value binding.localType
            pure
              Modifier
                { name = modifier.name,
                  variableReference = retagReference modifier.variableReference,
                  value = typedValue,
                  sourceSpan = modifier.sourceSpan
                }
          Nothing -> do
            reportNotYetSupported modifier.sourceSpan "Modifier target is not a state variable in scope"
            (typed, _) <- synthExpression modifier.value
            pure
              Modifier
                { name = modifier.name,
                  variableReference = retagReference modifier.variableReference,
                  value = typed,
                  sourceSpan = modifier.sourceSpan
                }
      _ -> do
        reportNotYetSupported modifier.sourceSpan "Modifier target must resolve to a state variable"
        (typed, _) <- synthExpression modifier.value
        pure
          Modifier
            { name = modifier.name,
              variableReference = retagReference modifier.variableReference,
              value = typed,
              sourceSpan = modifier.sourceSpan
            }

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
      reportNotYetSupported breakStmt.sourceSpan "`break` outside a request handler body"
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
      reportNotYetSupported nextStmt.sourceSpan "`next` outside a request handler body"
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
  Checker (Pattern Typed, NormalizedType, List (LocalVariableId, LocalBinding))
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
        Nothing -> do
          reportNotYetSupported constructorPattern.sourceSpan "Data type not registered in the type environment (internal)"
          fallbackConstructorPattern constructorPattern topType []
    _ -> do
      reportNotYetSupported constructorPattern.sourceSpan "Constructor pattern must reference a data type"
      fallbackConstructorPattern constructorPattern topType []
  where
    bindingsFor maybeLocal bindingType = case maybeLocal of
      Just localId -> [(localId, LocalBinding {localType = bindingType})]
      Nothing -> []
    fallbackConstructorPattern node cover bindings = do
      semantic <- denormalizeAt node.sourceSpan cover
      pure
        ( PatternConstructor
            ConstructorPattern
              { moduleQualifier = retagModuleQualifier <$> node.moduleQualifier,
                name = node.name,
                constructorReference = retagReference node.constructorReference,
                genericArguments = retagSyntacticTypeExpression <$> node.genericArguments,
                instantiation = mempty,
                fields = [],
                sourceSpan = node.sourceSpan,
                typeOf = semantic
              },
          cover,
          bindings
        )

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
  Checker (Text, NormalizedType, List (LocalVariableId, LocalBinding), FieldPattern Typed)
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
  nt <- case results of
    [] -> do
      reportNotYetSupported expression.sourceSpan "Match expression must have at least one case"
      pure bottomType
    ((firstCover, firstBody, _) : rest) -> do
      let restCovers = [c | (c, _, _) <- rest]
          restBodies = [b | (_, b, _) <- rest]
      unionCover <- foldM combineUnion firstCover restCovers
      unionBodyType <- foldM combineUnion firstBody restBodies
      runNormalizer expression.sourceSpan (subtype scrutineeType unionCover)
      pure unionBodyType
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
    reportNotYetSupported sourceSpan "`for` source must be a sequence (array or tuple) type"
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
    Just localId -> withLocal localId LocalBinding {localType = initialType} (continuation typedBinding)
    Nothing -> do
      reportNotYetSupported binding.sourceSpan "Variable binding must resolve to a local"
      continuation typedBinding

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
      (_, results) <-
        withEffectInference $
          traverse (walkRequestHandler resultType residualEffect) expression.handlers
      let names = mapMaybe fst results
          typedHs = snd <$> results
      pure (names, typedHs)
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
      (_, typedBody) <-
        withEffectInference $
          withParameters thenBindings $ do
            (tb, nt) <- synthBlock thenClause.body
            runNormalizer thenClause.sourceSpan (subtype nt resultType)
            pure tb
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
    reportNotYetSupported
      expression.sourceSpan
      "handler[R, E] requires exactly two generic arguments (Q1: handler generics are explicit)"
    pure (bottomType, bottomEffect)

walkRequestHandler ::
  NormalizedType ->
  NormalizedEffect ->
  RequestHandler Identified ->
  Checker (Maybe QualifiedName, RequestHandler Typed)
walkRequestHandler resultType residualEffect handler = case handler.typeReference.resolution of
  Just (TypeResolutionQualifiedName requestName) -> do
    requestEnv <- asks (\environment -> environment.typeEnvironment.requestEnvironment)
    case Map.lookup requestName requestEnv of
      Just requestInfo -> do
        substitution <-
          buildGenericSubstitution
            handler.sourceSpan
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
        ((typedBlock, _), _) <-
          pushHandleContext context $
            withParameters paramBindings $
              withBodyTypedReturn handler.body
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
        pure (Just requestName, typedHandler)
      Nothing -> do
        reportNotYetSupported handler.sourceSpan "Request not registered in the type environment (internal)"
        fallbackHandler
  _ -> do
    reportNotYetSupported handler.sourceSpan "Request handler must reference a request"
    fallbackHandler
  where
    fallbackHandler = do
      (_, _, typedParams) <- buildParameterScopeTyped handler.parameters
      (typedBlock, _) <- synthBlock handler.body
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
      pure (Nothing, typedHandler)

-- | Walk the body of a request handler returning the typed block.
withBodyTypedReturn :: Block Identified -> Checker ((Block Typed, NormalizedType), ())
withBodyTypedReturn block = do
  result <- synthBlock block
  pure (result, ())

buildGenericSubstitution ::
  SourceSpan ->
  GenericParameters ->
  List (SyntacticTypeExpression Identified) ->
  Checker (Map GenericId NormalizedKindedType)
buildGenericSubstitution sourceSpan parameters argumentExpressions = do
  let parameterNames = parameters.parameterNames
      parameterInfo = parameters.parameterInformation
  if length parameterNames /= length argumentExpressions
    then do
      reportNotYetSupported sourceSpan "Wrong number of explicit generic arguments"
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

synthAgent :: AgentDeclaration Identified -> Checker (AgentDeclaration Typed, NormalizedType)
synthAgent declaration = do
  (agentOuterAttribute, declaredAttribute) <- agentAttributes declaration
  (parameterObject, parameterBindings, typedParams) <- buildParameterScopeTyped declaration.parameters
  annotatedReturnType <- traverse elaborateAndNormalizeType declaration.returnType
  annotatedEffect <- traverse elaborateAndNormalizeEffect declaration.effects
  (inferredEffect, (typedBody, bodyReturnType)) <-
    withEffectInference $ case annotatedReturnType of
      Just expected -> do
        typedB <-
          withWorld declaredAttribute
            . withParameters parameterBindings
            . withReturnTarget expected
            $ checkBlock declaration.body expected
        pure (typedB, expected)
      Nothing ->
        withWorld declaredAttribute
          . withParameters parameterBindings
          . withReturnTarget topType
          $ synthBlock declaration.body
  finalEffect <- case annotatedEffect of
    Just declared -> do
      runNormalizer declaration.sourceSpan (subtype inferredEffect declared)
      pure declared
    Nothing -> pure inferredEffect
  let typedDeclaration =
        AgentDeclaration
          { annotation = declaration.annotation,
            private = declaration.private,
            name = declaration.name,
            variableReference = retagReference declaration.variableReference,
            genericParameters = retagGenericParameter <$> declaration.genericParameters,
            parameters = typedParams,
            returnType = retagSyntacticTypeExpression <$> declaration.returnType,
            effects = retagSyntacticTypeExpression <$> declaration.effects,
            body = typedBody,
            sourceSpan = declaration.sourceSpan
          }
  pure (typedDeclaration, assembleAgent agentOuterAttribute parameterObject bodyReturnType finalEffect)

synthAgentType :: AgentDeclaration Identified -> Checker NormalizedType
synthAgentType = fmap snd . synthAgent

buildAgentSeed :: AgentDeclaration Identified -> Checker NormalizedType
buildAgentSeed declaration = do
  (agentOuterAttribute, _) <- agentAttributes declaration
  (parameterObject, _, _) <- buildParameterScopeTyped declaration.parameters
  annotatedReturnType <- traverse elaborateAndNormalizeType declaration.returnType
  annotatedEffect <- traverse elaborateAndNormalizeEffect declaration.effects
  when (isNothing declaration.returnType) $
    reportNotYetSupported
      declaration.sourceSpan
      "Return type annotation is required for an agent in a (mutually) recursive group"
  when (isNothing declaration.effects) $
    reportNotYetSupported
      declaration.sourceSpan
      "Effect annotation is required for an agent in a (mutually) recursive group"
  pure $
    assembleAgent
      agentOuterAttribute
      parameterObject
      (fromMaybe bottomType annotatedReturnType)
      (fromMaybe bottomEffect annotatedEffect)

checkAgentBody ::
  AgentDeclaration Identified ->
  NormalizedType ->
  Checker (AgentDeclaration Typed)
checkAgentBody declaration seed = do
  (_, declaredAttribute) <- agentAttributes declaration
  (_, parameterBindings, typedParams) <- buildParameterScopeTyped declaration.parameters
  typedBody <- case extractFunction seed of
    Just (_, function) -> do
      (inferredEffect, typedB) <-
        withEffectInference
          $ withWorld declaredAttribute
            . withParameters parameterBindings
            . withReturnTarget function.returnType
          $ checkBlock declaration.body function.returnType
      runNormalizer declaration.sourceSpan (subtype inferredEffect function.effect)
      pure typedB
    Nothing -> do
      (typedB, _) <- synthBlock declaration.body
      pure typedB
  pure
    AgentDeclaration
      { annotation = declaration.annotation,
        private = declaration.private,
        name = declaration.name,
        variableReference = retagReference declaration.variableReference,
        genericParameters = retagGenericParameter <$> declaration.genericParameters,
        parameters = typedParams,
        returnType = retagSyntacticTypeExpression <$> declaration.returnType,
        effects = retagSyntacticTypeExpression <$> declaration.effects,
        body = typedBody,
        sourceSpan = declaration.sourceSpan
      }

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

-- | Build the parameter object type, per-parameter bindings, and per-parameter Typed nodes.
buildParameterScopeTyped ::
  List (ParameterBinding Identified) ->
  Checker
    ( NormalizedType,
      List (LocalVariableId, LocalBinding),
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
                          [ (name, NormalizedFieldInformation {normalizedType = normalizedType, optional = False})
                            | (name, _, normalizedType, _) <- entries
                          ],
                      rest = unknownType
                    }
            }
      bindings =
        [ (localId, LocalBinding {localType = normalizedType})
          | (_, Just localId, normalizedType, _) <- entries
        ]
      typedParameters = [tp | (_, _, _, tp) <- entries]
  pure (parameterObject, bindings, typedParameters)
  where
    buildOne parameter = case parameter.bindPattern of
      PatternVariable variablePattern ->
        case (variablePattern.variableReference.resolution, variablePattern.typeAnnotation) of
          (Just (VariableResolutionLocalVariable localId), Just annotation) -> do
            parameterType <- elaborateAndNormalizeType annotation
            (typedPattern, _, _) <- checkPattern parameter.bindPattern parameterType
            let typedBinding = mkTypedParameter parameter typedPattern
            pure (parameter.name, Just localId, parameterType, typedBinding)
          (Just (VariableResolutionLocalVariable localId), Nothing) -> do
            reportNotYetSupported parameter.sourceSpan "Agent parameter requires a type annotation"
            (typedPattern, _, _) <- checkPattern parameter.bindPattern bottomType
            let typedBinding = mkTypedParameter parameter typedPattern
            pure (parameter.name, Just localId, bottomType, typedBinding)
          _ -> do
            reportNotYetSupported parameter.sourceSpan "Agent parameter must resolve to a local variable"
            (typedPattern, _, _) <- checkPattern parameter.bindPattern bottomType
            let typedBinding = mkTypedParameter parameter typedPattern
            pure (parameter.name, Nothing, bottomType, typedBinding)
      _ -> do
        reportNotYetSupported parameter.sourceSpan "Pattern destructuring in agent parameters is not yet supported"
        (typedPattern, _, _) <- checkPattern parameter.bindPattern bottomType
        let typedBinding = mkTypedParameter parameter typedPattern
        pure (parameter.name, Nothing, bottomType, typedBinding)
    mkTypedParameter parameter typedPattern =
      ParameterBinding
        { annotation = parameter.annotation,
          name = parameter.name,
          labelReference = retagReference parameter.labelReference,
          bindPattern = typedPattern,
          sourceSpan = parameter.sourceSpan
        }

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

reportNotYetSupported :: SourceSpan -> Text -> Checker ()
reportNotYetSupported sourceSpan reason =
  tell (diagnosticAt sourceSpan (CompilerErrorType (TypeErrorMalformedType MalformedTypeErrorInfo {reason = reason})))

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
