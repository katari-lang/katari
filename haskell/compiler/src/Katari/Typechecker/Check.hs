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
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestInformation (..), Scheme (..), instantiationByName, monoScheme, reKeyByGenericId)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId, LocalVariableId, TypeResolution (..), VariableResolution (..))
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName (..), renderQualifiedName)
import Katari.Data.SemanticType (SemanticGenericArgument (..), SemanticType)
import Katari.Data.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Data.Variance (Variance (..))
import Katari.Diagnostics (diagnosticAt)
import Katari.Error
  ( ApplicationArityErrorInfo (..),
    CannotInferGenericErrorInfo (..),
    CompilerError (..),
    ExpectedShapeErrorInfo (..),
    GenericNotAppliedErrorInfo (..),
    MisplacedJumpErrorInfo (..),
    MissingAnnotationErrorInfo (..),
    TypeError (..),
    WrongReferenceKindErrorInfo (..),
  )
import Katari.Panic (panic)
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment (..),
    currentWorld,
    emitContinue,
    emitEffect,
    emitExit,
    enterAgentBody,
    enterForBody,
    enterHandlerThen,
    enterRequestHandler,
    freshBoundaryId,
    freshGenericId,
    runElaborator,
    runNormalizer,
    withEffectInference,
    withGeneric,
    withLocal,
    withParameters,
    withWorld,
  )
import Katari.Typechecker.Elaborate (elaborate, elaborateAsAttribute, elaborateAsEffect, elaborateAsType, schemeVariableFor)
import Katari.Typechecker.Environment (TypeEnvironment (..), collectGenericParameters, stampBound)
import Katari.Typechecker.Inference (Metavar (..), Registry, SolveResult (..), collectConstraints, metavarKinded, solveConstraints)
import Katari.Typechecker.Normalizer (boundedType, checkBounds, checkGenericBounds, denormalize, denormalizeGenericArgument, foldAttribute, intersect, joinAttribute, normalizeAttribute, normalizeEffect, normalizeGenericArgument, normalizeType, objectAsType, substituteGenericArgument, substituteObject, substituteType, subtype, union)

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
  -- Operators are desugared into generic @primitive.*@ calls by the identifier, so they never reach
  -- the checker; their typing (including generic inference of the operand type) goes through
  -- 'synthCallExpression' like any other call.
  ExpressionBinaryOperator _ -> panic "synthExpression: binary operator survived past the identifier desugar"
  ExpressionUnaryOperator _ -> panic "synthExpression: unary operator survived past the identifier desugar"
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

-- | A block's type is its trailing expression's type, or @null@ if absent — unless the block makes a
-- global exit ('statementExits'), in which case its fall-through is unreachable and its type is
-- @never@.
synthBlock :: Block Identified -> Checker (Block Typed, NormalizedType)
synthBlock block = do
  ((typedReturn, trailingType), typedStatements) <-
    walkStatements block.statements $ case block.returnExpression of
      Just expression -> do
        (typedValue, resultType) <- synthExpression expression
        pure (Just typedValue, resultType)
      Nothing -> pure (Nothing, nullType)
  pure
    ( Block
        { statements = typedStatements,
          returnExpression = typedReturn,
          sourceSpan = block.sourceSpan
        },
      if blockExits block then bottomType else trailingType
    )

checkBlock :: Block Identified -> NormalizedType -> Checker (Block Typed)
checkBlock block expected = do
  let diverges = blockExits block
  (typedReturn, typedStatements) <-
    walkStatements block.statements $ case block.returnExpression of
      Just expression
        -- A diverging block's tail is unreachable: synthesize it (for the typed AST) but do not
        -- constrain it against the expectation.
        | diverges -> Just . fst <$> synthExpression expression
        | otherwise -> Just <$> checkExpression expression expected
      Nothing -> do
        unless diverges $ runNormalizer block.sourceSpan (subtype nullType expected)
        pure Nothing
  pure
    Block
      { statements = typedStatements,
        returnExpression = typedReturn,
        sourceSpan = block.sourceSpan
      }

-- | Whether a block makes a global exit, so control never reaches its tail. True once any statement
-- transfers control out of the block: a @return@ / @break@ / @next@ jump, or a @use@ (which delegates
-- the rest of the block to its continuation). Such a block's value type is @never@.
blockExits :: Block phase -> Bool
blockExits block = any statementExits block.statements

statementExits :: Statement phase -> Bool
statementExits = \case
  StatementReturn _ -> True
  StatementBreak _ -> True
  StatementNext _ -> True
  StatementForBreak _ -> True
  StatementForNext _ -> True
  StatementUse _ -> True
  _ -> False

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
walkStatements statements continuation = case statements of
  [] -> do
    result <- continuation
    pure (result, [])
  statement : rest ->
    -- @let@ and a local @agent@ extend the scope of the remaining statements, so they own the recursion;
    -- every other statement is a pass-through that types itself and cons-es onto the walked rest.
    let passThrough makeTyped = do
          typedStatement <- makeTyped
          (result, restTyped) <- walkStatements rest continuation
          pure (result, typedStatement : restTyped)
     in case statement of
          StatementLet letStmt -> runLetStatement letStmt rest continuation
          StatementAgent agentDeclaration -> runLocalAgentStatement agentDeclaration rest continuation
          StatementExpression expression -> passThrough (StatementExpression . fst <$> synthExpression expression)
          StatementUse useStmt -> passThrough (StatementUse <$> handleUseStatement useStmt)
          StatementReturn returnStmt -> passThrough (StatementReturn <$> checkReturnStatement returnStmt)
          StatementForNext forNextStmt -> passThrough (StatementForNext <$> checkForNextStatement forNextStmt)
          StatementForBreak forBreakStmt -> passThrough (StatementForBreak <$> checkForBreakStatement forBreakStmt)
          StatementBreak breakStmt -> passThrough (StatementBreak <$> checkBreakStatement breakStmt)
          StatementNext nextStmt -> passThrough (StatementNext <$> checkNextStatement nextStmt)
          StatementError s -> passThrough (pure (StatementError s))

-- | A @let@ binding: compute the value's type (against an annotation if present), bind, walk the
-- rest in the extended scope, and produce the typed let statement.
runLetStatement ::
  LetStatement Identified ->
  List (Statement Identified) ->
  Checker a ->
  Checker (a, List (Statement Typed))
runLetStatement letStmt rest continuation = do
  -- A variable binder takes its scrutinee from its annotation (or the synthesized value type) and binds
  -- exactly its one local; any other pattern destructures the synthesized value type into its bindings.
  (typedValue, typedPattern, bindings) <- case letStmt.pattern of
    PatternVariable variablePattern -> case variablePattern.variableReference.resolution of
      Just (VariableResolutionLocalVariable localId) -> do
        (typedValue, bindingType) <- case variablePattern.typeAnnotation of
          Just annotation -> do
            annotatedType <- elaborateAndNormalizeType annotation
            typedValue <- checkExpression letStmt.value annotatedType
            pure (typedValue, annotatedType)
          Nothing -> synthExpression letStmt.value
        (typedPattern, _, _) <- checkPattern letStmt.pattern bindingType
        pure (typedValue, typedPattern, [(localId, monoScheme bindingType)])
      _ -> panic "runLetStatement: let-bound variable is not resolved to a local"
    otherPattern -> do
      (typedValue, valueType) <- synthExpression letStmt.value
      (typedPattern, _, bindings) <- checkPattern otherPattern valueType
      pure (typedValue, typedPattern, bindings)
  (result, restTyped) <- withParameters bindings (walkStatements rest continuation)
  let typedLetStmt = LetStatement {pattern = typedPattern, value = typedValue, sourceSpan = letStmt.sourceSpan}
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
-- @{ stmts_before; h(continuation = agent({value: A}) -> R with E' { stmts_after; e }) }@.
-- @x@'s annotation is required (the continuation's value type A), R is the continuation body's /tail/
-- (its trailing value — a @return@ inside it short-circuits the enclosing agent, not the continuation,
-- so it does not contribute to R), and E' is the continuation body's /inferred/ effect (so the subtype
-- check against the provider's expected continuation effect enforces "body effects ⊆ what the handler
-- expects").
------------------------------------------------------------------------------------------------

handleUseStatement :: UseStatement Identified -> Checker (UseStatement Typed)
handleUseStatement useStmt = do
  -- The binder declares the continuation's value type A (required); without a binder the continuation
  -- receives null.
  (bindingType, typedBinder, bindings) <- case useStmt.binder of
    Nothing -> pure (nullType, Nothing, [])
    Just patternNode -> do
      (declaredType, typedPattern, binderBindings) <-
        checkAnnotatedBinder "`use` binder requires an explicit type annotation" patternNode
      pure (declaredType, Just typedPattern, binderBindings)
  -- The continuation is the rest of the block; its result R is its trailing value, synthesized in the
  -- /current/ context — no new return target is pushed, so a @return@ inside escapes to the enclosing
  -- agent (caught at the agent edge) rather than ending the continuation.
  (inferredContinuationEffect, (typedBody, resultType)) <-
    withEffectInference $
      withParameters bindings $
        synthBlock useStmt.body
  let providerExpectedArgument = continuationExpectedArgument bindingType resultType inferredContinuationEffect
  -- Apply the provider to the continuation argument through the shared callee-application rule, so a
  -- @use@ provider is held to the same world / effect discipline as a direct call AND gets the same
  -- generic-argument inference: a provider generic in its continuation result @R@ has @R@ inferred from
  -- this continuation argument (whose return type is the continuation body's tail).
  (typedProvider, scheme) <- synthApplicationCallee useStmt.provider
  argumentAttribute <- runNormalizer useStmt.sourceSpan (foldAttribute providerExpectedArgument)
  _ <- applyCallee useStmt.sourceSpan scheme providerExpectedArgument argumentAttribute
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
  typedExpression expression.sourceSpan (synthLiteralValue expression.value) $ \semantic ->
    ExpressionLiteral
      LiteralExpression
        { value = expression.value,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

synthLiteralValue :: LiteralValue -> NormalizedType
synthLiteralValue = \case
  LiteralValueInteger _ -> integerType
  LiteralValueNumber _ -> numberType
  LiteralValueString _ -> stringType
  LiteralValueBoolean _ -> booleanType
  LiteralValueNull -> nullType

-- | The type a literal /pattern/ contributes to match exhaustiveness. @null@ and the two booleans are
-- the only finitely-enumerable values, so they cover themselves (@{ true => …; false => … }@ is
-- exhaustive); an integer / number / string literal has no singleton type, so it covers nothing —
-- only a wildcard, variable, or type-filter pattern can cover those.
literalPatternCover :: LiteralValue -> NormalizedType
literalPatternCover = \case
  LiteralValueBoolean value -> booleanSingleton value
  LiteralValueNull -> nullType
  _ -> bottomType

synthVariableExpression :: VariableExpression Identified -> Checker (Expression Typed, NormalizedType)
synthVariableExpression expression = do
  scheme <- lookupScheme expression.variableReference.resolution
  resultType <- instantiateBare expression.sourceSpan scheme
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionVariable
      VariableExpression
        { name = expression.name,
          variableReference = retagReference expression.variableReference,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

synthQualifiedReferenceExpression ::
  QualifiedReferenceExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthQualifiedReferenceExpression expression = do
  scheme <- lookupScheme expression.variableReference.resolution
  resultType <- instantiateBare expression.sourceSpan scheme
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionQualifiedReference
      QualifiedReferenceExpression
        { moduleQualifier = retagModuleQualifier expression.moduleQualifier,
          name = expression.name,
          variableReference = retagReference expression.variableReference,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

synthTupleExpression :: TupleExpression Identified -> Checker (Expression Typed, NormalizedType)
synthTupleExpression expression = do
  results <- traverse synthExpression expression.elements
  let (typedElements, elementTypes) = unzip results
      resultType =
        layeredOf
          neverLayer
            { sequenceLayer = Just NormalizedSequence {items = elementTypes, rest = bottomType}
            }
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionTuple
      TupleExpression
        { parallel = expression.parallel,
          elements = typedElements,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

synthRecordExpression :: RecordExpression Identified -> Checker (Expression Typed, NormalizedType)
synthRecordExpression expression = do
  -- Duplicate field labels are rejected in the identifier phase (K2003), so keying the field map by
  -- name here drops nothing.
  entries <- traverse synthEntry expression.entries
  let resultType = namedObjectType [(name, fieldType) | (_, name, fieldType) <- entries]
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionRecord
      RecordExpression
        { entries = [typedEntry | (typedEntry, _, _) <- entries],
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }
  where
    synthEntry entry = do
      (typedValue, fieldType) <- synthExpression entry.value
      pure (RecordEntry {name = entry.name, value = typedValue, sourceSpan = entry.sourceSpan}, entry.name, fieldType)

synthIfExpression :: IfExpression Identified -> Checker (Expression Typed, NormalizedType)
synthIfExpression expression = do
  (typedCondition, conditionType) <- synthExpression expression.condition
  -- The condition must be a boolean; like a match scrutinee its attribute is observed, so it is checked
  -- as @boolean of <its attribute>@ rather than forced public (a private condition is allowed, and
  -- carries its world into a pure branch's result below).
  conditionAttribute <- runNormalizer (sourceSpanOf expression.condition) (foldAttribute conditionType)
  runNormalizer (sourceSpanOf expression.condition) (subtype conditionType (liftByAttribute conditionAttribute booleanType))
  (typedThen, thenType) <- processObserved expression.sourceSpan conditionAttribute (synthBlock expression.thenBlock)
  (typedElse, elseType) <- case expression.elseBlock of
    Just block -> do
      (typedBlock, blockType) <- processObserved expression.sourceSpan conditionAttribute (synthBlock block)
      pure (Just typedBlock, blockType)
    -- A missing else yields @null@ when the condition is false; that branch is pure, so it too carries
    -- the condition's world.
    Nothing -> pure (Nothing, liftByAttribute conditionAttribute nullType)
  resultType <- runNormalizer expression.sourceSpan (union thenType elseType)
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionIf
      IfExpression
        { condition = typedCondition,
          thenBlock = typedThen,
          elseBlock = typedElse,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

synthBlockExpression :: BlockExpression Identified -> Checker (Expression Typed, NormalizedType)
synthBlockExpression expression = do
  (typedBlock, resultType) <- synthBlock expression.block
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionBlock
      BlockExpression
        { block = typedBlock,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

synthFieldAccessExpression ::
  FieldAccessExpression Identified ->
  Checker (Expression Typed, NormalizedType)
synthFieldAccessExpression expression = do
  (typedObject, objectType) <- synthExpression expression.object
  maybeField <- maybeReadField expression.sourceSpan expression.fieldName objectType
  resultType <- case maybeField of
    Just fieldType -> pure fieldType
    Nothing -> do
      reportExpectedShape expression.sourceSpan "an object" objectType
      pure bottomType
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionFieldAccess
      FieldAccessExpression
        { object = typedObject,
          fieldName = expression.fieldName,
          labelReference = retagReference expression.labelReference,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

-- | Read field @fieldName@ from a value, raising its generics to their bounds first (a field of a
-- bounded generic reads at the bound). Yields 'Nothing' when the raised value has no object / data
-- shape to read from. Shared by field-access expressions and record-pattern field scrutinees.
maybeReadField :: SourceSpan -> Text -> NormalizedType -> Checker (Maybe NormalizedType)
maybeReadField sourceSpan fieldName valueType =
  -- A field read requires the value to be solely object / data shaped: a @{x: T} | null@ (or
  -- @… | number@) value is not read through, so the dropped @null@ can no longer surface as a
  -- non-null field type. The field type is lifted by the container's handle attribute in 'withSoleLayer'.
  withSoleLayer sourceSpan (Set.fromList [ObjectKind, DataKind]) valueType $ \layer ->
    if isJust layer.objectLayer || not (Map.null layer.dataLayer)
      then Just <$> fieldOfLayer sourceSpan fieldName layer
      else pure Nothing

-- | The type of a field read from a value's layer: the union over its structural object (if any) and
-- every nominal data type it may be (each data type's constructor object, instantiated). Subtyping
-- already relates a data value to its fields, so a field access is the read at that relation.
fieldOfLayer :: SourceSpan -> Text -> LayeredType -> Checker NormalizedType
fieldOfLayer sourceSpan fieldName layer = do
  let structural = maybe [] (\object -> [objectFieldType object fieldName]) layer.objectLayer
  nominal <- traverse (dataFieldType sourceSpan fieldName) (Map.toList layer.dataLayer)
  foldM (\accumulated fieldType -> runNormalizer sourceSpan (union accumulated fieldType)) bottomType (structural <> nominal)

-- | A field's type in an object. A required field reads as its declared type. An optional field, or
-- an undeclared key read through @rest@, may be absent, so @null@ is unioned in at the read site (the
-- field type is stored bare — "present then this type" — and the @?@ widening is applied here).
objectFieldType :: NormalizedObject -> Text -> NormalizedType
objectFieldType object fieldName = case Map.lookup fieldName object.fields of
  Just field
    | field.optional -> orNull field.normalizedType
    | otherwise -> field.normalizedType
  Nothing -> orNull object.rest

-- | A field's type in a nominal data value: the data type's constructor object instantiated with the
-- value's generic arguments, then read like any object.
dataFieldType :: SourceSpan -> Text -> (QualifiedName, Map Text NormalizedKindedType) -> Checker NormalizedType
dataFieldType sourceSpan fieldName entry = do
  constructorObject <- dataConstructorObject sourceSpan entry
  pure (objectFieldType constructorObject fieldName)

-- | A nominal data value's constructor object instantiated with the value's generic arguments — its
-- /read shape/ (every field required). The single home of "instantiate a data type's constructor",
-- shared by field reads ('dataFieldType') and the @record@ type filter ('filterSlot').
dataConstructorObject :: SourceSpan -> (QualifiedName, Map Text NormalizedKindedType) -> Checker NormalizedObject
dataConstructorObject sourceSpan (dataName, arguments) = do
  dataEnvironment <- asks (\environment -> environment.typeEnvironment.dataEnvironment)
  case Map.lookup dataName dataEnvironment of
    Just info -> runNormalizer sourceSpan (substituteObject (reKeyByGenericId info.genericParameters arguments) info.constructor)
    Nothing -> panic ("dataConstructorObject: data type not registered: " <> renderQualifiedName dataName)

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
  instantiation <- instantiationOf expression.sourceSpan scheme.genericParameters substitution
  typedExpression expression.sourceSpan instantiated $ \semantic ->
    ExpressionTypeApplication
      TypeApplicationExpression
        { callee = typedCallee,
          typeArguments = retagSyntacticTypeExpression <$> expression.typeArguments,
          instantiation = instantiation,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

-- | The callee of a generic application paired with its (uninstantiated) scheme. A direct value
-- reference contributes its full scheme — the only source of a generic value — so its generics are
-- not flagged as an unapplied generic reference here (that check is 'instantiateBare', for bare
-- uses); any other callee is non-generic, and supplying type arguments to it is an arity error in
-- 'buildGenericSubstitution'.
synthApplicationCallee :: Expression Identified -> Checker (Expression Typed, Scheme)
synthApplicationCallee = \case
  ExpressionVariable variable -> do
    scheme <- lookupScheme variable.variableReference.resolution
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
    scheme <- lookupScheme reference.variableReference.resolution
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
  -- A handler is a generic value over its result @R@ and effect @E@ (see 'checkHandlerScheme'); in
  -- application position its scheme is handed up so the continuation argument infers @R@ / @E@, exactly
  -- as for any generic callee. The node keeps the (uninstantiated) scheme type; the application records
  -- the inferred arguments.
  ExpressionHandler expression -> do
    (components, scheme) <- checkHandlerScheme expression
    node <- assembleHandlerNode components (ownHandlerInstantiation scheme) scheme.valueType
    pure (node, scheme)
  other -> do
    (typedCallee, calleeType) <- synthExpression other
    pure (typedCallee, monoScheme calleeType)

synthTemplateExpression :: TemplateExpression Identified -> Checker (Expression Typed, NormalizedType)
synthTemplateExpression expression = do
  typedElements <- traverse synthElement expression.elements
  typedExpression expression.sourceSpan stringType $ \semantic ->
    ExpressionTemplate
      TemplateExpression
        { elements = typedElements,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }
  where
    synthElement = \case
      TemplateElementString stringElement ->
        pure (TemplateElementString stringElement)
      TemplateElementExpression element -> do
        -- An interpolation must be a string; there is no implicit stringification.
        typedValue <- checkExpression element.value stringType
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
  -- Take the callee's full 'Scheme' (not a bare-instantiated type): a generic callee keeps its
  -- quantified parameters here so they can be inferred from the arguments below, rather than being
  -- rejected as an unapplied generic.
  (typedCallee, scheme) <- synthApplicationCallee expression.callee
  (typedArgs, argumentObject, argumentAttribute) <- synthCallArguments expression.sourceSpan expression.arguments
  effectiveReturn <- applyCallee expression.sourceSpan scheme argumentObject argumentAttribute
  typedExpression expression.sourceSpan effectiveReturn $ \semantic ->
    ExpressionCall
      CallExpression
        { callee = typedCallee,
          arguments = typedArgs,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }

-- | Apply a callee (a direct call's callee, or a @use@ provider) to its argument object, dispatching on
-- whether the callee is generic: a non-generic callee must already be callable; a generic one has its
-- type arguments inferred from the argument ('applyGenericValue'). Shared by 'synthCallExpression' and
-- 'handleUseStatement', so a @use@ provider gets the same inference as a direct call — in particular a
-- provider generic in its continuation's result @R@ (e.g. @foo[R](continuation: agent(value: A) -> R)
-- -> R@) infers @R@ from the continuation argument's return type.
applyCallee :: SourceSpan -> Scheme -> NormalizedType -> NormalizedAttribute -> Checker NormalizedType
applyCallee sourceSpan scheme argumentObject argumentAttribute =
  if null scheme.genericParameters.parameterNames
    then applyMonomorphicCallee sourceSpan scheme.valueType argumentObject argumentAttribute
    else applyGenericValue sourceSpan scheme argumentObject argumentAttribute

-- | Apply a non-generic callee: it must already be a callable agent (no inference). A non-callable
-- callee is reported and degrades to bottom.
applyMonomorphicCallee :: SourceSpan -> NormalizedType -> NormalizedType -> NormalizedAttribute -> Checker NormalizedType
applyMonomorphicCallee sourceSpan calleeType argumentObject argumentAttribute = do
  maybeFunction <- extractFunction sourceSpan calleeType
  case maybeFunction of
    Just (functionAttribute, function) -> applyAgent sourceSpan functionAttribute function argumentObject argumentAttribute
    Nothing -> do
      reportExpectedShape sourceSpan "a callable agent" calleeType
      pure bottomType

-- | Raise a type's generics to their declared upper bounds before its shape is inspected, so a value
-- typed as a bounded generic (@F extends agent(...)@, @S extends array[T]@) is usable at its bound.
-- The bounds are folded into the base, so the residual generics set is immaterial to the inspectors.
raiseToBounds :: SourceSpan -> NormalizedType -> Checker NormalizedType
raiseToBounds sourceSpan normalizedType = runNormalizer sourceSpan (boundedType Set.empty normalizedType)

-- | Raise a value's generics to their bounds, then project its base layer with the node's handle
-- attribute. The single home of the "raise to bounds, then inspect one structural layer" idiom every
-- shape inspector ('extractFunction', 'maybeReadField', 'extractTupleElementTypes',
-- 'extractIterableElementType') shares, so none of them can forget the bound-raising step. An
-- @unknown@ value has no layer and yields 'Nothing'.
raisedLayer :: SourceSpan -> NormalizedType -> Checker (Maybe (NormalizedAttribute, LayeredType))
raisedLayer sourceSpan normalizedType = do
  raised <- raiseToBounds sourceSpan normalizedType
  pure $ case raised.baseType of
    NormalizedBaseTypeLayered layer -> Just (raised.attribute, layer)
    NormalizedBaseTypeUnknown -> Nothing

-- | The structural shapes a layered type inhabits. A shape inspector requires a value to be /only/
-- the shape it reads, so a value also carrying @null@ (or another union member outside the expected
-- shape — a @... | null@ union) is rejected rather than silently read through.
data LayerKind
  = NullKind
  | NumberKind
  | StringKind
  | BooleanKind
  | FileKind
  | FunctionKind
  | SequenceKind
  | ObjectKind
  | DataKind
  deriving (Eq, Ord, Show)

-- | Every shape the layered type actually inhabits.
inhabitedKinds :: LayeredType -> Set.Set LayerKind
inhabitedKinds layer =
  Set.fromList $
    concat
      [ [NullKind | layer.nullLayer],
        [NumberKind | layer.numberLayer /= NumberSlotAbsent],
        [StringKind | layer.stringLayer],
        [BooleanKind | not (Set.null layer.booleanLayer)],
        [FileKind | layer.fileLayer],
        [FunctionKind | isJust layer.functionLayer],
        [SequenceKind | isJust layer.sequenceLayer],
        [ObjectKind | isJust layer.objectLayer],
        [DataKind | not (Map.null layer.dataLayer)]
      ]

-- | Like 'raisedLayer', but yields the layer only when every shape the value inhabits is among
-- @allowed@ — so a value that is also @null@ (or any union member outside the expected shape) yields
-- 'Nothing' instead of being read through. The single home of the "this value is solely the shape I
-- inspect" rule every shape inspector ('extractFunction', 'maybeReadField', 'extractIterableElementType',
-- 'extractTupleElementTypes') shares, so none of them can forget it and unsoundly drop a @null@.
soleLayer :: SourceSpan -> Set.Set LayerKind -> NormalizedType -> Checker (Maybe (NormalizedAttribute, LayeredType))
soleLayer sourceSpan allowed normalizedType = do
  raised <- raisedLayer sourceSpan normalizedType
  pure $ case raised of
    Just (attribute, layer) | inhabitedKinds layer `Set.isSubsetOf` allowed -> Just (attribute, layer)
    _ -> Nothing

-- | Read a single interior out of a value through exactly one structural shape, /lifting/ the projected
-- interior by the value's handle attribute. The single home of the "observe an interior through its
-- container" lift, so a strict single-value read cannot forget it: a field / element read off a value
-- private at the handle yields a private interior (no laundering), and nested reads compose because each
-- step lifts by the immediate container's attribute. The value must be solely one of @allowed@
-- ('soleLayer'); @project@ then reads the matched layer, returning 'Nothing' when the layer does not
-- carry what it needs. The two readers that do not go through here are deliberate: 'extractFunction'
-- hands the raw handle attribute to 'applyAgent' (which decides cross-world lifting itself), and
-- 'extractTupleElementTypes' lifts per element (a list, not a single value).
withSoleLayer ::
  SourceSpan ->
  Set.Set LayerKind ->
  NormalizedType ->
  (LayeredType -> Checker (Maybe NormalizedType)) ->
  Checker (Maybe NormalizedType)
withSoleLayer sourceSpan allowed value project = do
  raised <- soleLayer sourceSpan allowed value
  case raised of
    Just (attribute, layer) -> fmap (liftByAttribute attribute) <$> project layer
    Nothing -> pure Nothing

-- | View a value as a callable function, raising its generics to their bounds first. Callable exactly
-- when its raised base is solely a function layer ('soleLayer' rejects a value mixed with @null@ or any
-- other shape); every bound has been folded into the base, so the residual generics set is ignored.
extractFunction :: SourceSpan -> NormalizedType -> Checker (Maybe (NormalizedAttribute, NormalizedFunction))
extractFunction sourceSpan normalizedType = do
  raised <- soleLayer sourceSpan (Set.singleton FunctionKind) normalizedType
  pure $ case raised of
    Just (attribute, layer) | Just function <- layer.functionLayer -> Just (attribute, function)
    _ -> Nothing

synthCallArguments ::
  SourceSpan ->
  List (CallArgument Identified) ->
  Checker (List (CallArgument Typed), NormalizedType, NormalizedAttribute)
synthCallArguments sourceSpan arguments = do
  entries <- traverse synthEntry arguments
  let typedArguments = [typedArg | (typedArg, _, _) <- entries]
      -- A call's arguments are exactly those written, so the object is /closed/ (@rest = never@): an
      -- unwritten field is genuinely absent, which is what lets an omitted optional (defaulted)
      -- parameter match (against a required parameter it still fails the optional<:required check).
      object = namedObjectTypeWithRest bottomType [(name, normalizedType) | (_, name, normalizedType) <- entries]
  liftAmount <-
    runNormalizer sourceSpan $
      foldr joinAttribute bottomAttribute <$> traverse foldAttribute [normalizedType | (_, _, normalizedType) <- entries]
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

-- | Pure = no requests /and/ no escapes. Because a @return@ / @next@ / @break@ now contributes an escape
-- effect, a control-flow branch that escapes is automatically impure here — the single rule that
-- replaces the old per-branch jump-escape bookkeeping.
isPureEffect :: NormalizedEffect -> Bool
isPureEffect effect =
  pureRequests effect.requests && not (hasConcreteEscape effect)
  where
    pureRequests = \case
      RequestEffectAny -> False
      RequestEffectRow row -> Map.null row.request && Map.null row.tails

liftByAttribute :: NormalizedAttribute -> NormalizedType -> NormalizedType
liftByAttribute attribute normalizedType =
  NormalizedType
    { baseType = normalizedType.baseType,
      generics = normalizedType.generics,
      attribute = joinAttribute normalizedType.attribute attribute
    }

-- | Apply an agent value to an argument, enforcing the world rules shared by every application site (a
-- @call@ expression, a @use@ provider). A /pure/ agent may cross attribute worlds by lifting: the
-- agent's own handle attribute and the argument's observable attribute join into the world the result
-- is observed through, so both the expected parameter and the result are lifted by it (a pure private
-- agent applied in a public context yields a private result; a private argument is accepted by an
-- otherwise public pure parameter). A non-pure (monadic) agent cannot be lifted across worlds, so its
-- types are used as-is, the agent must already be callable in the current world
-- (@functionAttribute <: public@), and its effect is re-emitted into the enclosing scope. Returns the
-- (possibly lifted) result type.
applyAgent :: SourceSpan -> NormalizedAttribute -> NormalizedFunction -> NormalizedType -> NormalizedAttribute -> Checker NormalizedType
applyAgent sourceSpan functionAttribute function argumentType argumentAttribute = do
  let pureCall = isPureEffect function.effect
      liftAttribute = joinAttribute functionAttribute argumentAttribute
      (effectiveParameter, effectiveReturn) =
        if pureCall
          then (liftByAttribute liftAttribute function.argumentType, liftByAttribute liftAttribute function.returnType)
          else (function.argumentType, function.returnType)
  runNormalizer sourceSpan (subtype argumentType effectiveParameter)
  unless pureCall $ do
    runNormalizer sourceSpan (subtype functionAttribute bottomAttribute)
    emitEffect sourceSpan function.effect
  pure effectiveReturn

-- | The @continuation@ argument a @use@ provider / handler receives: @{continuation: agent({value: V})
-- -> R with E}@. The single home of the continuation ABI (the @value@ / @continuation@ field names and
-- the agent shape) shared by 'handleUseStatement' and 'synthHandlerExpression'.
continuationExpectedArgument :: NormalizedType -> NormalizedType -> NormalizedEffect -> NormalizedType
continuationExpectedArgument valueType resultType effect =
  namedObjectType [("continuation", assembleAgent bottomAttribute (namedObjectType [("value", valueType)]) resultType effect)]

------------------------------------------------------------------------------------------------
-- Generic-argument inference at call sites
--
-- A generic callee keeps its quantified parameters; this is where they are inferred. The flow is the
-- "propose / dispose" split (see "Katari.Typechecker.Inference"): instantiate the parameters to fresh
-- metavariables, PROPOSE candidate bounds by matching the arguments against the (open) parameter type
-- (a separate, error-free pass that never touches the trusted 'subtype'), SOLVE, substitute the
-- solution into the original scheme, then DISPOSE by running the ordinary 'subtype' / bound checks on
-- the now-concrete types.
------------------------------------------------------------------------------------------------

-- | Instantiate a scheme's generic parameters as fresh inference variables: a substitution from each
-- declared parameter id to its metavariable (used to open the scheme body), plus the registry of
-- metavariables (their declared name / kind / @extends@ bound, the bound rewritten into metavariable
-- terms so it can be checked against the solution).
instantiateToMetavars :: SourceSpan -> GenericParameters -> Checker (Map GenericId NormalizedKindedType, Registry)
instantiateToMetavars sourceSpan parameters = do
  allocated <- traverse allocate (Map.toList parameters.parameterInformation)
  let substitution = Map.fromList [(info.genericId, metavarKinded info.kind metavar) | (_, info, metavar) <- allocated]
  registry <-
    Map.fromList
      <$> traverse
        ( \(parameterName, info, metavar) -> do
            boundInMetavarTerms <- traverse (runNormalizer sourceSpan . substituteGenericArgument substitution) info.upperBound
            pure (metavar, Metavar {name = parameterName, kind = info.kind, bound = boundInMetavarTerms})
        )
        allocated
  pure (substitution, registry)
  where
    allocate (parameterName, info) = do
      metavar <- freshGenericId
      pure (parameterName, info, metavar)

-- | Apply a generic callee by inferring its type arguments from the argument object. Falls back to
-- 'bottomType' (after a diagnostic) when the scheme is not a callable agent or a type argument cannot
-- be inferred.
applyGenericValue :: SourceSpan -> Scheme -> NormalizedType -> NormalizedAttribute -> Checker NormalizedType
applyGenericValue sourceSpan scheme argumentObject argumentAttribute = do
  (substitution, registry) <- instantiateToMetavars sourceSpan scheme.genericParameters
  openType <- runNormalizer sourceSpan (substituteType substitution scheme.valueType)
  case openFunctionLayer openType of
    Nothing -> do
      reportExpectedShape sourceSpan "a callable agent" scheme.valueType
      pure bottomType
    Just openFunction -> do
      -- Infer the type arguments from the argument against the open parameter, then substitute the
      -- solution into the open scheme and dispose by applying it through the trusted 'applyAgent'.
      solveResult <- inferGenericArguments sourceSpan registry argumentObject openFunction.argumentType
      solvedType <- runNormalizer sourceSpan (substituteType solveResult.substitution openType)
      maybeFunction <- extractFunction sourceSpan solvedType
      case maybeFunction of
        Just (functionAttribute, function) -> applyAgent sourceSpan functionAttribute function argumentObject argumentAttribute
        Nothing -> do
          reportExpectedShape sourceSpan "a callable agent" solvedType
          pure bottomType

-- | The propose / solve / dispose core of generic-argument inference, shared by a generic call
-- ('applyGenericValue') and a request handler ('inferRequestHandlerSubstitution'). Given the
-- metavariable @registry@ for an already-instantiated scheme and the open parameter type the argument
-- must satisfy, it PROPOSES candidate lower bounds by matching @argumentObject@ against
-- @openParameterType@ (the error-free 'collectConstraints' pass, never the trusted 'subtype'), SOLVES,
-- reports any un-inferrable parameter (K3016), and DISPOSES the solution against each parameter's
-- declared @extends@ bound (K3001) via the shared 'checkInferredBounds'. The caller substitutes
-- 'solveResult.substitution' wherever it needs the concrete result.
inferGenericArguments :: SourceSpan -> Registry -> NormalizedType -> NormalizedType -> Checker SolveResult
inferGenericArguments sourceSpan registry argumentObject openParameterType = do
  constraints <- runNormalizer sourceSpan (collectConstraints (Map.keysSet registry) argumentObject openParameterType)
  solveResult <- runNormalizer sourceSpan (solveConstraints registry constraints)
  reportUninferredGenerics sourceSpan registry solveResult.uninferred
  checkInferredBounds sourceSpan registry solveResult
  pure solveResult

-- | The function layer of a type whose base is exactly a function (a scheme body opened to
-- metavariables), without any bound raising — the open callee is a plain agent type, not a bounded
-- generic.
openFunctionLayer :: NormalizedType -> Maybe NormalizedFunction
openFunctionLayer normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeLayered layer -> layer.functionLayer
  NormalizedBaseTypeUnknown -> Nothing

-- | Report the declared parameter names whose type arguments the application did not constrain (K3016).
reportUninferredGenerics :: SourceSpan -> Registry -> List GenericId -> Checker ()
reportUninferredGenerics sourceSpan registry uninferred =
  case [info.name | metavar <- uninferred, Just info <- [Map.lookup metavar registry]] of
    [] -> pure ()
    names -> reportType sourceSpan (TypeErrorCannotInferGeneric CannotInferGenericErrorInfo {parameters = names})

-- | The checker's dispose step for inferred generic arguments: check each genuinely-inferred
-- metavariable's solution against its declared @extends@ bound with the trusted (shared) 'checkBounds'
-- — so an inferred @T = integer | string@ for @add[T extends number]@ fails here as a real K3001, the
-- same outcome the explicit application path gets via 'checkGenericBounds'. Un-inferrable metavariables
-- are skipped (already reported K3016; their recovery value would spuriously fail). This is the single
-- bound check both the generic-call and request-handler inference sites share.
checkInferredBounds :: SourceSpan -> Registry -> SolveResult -> Checker ()
checkInferredBounds sourceSpan registry solveResult =
  runNormalizer sourceSpan (checkBounds solveResult.substitution boundPairs)
  where
    uninferred = Set.fromList solveResult.uninferred
    boundPairs = [(metavar, info.bound) | (metavar, info) <- Map.toList registry, not (Set.member metavar uninferred)]

------------------------------------------------------------------------------------------------
-- Jump statements
------------------------------------------------------------------------------------------------

-- | The body shared by every jump statement (@return@ / @for@ @next@ / @break@ / handler @next@ /
-- @break@). When the jump is in a valid context (@available@ is 'Just'), @inScope@ types its value,
-- emits / checks it and marks the jump; otherwise the jump is reported misplaced and its value is
-- synthesized only for recovery. Modifiers (@with x = e@) follow the same valid / invalid split.
checkJump ::
  Maybe context ->
  SourceSpan ->
  Text ->
  Text ->
  Expression Identified ->
  List (Modifier Identified) ->
  (context -> Checker (Expression Typed)) ->
  Checker (Expression Typed, List (Modifier Typed))
checkJump available sourceSpan keyword place value modifiers inScope = case available of
  Just context -> do
    typedValue <- inScope context
    typedModifiers <- checkModifiers modifiers
    pure (typedValue, typedModifiers)
  Nothing -> do
    reportMisplacedJump sourceSpan keyword place
    (typedValue, _) <- synthExpression value
    typedModifiers <- traverse retagModifier modifiers
    pure (typedValue, typedModifiers)

checkReturnStatement :: ReturnStatement Identified -> Checker (ReturnStatement Typed)
checkReturnStatement returnStmt = do
  target <- asks (.returnTarget)
  (typedValue, _) <-
    checkJump target returnStmt.sourceSpan "return" "an agent body" returnStmt.value [] $ \boundaryId -> do
      (typed, valueType) <- synthExpression returnStmt.value
      -- The value rides an @EXIT(agent)@ escape effect; the enclosing agent discharges it (its union with
      -- the body tail is the agent's return type, checked against the annotation at the agent edge).
      emitExit returnStmt.sourceSpan boundaryId valueType
      pure typed
  pure ReturnStatement {value = typedValue, sourceSpan = returnStmt.sourceSpan}

checkForNextStatement :: ForNextStatement Identified -> Checker (ForNextStatement Typed)
checkForNextStatement forNextStmt = do
  target <- asks (.forTarget)
  (typedValue, typedModifiers) <-
    checkJump target forNextStmt.sourceSpan "next" "a `for` body" forNextStmt.value forNextStmt.modifiers $ \boundaryId -> do
      -- Each `next` value rides a @CONTINUE(for)@ escape; the for discharges it as an element of its map.
      (typed, valueType) <- synthExpression forNextStmt.value
      emitContinue forNextStmt.sourceSpan boundaryId valueType
      pure typed
  pure
    ForNextStatement
      { value = typedValue,
        modifiers = typedModifiers,
        sourceSpan = forNextStmt.sourceSpan
      }

checkForBreakStatement :: ForBreakStatement Identified -> Checker (ForBreakStatement Typed)
checkForBreakStatement forBreakStmt = do
  target <- asks (.forTarget)
  (typedValue, _) <-
    checkJump target forBreakStmt.sourceSpan "break" "a `for` body" forBreakStmt.value [] $ \boundaryId -> do
      -- A `break` rides an @EXIT(for)@ escape: it short-circuits the for, bypassing `then`, and its value
      -- unions into the for's result. It is not a `next` element.
      (typed, valueType) <- synthExpression forBreakStmt.value
      emitExit forBreakStmt.sourceSpan boundaryId valueType
      pure typed
  pure ForBreakStatement {value = typedValue, sourceSpan = forBreakStmt.sourceSpan}

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
  target <- asks (.handlerTarget)
  (typedValue, _) <-
    checkJump target breakStmt.sourceSpan "break" "a request handler body" breakStmt.value [] $ \boundaryId -> do
      -- A @break@ rides an @EXIT(handler)@ escape: it short-circuits the handler, bypassing its @then@
      -- clause, and its value unions straight into the handler's result type (it is not checked against R).
      (typed, valueType) <- synthExpression breakStmt.value
      emitExit breakStmt.sourceSpan boundaryId valueType
      pure typed
  pure BreakStatement {value = typedValue, sourceSpan = breakStmt.sourceSpan}

checkNextStatement :: NextStatement Identified -> Checker (NextStatement Typed)
checkNextStatement nextStmt = do
  target <- asks (.handlerTarget)
  (typedValue, typedModifiers) <-
    checkJump target nextStmt.sourceSpan "next" "a request handler body" nextStmt.value nextStmt.modifiers $ \boundaryId -> do
      -- A @next@ resumes the continuation with its value, riding a @CONTINUE(handler)@ escape; the
      -- request handler discharges it and checks the resume value against the request's return type.
      (typed, valueType) <- synthExpression nextStmt.value
      emitContinue nextStmt.sourceSpan boundaryId valueType
      pure typed
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
    (bindingType, retaggedAnnotation) <- case variablePattern.typeAnnotation of
      Nothing -> pure (scrutinee, Nothing)
      Just annotation -> do
        annotatedType <- elaborateAndNormalizeType annotation
        -- A variable pattern always matches, so its declared type must accept every value the scrutinee
        -- can take: @scrutinee <: annotation@ (an @(x: integer)@ arm over a @number@ scrutinee is
        -- rejected). The annotation does not narrow the match — the cover stays @top@ (below), leaving
        -- @never@ for later arms; only a type-filter @T(x)@ refutably narrows.
        runNormalizer variablePattern.sourceSpan (subtype scrutinee annotatedType)
        pure (annotatedType, Just (retagSyntacticTypeExpression annotation))
    semantic <- denormalizeAt variablePattern.sourceSpan bindingType
    pure
      ( PatternVariable
          VariablePattern
            { name = variablePattern.name,
              variableReference = retagReference variablePattern.variableReference,
              typeAnnotation = retaggedAnnotation,
              sourceSpan = variablePattern.sourceSpan,
              typeOf = semantic
            },
        topType,
        bindingsFor maybeLocal bindingType
      )
  PatternLiteral literalPattern -> do
    -- The node's type is the literal's full type; its match /cover/ is narrower — only @null@ and the
    -- two booleans are finitely enumerable, so an integer / string / number literal covers nothing.
    semantic <- denormalizeAt literalPattern.sourceSpan (synthLiteralValue literalPattern.value)
    pure
      ( PatternLiteral
          LiteralPattern
            { value = literalPattern.value,
              sourceSpan = literalPattern.sourceSpan,
              typeOf = semantic
            },
        literalPatternCover literalPattern.value,
        []
      )
  PatternTypeFilter typeFilterPattern -> do
    -- The inner pattern sees the value /extracted from the scrutinee/ at this tag (a private scrutinee's
    -- nested value stays private), so a nested pattern destructures the scrutinee's actual array / record
    -- / agent type — not a generic top.
    narrowed <- narrowToFilter typeFilterPattern.sourceSpan typeFilterPattern.matchedType scrutinee
    (typedInner, innerCover, innerBindings) <- checkPattern typeFilterPattern.inner narrowed
    -- The cover (what this arm matches) is @filterShape ∧ innerCover@: this tag matches /any/ value of
    -- its runtime shape. 'intersect' under-approximates generics, which is the sound direction here —
    -- the cover feeds only the exhaustiveness lower bound @scrutinee <: ⋃ covers@, never a bound
    -- variable (the inner pattern is narrowed from the scrutinee above).
    cover <- runNormalizer (sourceSpanOf typeFilterPattern) (intersect (filterShape typeFilterPattern.matchedType) innerCover)
    semantic <- denormalizeAt typeFilterPattern.sourceSpan cover
    pure
      ( PatternTypeFilter
          TypeFilterPattern
            { matchedType = typeFilterPattern.matchedType,
              inner = typedInner,
              sourceSpan = typeFilterPattern.sourceSpan,
              typeOf = semantic
            },
        cover,
        innerBindings
      )
  PatternTuple tuplePattern -> do
    elementTypes <- extractTupleElementTypes tuplePattern.sourceSpan scrutinee (length tuplePattern.elements)
    pairResults <- zipWithM checkPattern tuplePattern.elements elementTypes
    let typedElements = [t | (t, _, _) <- pairResults]
        elementCovers = [c | (_, c, _) <- pairResults]
        allBindings = concatMap (\(_, _, b) -> b) pairResults
        cover =
          layeredOf
            neverLayer
              { sequenceLayer = Just NormalizedSequence {items = elementCovers, rest = bottomType}
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
        allBindings = concatMap (\(_, _, b, _) -> b) fieldResults
        cover = namedObjectType [(fieldName, fieldCover) | (fieldName, fieldCover, _, _) <- fieldResults]
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
            constructorPatternSubstitution
              constructorPattern.sourceSpan
              qualifiedName
              dataInfo
              scrutinee
              constructorPattern.genericArguments
          instantiatedConstructor <-
            runNormalizer constructorPattern.sourceSpan (objectAsType <$> substituteObject substitution dataInfo.constructor)
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
          instantiation <- instantiationOf constructorPattern.sourceSpan dataInfo.genericParameters substitution
          semantic <- denormalizeAt constructorPattern.sourceSpan cover
          pure
            ( PatternConstructor
                ConstructorPattern
                  { moduleQualifier = retagModuleQualifier <$> constructorPattern.moduleQualifier,
                    name = constructorPattern.name,
                    constructorReference = retagReference constructorPattern.constructorReference,
                    genericArguments = retagSyntacticTypeExpression <$> constructorPattern.genericArguments,
                    instantiation = instantiation,
                    fields = typedFields,
                    sourceSpan = constructorPattern.sourceSpan,
                    typeOf = semantic
                  },
              cover,
              allBindings
            )
        -- The name resolved, but not to a data type (the variable namespace is shared with agents /
        -- requests / locals), so this is a user error, not a compiler bug.
        Nothing -> recoverConstructorPattern constructorPattern
    -- Resolved to a local / non-data value used in constructor-pattern position — likewise a user error.
    _ -> recoverConstructorPattern constructorPattern
  where
    bindingsFor maybeLocal bindingType = case maybeLocal of
      Just localId -> [(localId, monoScheme bindingType)]
      Nothing -> []

extractTupleElementTypes :: SourceSpan -> NormalizedType -> Int -> Checker (List NormalizedType)
extractTupleElementTypes sourceSpan scrutinee count = do
  -- Destructuring requires the scrutinee to be solely a sequence: a @[A, B] | null@ scrutinee yields
  -- no element types (each position degrades to top), so a possibly-null value is not read through as
  -- its element types.
  raised <- soleLayer sourceSpan (Set.singleton SequenceKind) scrutinee
  pure $ case raised of
    Just (attribute, layer)
      | Just normalizedSequence <- layer.sequenceLayer ->
          -- Destructuring observes each element through the container's handle, so each binder is the
          -- element type lifted by that handle attribute ('liftByAttribute'): a private tuple
          -- distributes its privacy to its components, the same as a @match@ scrutinee. The fixed
          -- prefix positions are present; a position past it may be absent at runtime, so it reads as
          -- @rest | null@ (an array's tail @T@ ~> @T | null@, a tuple's @never@ ~> @null@).
          liftByAttribute attribute <$> take count (normalizedSequence.items <> repeat (orNull normalizedSequence.rest))
    _ -> replicate count topType

-- | Recover from a constructor pattern whose name does not denote a data type (a user error, since the
-- variable namespace is shared with agents / requests / locals): report it, then bind the field
-- patterns against 'topType' so the arm body's references still resolve, with a 'topType' cover so
-- exhaustiveness does not cascade a second diagnostic.
recoverConstructorPattern ::
  ConstructorPattern Identified ->
  Checker (Pattern Typed, NormalizedType, List (LocalVariableId, Scheme))
recoverConstructorPattern constructorPattern = do
  reportType
    constructorPattern.sourceSpan
    (TypeErrorWrongReferenceKind (WrongReferenceKindErrorInfo {name = constructorPattern.name, expected = "a constructor (data type)"}))
  fieldResults <- traverse (checkFieldPattern topType) constructorPattern.fields
  let recoveredFields = [typed | (_, _, _, typed) <- fieldResults]
      recoveredBindings = concatMap (\(_, _, bindings, _) -> bindings) fieldResults
  recoveredSemantic <- denormalizeAt constructorPattern.sourceSpan topType
  pure
    ( PatternConstructor
        ConstructorPattern
          { moduleQualifier = retagModuleQualifier <$> constructorPattern.moduleQualifier,
            name = constructorPattern.name,
            constructorReference = retagReference constructorPattern.constructorReference,
            genericArguments = retagSyntacticTypeExpression <$> constructorPattern.genericArguments,
            instantiation = mempty,
            fields = recoveredFields,
            sourceSpan = constructorPattern.sourceSpan,
            typeOf = recoveredSemantic
          },
      topType,
      recoveredBindings
    )

checkFieldPattern ::
  NormalizedType ->
  FieldPattern Identified ->
  Checker (Text, NormalizedType, List (LocalVariableId, Scheme), FieldPattern Typed)
checkFieldPattern scrutinee fieldPattern = do
  let fieldName = fieldPattern.name
  -- A value with no object / data shape contributes 'topType' here: the binder accepts anything and
  -- the arm's cover check ('subtype scrutinee cover') catches a genuine mismatch.
  fieldScrutinee <- fromMaybe topType <$> maybeReadField fieldPattern.sourceSpan fieldName scrutinee
  (typedInner, cover, bindings) <- checkPattern fieldPattern.bindPattern fieldScrutinee
  let typedFieldPattern =
        FieldPattern
          { name = fieldPattern.name,
            labelReference = retagReference fieldPattern.labelReference,
            bindPattern = typedInner,
            sourceSpan = fieldPattern.sourceSpan
          }
  pure (fieldName, cover, bindings, typedFieldPattern)

-- | The most-general type of a type-filter tag — the cover for @tag(p)@ (it matches /any/ value of that
-- runtime shape): a primitive's own type, @array[unknown]@, @record[unknown]@, or the top agent.
filterShape :: TypeFilter -> NormalizedType
filterShape = \case
  FilterNull -> nullType
  FilterBoolean -> booleanType
  FilterInteger -> integerType
  FilterNumber -> numberType
  FilterString -> stringType
  FilterFile -> fileType
  FilterArray -> arrayOf unknownType
  FilterRecord -> recordOf unknownType
  FilterAgent -> topAgentType

-- | The type the inner pattern of @tag(inner)@ matches against: the value /extracted from the scrutinee/
-- at this tag (so a nested pattern sees the scrutinee's actual array / record / agent type), lifted by
-- the scrutinee's (raised) handle attribute. The lift is applied in /both/ the layered and the @unknown@
-- (no layer) case, so a private scrutinee's nested value stays private — this is the path-accumulated
-- privacy a @let@ binder needs (it composes with the per-container lift of field / element reads) and the
-- world a @match@ arm observes. A primitive carries no nested type (just its own type); an @unknown@
-- scrutinee falls back to the tag's most-general shape.
narrowToFilter :: SourceSpan -> TypeFilter -> NormalizedType -> Checker NormalizedType
narrowToFilter sourceSpan tag scrutinee = do
  raised <- raiseToBounds sourceSpan scrutinee
  slot <- case raised.baseType of
    NormalizedBaseTypeUnknown -> pure (filterShape tag)
    NormalizedBaseTypeLayered layer -> filterSlot sourceSpan tag layer
  pure (liftByAttribute raised.attribute slot)

-- | The scrutinee layer's component for a tag (carrying its nested types), or the tag's most-general
-- shape when that slot is absent (a refuted arm — its binders still type, but the arm never fires). A
-- @record@ reads the structural object /and/ every nominal data type's (instantiated) constructor
-- object, so @record(value => v)@ over a @box[integer]@ binds @v@ at the data's read shape (@integer@),
-- not @unknown@.
filterSlot :: SourceSpan -> TypeFilter -> LayeredType -> Checker NormalizedType
filterSlot sourceSpan tag layer = case tag of
  FilterArray -> pure (projectSlot FilterArray layer.sequenceLayer (\sequence' -> neverLayer {sequenceLayer = Just sequence'}))
  FilterAgent -> pure (projectSlot FilterAgent layer.functionLayer (\function -> neverLayer {functionLayer = Just function}))
  FilterRecord -> do
    -- The record view of the value: its structural object, plus each nominal data type's read shape.
    dataViews <- traverse (fmap objectAsType . dataConstructorObject sourceSpan) (Map.toList layer.dataLayer)
    case maybe [] (\object -> [objectAsType object]) layer.objectLayer <> dataViews of
      [] -> pure (filterShape FilterRecord)
      views -> foldM (\accumulated view -> runNormalizer sourceSpan (union accumulated view)) bottomType views
  _ -> pure (filterShape tag)
  where
    -- A structural tag projects the scrutinee onto only its matching slot (keeping the nested types); a
    -- slot the scrutinee lacks — a refuted arm — falls back to the tag's most-general shape ('filterShape').
    projectSlot missingTag slot build = maybe (filterShape missingTag) (layeredOf . build) slot

------------------------------------------------------------------------------------------------
-- Match expressions
------------------------------------------------------------------------------------------------

synthMatchExpression :: MatchExpression Identified -> Checker (Expression Typed, NormalizedType)
synthMatchExpression expression = do
  (typedSubject, scrutineeType) <- synthExpression expression.subject
  scrutineeAttribute <- runNormalizer expression.sourceSpan (foldAttribute scrutineeType)
  results <- traverse (processCase scrutineeType scrutineeAttribute) expression.cases
  -- The arm covers union to a sound lower bound of what the match accepts; exhaustiveness is then
  -- @scrutinee <: ⋃ covers@. Folding from 'bottomType' makes an empty match (covers union to never)
  -- fail this check for any inhabited scrutinee, with no special case.
  unionCover <- foldM combineUnion bottomType [cover | (cover, _, _) <- results]
  resultType <- foldM combineUnion bottomType [body | (_, body, _) <- results]
  -- Exhaustiveness is about base-type coverage, not observation: the covers are built public, so
  -- compare under a private world (where every attribute comparison collapses) to avoid spuriously
  -- rejecting a private — or otherwise attributed — scrutinee. The observation rules still apply to the
  -- arm bodies (via 'processObserved'), so ignoring attributes here is sound.
  withWorld topAttribute $ runNormalizer expression.sourceSpan (subtype scrutineeType unionCover)
  let typedCases = [arm | (_, _, arm) <- results]
  typedExpression expression.sourceSpan resultType $ \semantic ->
    ExpressionMatch
      MatchExpression
        { subject = typedSubject,
          cases = typedCases,
          sourceSpan = expression.sourceSpan,
          typeOf = semantic
        }
  where
    processCase scrutType scrutAttribute arm = do
      (typedPattern, cover, bindings) <- checkPattern arm.pattern scrutType
      (typedBody, resultType) <-
        processObserved arm.sourceSpan scrutAttribute (withParameters bindings (synthBlock arm.body))
      let typedArm =
            CaseArm
              { pattern = typedPattern,
                body = typedBody,
                sourceSpan = arm.sourceSpan
              }
      pure (cover, resultType, typedArm)
    combineUnion accumulator next = runNormalizer expression.sourceSpan (union accumulator next)

-- | Apply an observed value's world to a result given its (already collected) effect. A /pure/ branch —
-- no effect and no escaping @return@ / @break@ / @next@ (which now show up as escape effects, so
-- 'isPureEffect' already accounts for them) — carries the observed attribute into its result. A branch
-- that performs an effect or escapes cannot be lifted across worlds, so the observed value must be
-- allowed in the current world (its attribute <: world) and its effect is re-emitted into the enclosing
-- scope.
observeResult :: SourceSpan -> NormalizedAttribute -> NormalizedEffect -> NormalizedType -> Checker NormalizedType
observeResult sourceSpan observedAttribute branchEffect resultType =
  if isPureEffect branchEffect
    then pure (liftByAttribute observedAttribute resultType)
    else do
      runNormalizer sourceSpan (subtype observedAttribute bottomAttribute)
      emitEffect sourceSpan branchEffect
      pure resultType

-- | Run a control-flow branch (a match arm body, an @if@ branch) collecting its effect, then apply the
-- observation rule ('observeResult').
processObserved :: SourceSpan -> NormalizedAttribute -> Checker (node, NormalizedType) -> Checker (node, NormalizedType)
processObserved sourceSpan observedAttribute walk = do
  (branchEffect, (node, bodyType)) <- withEffectInference walk
  resultType <- observeResult sourceSpan observedAttribute branchEffect bodyType
  pure (node, resultType)

------------------------------------------------------------------------------------------------
-- For expressions
------------------------------------------------------------------------------------------------

synthForExpression :: ForExpression Identified -> Checker (Expression Typed, NormalizedType)
synthForExpression expression = do
  (typedSource, sourceType) <- synthExpression expression.inBinding.source
  -- A `for` is a control construct: like `if` / `match`, it observes its source, so the source's
  -- attribute carries into the result ('observeResult' over the loop's residual effect enforces that —
  -- a pure loop over a private source yields a private result; a loop with effects / outer escapes over
  -- a private source is rejected).
  sourceAttribute <- runNormalizer (sourceSpanOf expression.inBinding.source) (foldAttribute sourceType)
  elementType <- extractIterableElementType (sourceSpanOf expression.inBinding.source) sourceType
  (typedPattern, _, patternBindings) <- checkPattern expression.inBinding.pattern elementType
  -- The `var` state scopes over the body /and/ the then clause; the loop pattern scopes over the body.
  (typedVarBindings, (typedBody, typedThen, finalType)) <-
    withVarBindingsTyped expression.varBindings $ do
      boundaryId <- freshBoundaryId
      -- Collect the for body's whole effect (its @CONTINUE(for)@ elements, @EXIT(for)@ breaks, and any
      -- ordinary effects / outer escapes).
      (bodyEffect, (typedBody, bodyTail)) <-
        withEffectInference $
          enterForBody boundaryId $
            withParameters patternBindings (synthBlock expression.body)
      -- Discharge the for's own escapes. A `for` is a map: each @CONTINUE@ element and the body tail join
      -- the element type R; a @break@ (@EXIT@) bypasses `then` and unions into the result. The residual
      -- is the loop's observable effect.
      let (continueType, afterContinue) = splitContinue boundaryId bodyEffect
          (breakType, residualEffect) = splitExit boundaryId afterContinue
      elementR <- runNormalizer expression.sourceSpan (union bodyTail continueType)
      let arrayType = arrayOf elementR
      -- The `then` clause inherits the outer control context (no barrier) and runs in the `var` scope;
      -- its own effect joins the loop's observed effect.
      (thenEffect, maybeThenResult, typedThen) <- walkThenClause ForThen arrayType expression.thenClause
      let normalType = fromMaybe arrayType maybeThenResult
      breakAndNormal <- runNormalizer expression.sourceSpan (union normalType breakType)
      observedEffect <- runNormalizer expression.sourceSpan (union residualEffect thenEffect)
      finalType <- observeResult expression.sourceSpan sourceAttribute observedEffect breakAndNormal
      pure (typedBody, typedThen, finalType)
  typedExpression expression.sourceSpan finalType $ \semantic ->
    ExpressionFor
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
        }

-- | The element type produced by iterating a sequence: the union of every fixed position and the
-- @rest@. No @null@ is added — iteration visits the elements that exist, never an out-of-range slot —
-- so @array[T]@ iterates as @T@ and the tuple @[A, B]@ as @A | B@.
extractIterableElementType :: SourceSpan -> NormalizedType -> Checker NormalizedType
extractIterableElementType sourceSpan source = do
  -- Iterating requires the source to be solely a sequence: a @array[T] | null@ source is rejected, so
  -- the null possibility is no longer silently dropped from the element type. The element type is lifted
  -- by the container's handle attribute in 'withSoleLayer' (a private array yields private elements); no
  -- @null@ is added — iteration visits the elements that exist.
  maybeElement <-
    withSoleLayer sourceSpan (Set.singleton SequenceKind) source $ \layer ->
      traverse
        (\normalizedSequence -> foldM combineUnion bottomType (normalizedSequence.items <> [normalizedSequence.rest]))
        layer.sequenceLayer
  case maybeElement of
    Just element -> pure element
    Nothing -> do
      reportExpectedShape sourceSpan "a sequence (array or tuple)" source
      pure bottomType
  where
    combineUnion accumulator next = runNormalizer sourceSpan (union accumulator next)

-- | Bring var (@for@ / handler state) bindings into scope and run an action; return the typed
-- bindings paired with the action's result.
withVarBindingsTyped ::
  List (VariableBinding Identified) ->
  Checker a ->
  Checker (List (VariableBinding Typed), a)
withVarBindingsTyped bindings action = go bindings []
  where
    go remaining accumulated = case remaining of
      [] -> do
        result <- action
        pure (reverse accumulated, result)
      binding : rest -> withVarBindingTyped binding $ \typedBinding -> go rest (typedBinding : accumulated)

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

-- | A fixed-length tuple type from its positional element types (the @rest@ is @never@: no further
-- positions). The dual of 'arrayOf' (homogeneous tail) for a fixed prefix.
tupleOf :: List NormalizedType -> NormalizedType
tupleOf elementTypes =
  layeredOf
    neverLayer
      { sequenceLayer = Just NormalizedSequence {items = elementTypes, rest = bottomType}
      }

-- | A homogeneous @record[T]@: an object with no fixed fields whose every key reads as @T@.
recordOf :: NormalizedType -> NormalizedType
recordOf valueType =
  layeredOf
    neverLayer
      { objectLayer = Just NormalizedObject {fields = mempty, rest = valueType}
      }

-- | The top agent type — every agent is a subtype of it (contravariant @never@ argument, @unknown@
-- return, @all@ effect) — used as the @agent(p)@ filter's most-general shape.
topAgentType :: NormalizedType
topAgentType = assembleAgent bottomAttribute bottomType unknownType topEffect

------------------------------------------------------------------------------------------------
-- Handler expressions
------------------------------------------------------------------------------------------------

-- | The typed sub-parts of a handler, assembled into the typed node once its (possibly instantiated)
-- type and generic arguments are known.
data HandlerComponents = HandlerComponents
  { parallel :: Bool,
    genericArguments :: List (SyntacticTypeExpression Typed),
    stateVariables :: List (VariableBinding Typed),
    handlers :: List (RequestHandler Typed),
    thenClause :: Maybe (ThenClause Typed),
    sourceSpan :: SourceSpan
  }

-- | Build a handler value's generic scheme. A handler is a generic value over its result type @R@ (the
-- continuation's result) and residual effect @E@:
--
-- @∀R E. agent({continuation: agent({value: null}) -> R with {...E, req1[..], ...}})
--        -> (break-union | then(R)) with (E | bodyEffect)@
--
-- The request bodies are checked with @R@ / @E@ as rigid generics: their explicit @break@s form the
-- (concrete) break union and their effects the (concrete) body effect, while @R@ appears only as the
-- @then@ binder's type and @E@ only in the effect rows — so the body never compares a concrete value
-- against a rigid @R@ / @E@. A request body's resume values (its handler @next@ and its body tail) are
-- /not/ part of the result: they are checked against the request's own return type inside
-- 'walkResolvedRequestHandler'. The continuation effect is the /overwrite/ @{...E, req[..]}@: @E@ lacks
-- every handled request, which appears as a concrete override (its generic arguments resolved per
-- request handler). At a call / @use@ the standard generic-argument inference solves @R@ from the
-- continuation's return and @E@ from its effect (the handled requests dropped).
checkHandlerScheme :: HandlerExpression Identified -> Checker (HandlerComponents, Scheme)
checkHandlerScheme expression = do
  resultId <- freshGenericId
  effectId <- freshGenericId
  let resultVariable = NormalizedType {baseType = NormalizedBaseTypeLayered neverLayer, generics = Set.singleton resultId, attribute = bottomAttribute}
      resultInfo = GenericParameterInformation {genericId = resultId, kind = GenericKindType, variance = Bivariant, upperBound = Nothing}
      effectInfo = GenericParameterInformation {genericId = effectId, kind = GenericKindEffect, variance = Bivariant, upperBound = Nothing}
      handlerGenerics =
        GenericParameters
          { parameterNames = [handlerResultParameterName, handlerEffectParameterName],
            parameterInformation = Map.fromList [(handlerResultParameterName, resultInfo), (handlerEffectParameterName, effectInfo)]
          }
  (typedVarBindings, (handled, typedHandlers, typedThen, breakUnion, bodyEffect, thenResult)) <-
    withVarBindingsTyped expression.stateVariables $
      withGenerics handlerGenerics $ do
        (handlerBodyEffect, results) <-
          withEffectInference $
            catMaybes <$> traverse walkRequestHandler expression.handlers
        -- Only explicit @break@s reach the handler's result (each request handler discharges its own and
        -- returns it), bypassing @then@ and unioning straight in. A request body's resume values (its
        -- @next@ and body tail) were already checked against the request return type. @then@ is jumpless.
        breakUnion <- foldM (\accumulated (_, _, breakType, _) -> runNormalizer expression.sourceSpan (union accumulated breakType)) bottomType results
        (thenEffect, maybeThenResult, typedThen) <- walkThenClause HandlerThen resultVariable expression.thenClause
        totalBodyEffect <- runNormalizer expression.sourceSpan (union handlerBodyEffect thenEffect)
        pure
          ( [(name, requestArguments) | (name, requestArguments, _, _) <- results],
            [node | (_, _, _, node) <- results],
            typedThen,
            breakUnion,
            totalBodyEffect,
            fromMaybe resultVariable maybeThenResult
          )
  let handledRequests = Map.fromList handled
      continuationEffect =
        effectRow EffectRow {request = handledRequests, tails = Map.singleton effectId (Map.keysSet handledRequests)}
      effectVariable = effectRow EffectRow {request = mempty, tails = Map.singleton effectId mempty}
  handlerEffect <- runNormalizer expression.sourceSpan (union effectVariable bodyEffect)
  handlerResult <- runNormalizer expression.sourceSpan (union breakUnion thenResult)
  let outerParameter = continuationExpectedArgument nullType resultVariable continuationEffect
      handlerType = assembleAgent bottomAttribute outerParameter handlerResult handlerEffect
      components =
        HandlerComponents
          { parallel = expression.parallel,
            genericArguments = retagSyntacticTypeExpression <$> expression.genericArguments,
            stateVariables = typedVarBindings,
            handlers = typedHandlers,
            thenClause = typedThen,
            sourceSpan = expression.sourceSpan
          }
  pure (components, Scheme {genericParameters = handlerGenerics, valueType = handlerType})

-- | A handler scheme's own generic parameters as the instantiation arguments (each parameter to its
-- own scheme variable), for a handler node whose @R@ / @E@ are not yet substituted.
ownHandlerInstantiation :: Scheme -> Map Text SemanticGenericArgument
ownHandlerInstantiation scheme =
  Map.fromList [(name, schemeVariableFor info.kind info.genericId) | (name, info) <- Map.toList scheme.genericParameters.parameterInformation]

assembleHandlerNode :: HandlerComponents -> Map Text SemanticGenericArgument -> NormalizedType -> Checker (Expression Typed)
assembleHandlerNode components instantiation handlerType = do
  semantic <- denormalizeAt components.sourceSpan handlerType
  pure $
    ExpressionHandler
      HandlerExpression
        { parallel = components.parallel,
          genericArguments = components.genericArguments,
          instantiation = instantiation,
          stateVariables = components.stateVariables,
          handlers = components.handlers,
          thenClause = components.thenClause,
          sourceSpan = components.sourceSpan,
          typeOf = semantic
        }

-- | Synthesize a bare handler expression (one not in call position). An explicit @handler[R, E]@ is the
-- scheme applied to its arguments; a bare @handler { ... }@ is a generic value used without application,
-- whose @R@ / @E@ cannot be inferred (there is no continuation), so it is reported (K3015) like any
-- unapplied generic — write @handler[R, E]@ or apply it (@use handler { ... }@).
synthHandlerExpression :: HandlerExpression Identified -> Checker (Expression Typed, NormalizedType)
synthHandlerExpression expression = do
  (components, scheme) <- checkHandlerScheme expression
  case expression.genericArguments of
    [] -> do
      instantiated <- instantiateBare expression.sourceSpan scheme
      node <- assembleHandlerNode components (ownHandlerInstantiation scheme) instantiated
      pure (node, instantiated)
    genericArguments -> do
      substitution <- buildGenericSubstitution expression.sourceSpan "handler" scheme.genericParameters genericArguments
      instantiated <- runNormalizer expression.sourceSpan (substituteType substitution scheme.valueType)
      instantiation <- instantiationOf expression.sourceSpan scheme.genericParameters substitution
      node <- assembleHandlerNode components instantiation instantiated
      pure (node, instantiated)

-- | Check a @then@ clause's optional binder against the type it matches — the @for@ result array, or
-- a handler's result @R@ — yielding the typed binder and its bindings.
checkThenBinder ::
  NormalizedType ->
  Maybe (Pattern Identified) ->
  Checker (Maybe (Pattern Typed), List (LocalVariableId, Scheme))
checkThenBinder matchedType = \case
  Nothing -> pure (Nothing, [])
  Just binder -> do
    (typedPattern, _, bindings) <- checkPattern binder matchedType
    pure (Just typedPattern, bindings)

-- | Whether a @then@ finalizer inherits the outer control context (a @for@'s @then@) or is jumpless (a
-- handler's @then@). The parser already binds a @then@-clause @next@ / @break@ to the /outer/ loop
-- context, so a @for@'s @then@ targets the enclosing @for@ / handler / agent; a handler's @then@ pushes a
-- barrier so no jump escapes it (the handler is a deferred value).
data ThenScope = ForThen | HandlerThen

-- | Walk a @then@ finalizer — a @for@'s or a @handler@'s, the single home of the rule. Its binder
-- matches @matchedType@ (the value the construct produces before @then@: a @for@'s result array, a
-- handler's result @R@), and its body freely synthesizes the transformed result. Returns the body's
-- inferred effect (the caller folds it into the construct's effect — a handler unions it into @E@, a
-- @for@ re-emits it into its enclosing observed scope), the synthesized result (so the caller can make
-- it the construct's result), and the typed clause. A @for@'s @then@ inherits the outer control context;
-- a handler's @then@ is jumpless ('enterHandlerThen' bars every jump). Walked inside the construct's
-- @var@ state scope (the finalizer reads the accumulated state).
walkThenClause ::
  ThenScope ->
  NormalizedType ->
  Maybe (ThenClause Identified) ->
  Checker (NormalizedEffect, Maybe NormalizedType, Maybe (ThenClause Typed))
walkThenClause scope matchedType = \case
  Nothing -> pure (bottomEffect, Nothing, Nothing)
  Just thenClause -> do
    (typedBinder, thenBindings) <- checkThenBinder matchedType thenClause.binder
    (thenEffect, (typedBody, thenResult)) <-
      withEffectInference $
        withParameters thenBindings $
          enterThen (synthBlock thenClause.body)
    pure (thenEffect, Just thenResult, Just ThenClause {binder = typedBinder, body = typedBody, sourceSpan = thenClause.sourceSpan})
  where
    enterThen = case scope of
      ForThen -> id
      HandlerThen -> enterHandlerThen

-- | Walk one request handler: resolve the handled request's generic arguments (explicit, or derived
-- from the handler's parameters), check the handler's parameters accept the request's argument object,
-- then walk the body. The body's tail is an implicit @break@ — a value the handler returns without
-- resuming — so it joins the break union (the handler's result @R@ is the continuation's result, not a
-- body tail). Returns the handled request name, its inferred generic arguments (for the continuation's
-- overwrite effect), and the typed node.
-- | The handled name resolves in the /type/ namespace (shared with data types, synonyms and in-scope
-- generics), so a handler may name a non-request. That is a user error, not a compiler invariant, so it
-- is reported and the handler is skipped ('Nothing'); a resolved request that is somehow absent from
-- the environment would be a genuine compiler bug, but the same report keeps the checker total.
walkRequestHandler ::
  RequestHandler Identified ->
  Checker (Maybe (QualifiedName, Map Text NormalizedKindedType, NormalizedType, RequestHandler Typed))
walkRequestHandler handler = do
  requestEnv <- asks (\environment -> environment.typeEnvironment.requestEnvironment)
  let resolvedRequest = case handler.typeReference.resolution of
        Just (TypeResolutionQualifiedName name) -> (,) name <$> Map.lookup name requestEnv
        _ -> Nothing
  case resolvedRequest of
    Nothing -> do
      reportType handler.sourceSpan (TypeErrorWrongReferenceKind (WrongReferenceKindErrorInfo {name = handler.name, expected = "a request"}))
      pure Nothing
    Just (requestName, requestInfo) -> Just <$> walkResolvedRequestHandler handler requestName requestInfo

-- | Walk a request handler whose handled request has been resolved (see 'walkRequestHandler'). Returns
-- the handled request name, its inferred generic arguments, the @break@ value it discharges (a value the
-- handler returns without resuming — it bypasses @then@), and the typed node. The body's resume values
-- (its @next@ and its tail) are checked against the request's return type here; its residual effect is
-- re-emitted into the handler's effect scope.
walkResolvedRequestHandler ::
  RequestHandler Identified ->
  QualifiedName ->
  RequestInformation ->
  Checker (QualifiedName, Map Text NormalizedKindedType, NormalizedType, RequestHandler Typed)
walkResolvedRequestHandler handler requestName requestInfo = do
  -- The handler's parameters are built first: when the request's generics are not written explicitly,
  -- they are derived from the parameter annotations (a @request foo(x : int)@ handler of @foo[a](x: a)@
  -- infers @a = int@), exactly the single-site inference a generic call uses.
  (paramObject, paramBindings, typedParams) <- buildParameterScopeTyped handler.parameters
  substitution <- case handler.genericArguments of
    [] -> inferRequestHandlerSubstitution handler.sourceSpan requestInfo paramObject
    genericArguments -> buildGenericSubstitution handler.sourceSpan (renderQualifiedName requestName) requestInfo.genericParameters genericArguments
  instantiatedParam <- runNormalizer handler.sourceSpan (substituteType substitution requestInfo.parameterType)
  instantiatedReturn <- runNormalizer handler.sourceSpan (substituteType substitution requestInfo.returnType)
  runNormalizer handler.sourceSpan (subtype instantiatedParam paramObject)
  boundaryId <- freshBoundaryId
  (bodyEffect, (typedBlock, bodyTail)) <-
    -- A request handler body is deferred — it runs when the handler is invoked, not where it is written
    -- — so it sees none of the enclosing agent's / `for`'s targets: a `return` is barred
    -- ('enterRequestHandler' clears the return / `for` targets — only a nested closure's own boundary
    -- catches a `return`), and only the handler's own `break` / `next` are in scope.
    withEffectInference $
      enterRequestHandler boundaryId $
        withParameters paramBindings (synthBlock handler.body)
  -- Discharge the handler's own escapes: its @CONTINUE@ resumes (with the body tail, an implicit @next@)
  -- must be valid request results; its @break@s (@EXIT@) bypass @then@ and become handler results.
  let (resumeContinue, afterContinue) = splitContinue boundaryId bodyEffect
      (breakType, residualEffect) = splitExit boundaryId afterContinue
  resumeUnion <- runNormalizer handler.sourceSpan (union bodyTail resumeContinue)
  runNormalizer handler.sourceSpan (subtype resumeUnion instantiatedReturn)
  -- The body's residual effect joins the handler's effect scope (it becomes part of @E | bodyEffect@).
  emitEffect handler.sourceSpan residualEffect
  instantiation <- instantiationOf handler.sourceSpan requestInfo.genericParameters substitution
  -- The request's generic arguments by name, for the continuation's overwrite effect @{...E, req[..]}@.
  let requestArguments = instantiationByName requestInfo.genericParameters substitution
      typedHandler =
        RequestHandler
          { moduleQualifier = retagModuleQualifier <$> handler.moduleQualifier,
            name = handler.name,
            typeReference = retagReference handler.typeReference,
            genericArguments = retagSyntacticTypeExpression <$> handler.genericArguments,
            instantiation = instantiation,
            parameters = typedParams,
            returnType = retagSyntacticTypeExpression <$> handler.returnType,
            body = typedBlock,
            sourceSpan = handler.sourceSpan
          }
  pure (requestName, requestArguments, breakType, typedHandler)

-- | The generic substitution for a constructor pattern. Explicit @[...]@ arguments are elaborated as
-- usual (the pattern's signature is written). With none, the data type's generic arguments are
-- /derived from the scrutinee/ so a binder reads at the scrutinee's instantiation — a @box(value = v)@
-- pattern over a @box[integer]@ scrutinee binds @v : integer@, not an unconstrained @never@. The
-- pattern's signature is then exactly the scrutinee's (which trivially covers it); explicit arguments
-- can widen it. When the scrutinee does not carry this constructor (a refuted arm), the data type's own
-- generic variables are used so the binders read at the generics' bounds rather than at @never@.
constructorPatternSubstitution ::
  SourceSpan ->
  QualifiedName ->
  DataInformation ->
  NormalizedType ->
  List (SyntacticTypeExpression Identified) ->
  Checker (Map GenericId NormalizedKindedType)
constructorPatternSubstitution sourceSpan qualifiedName dataInfo scrutinee = \case
  [] -> do
    raised <- raiseToBounds sourceSpan scrutinee
    case raised.baseType of
      NormalizedBaseTypeLayered layer
        | Just arguments <- Map.lookup qualifiedName layer.dataLayer ->
            pure (reKeyByGenericId dataInfo.genericParameters arguments)
      _ -> do
        ownArguments <- ownGenericArguments sourceSpan dataInfo.genericParameters
        pure (reKeyByGenericId dataInfo.genericParameters ownArguments)
  genericArguments ->
    buildGenericSubstitution sourceSpan (renderQualifiedName qualifiedName) dataInfo.genericParameters genericArguments

-- | Infer a request's generic arguments for a request handler written without an explicit @[...]@: the
-- request's generics are instantiated to metavariables, the request's (open) parameter type is matched
-- against the handler's declared parameter object, and the solution is read back. A generic the
-- parameters do not constrain (e.g. one appearing only in the request's return) is reported
-- un-inferrable (K3016) and the user must write it explicitly. Returns the substitution from each
-- request generic id to its concrete argument.
inferRequestHandlerSubstitution :: SourceSpan -> RequestInformation -> NormalizedType -> Checker (Map GenericId NormalizedKindedType)
inferRequestHandlerSubstitution sourceSpan requestInfo paramObject = do
  (toMetavar, registry) <- instantiateToMetavars sourceSpan requestInfo.genericParameters
  openParam <- runNormalizer sourceSpan (substituteType toMetavar requestInfo.parameterType)
  -- The request's parameter values must be accepted by the handler's parameters; matching the handler
  -- parameter object against the open request parameter gives each request generic a lower bound (the
  -- same propose / solve / dispose a generic call runs).
  solveResult <- inferGenericArguments sourceSpan registry paramObject openParam
  traverse (runNormalizer sourceSpan . substituteGenericArgument solveResult.substitution) toMetavar

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
    else do
      substitution <- Map.fromList . catMaybes <$> zipWithM (elaborateArgument parameterInfo) parameterNames argumentExpressions
      runNormalizer sourceSpan (checkGenericBounds parameters substitution)
      pure substitution
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

-- | The Typed-AST @instantiation@ record for a generic application: each declared generic name mapped
-- to the (denormalized) argument the resolved substitution bound its id to, so lowering need not
-- re-derive it. A name absent from the substitution (an arity error was already reported) is dropped.
instantiationOf ::
  SourceSpan ->
  GenericParameters ->
  Map GenericId NormalizedKindedType ->
  Checker (Map Text SemanticGenericArgument)
instantiationOf sourceSpan parameters substitution =
  traverse (runNormalizer sourceSpan . denormalizeGenericArgument) (instantiationByName parameters substitution)

-- | An object type from named required fields with the given @rest@ (the type of every other key).
-- An /open/ rest ('unknownType') ignores undeclared keys (width subtyping); a /closed/ rest
-- ('bottomType') admits no other key, so an omitted field is genuinely absent — what a call-argument
-- object needs for an omitted optional (defaulted) parameter to match.
namedObjectTypeWithRest :: NormalizedType -> List (Text, NormalizedType) -> NormalizedType
namedObjectTypeWithRest restType fieldList =
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
                rest = restType
              }
      }

-- | An /open/ named object (undeclared keys allowed): the default for parameter / continuation shapes.
namedObjectType :: List (Text, NormalizedType) -> NormalizedType
namedObjectType = namedObjectTypeWithRest unknownType

-- | Mark the named fields of an object type /optional/ (a defaulted parameter is omittable at the call
-- site; the runtime fills the default). A non-object type is returned unchanged. Shared by the
-- constructor/request 'callShape' and the agent parameter object.
markFieldsOptional :: Set.Set Text -> NormalizedType -> NormalizedType
markFieldsOptional names objectType = case objectType.baseType of
  NormalizedBaseTypeLayered layer
    | Just object <- layer.objectLayer ->
        layeredOf layer {objectLayer = Just (NormalizedObject {fields = Map.mapWithKey reField object.fields, rest = object.rest})}
  _ -> objectType
  where
    reField :: Text -> NormalizedFieldInformation -> NormalizedFieldInformation
    reField name field =
      NormalizedFieldInformation {normalizedType = field.normalizedType, optional = field.optional || Set.member name names}

-- | The call (argument) shape of a constructor / request: its read shape with each defaulted parameter's
-- field made optional, so a caller may omit it. The read shape itself — field access, constructor
-- patterns, @data <: object@ — keeps every field required, so a constructed value's field never reads as
-- nullable.
callShape :: List (ParameterSignature Identified) -> NormalizedType -> NormalizedType
callShape parameters = markFieldsOptional (Set.fromList [signature.name | signature <- parameters, isJust signature.defaultValue])

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
-- | Collect a declaration's generic parameters and stamp each one's @extends@ upper bound. A bound
-- may reference sibling generics, so it is elaborated with the generics in scope. The bounds are
-- consulted by the normalizer while checking a body (raising a generic to its bound) and by
-- 'buildGenericSubstitution' when an explicit type argument is supplied.
boundedGenericParameters :: List (GenericParameter Identified) -> Checker GenericParameters
boundedGenericParameters declarations = do
  let (parameters, syntacticBounds) = collectGenericParameters declarations
  withGenerics parameters $ do
    normalizedBounds <- Map.fromList . catMaybes <$> traverse normalizeBound (Map.toList syntacticBounds)
    pure parameters {parameterInformation = stampBound normalizedBounds <$> parameters.parameterInformation}
  where
    normalizeBound (genericId, expression) = do
      maybeSemantic <- runElaborator (elaborate expression)
      case maybeSemantic of
        Just semantic -> do
          normalized <- runNormalizer (sourceSpanOf expression) (normalizeGenericArgument semantic)
          pure (Just (genericId, normalized))
        Nothing -> pure Nothing

prepareAgent :: AgentDeclaration Identified -> Checker AgentPreparation
prepareAgent declaration = do
  (outerAttribute, declaredAttribute) <- agentAttributes declaration
  genericParameters <- boundedGenericParameters declaration.genericParameters
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

-- | Build the 'Typed' agent declaration; every field but the parameters, body and stamped function
-- type ('typeOf') is a mechanical retag of the identified declaration. 'functionType' is the agent's
-- resolved @agent param -> return with effect@ type (denormalized), which lowering reads to build the
-- callable's schema for both top-level and local agents.
assembleTypedAgentDeclaration ::
  AgentDeclaration Identified ->
  List (ParameterBinding Typed) ->
  Block Typed ->
  SemanticType ->
  AgentDeclaration Typed
assembleTypedAgentDeclaration declaration typedParameters typedBody functionType =
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
      typeOf = functionType,
      sourceSpan = declaration.sourceSpan
    }

-- | The agent-body walk shared by the acyclic ('synthAgent') and recursive ('checkAgentBody') paths:
-- bring the agent's generics, world (declared attribute) and parameters into scope, push the agent's
-- @return@ boundary ('enterAgentBody') and capture its own @return@s (so a local agent's @return@ does
-- not escape an enclosing branch), synthesize the body, then /reconcile the result at the edge inside the
-- same scope/ — the inferred result (the body tail unioned with the collected @return@s) and inferred
-- effect, checked against any annotation. Running the edge checks inside the generics + world scope is
-- essential: a private agent's private result, or a generic's @extends@ bound, are only accepted against
-- the annotation under the body's world / generics. @expectedReturn@ / @expectedEffect@ are the annotation
-- policy ('Just' to check against, 'Nothing' to infer). Returns the resolved return type, effect and
-- typed body.
walkAgentBody ::
  AgentDeclaration Identified ->
  AgentPreparation ->
  Maybe NormalizedType ->
  Maybe NormalizedEffect ->
  Checker (NormalizedType, NormalizedEffect, Block Typed)
walkAgentBody declaration preparation expectedReturn expectedEffect =
  withGenerics preparation.genericParameters
    . withWorld preparation.declaredAttribute
    . withParameters preparation.parameterBindings
    $ do
      boundaryId <- freshBoundaryId
      (bodyEffect, (typedBody, tailType)) <-
        withEffectInference $ enterAgentBody boundaryId $ synthBlock declaration.body
      -- Discharge the agent's own @return@s (@EXIT(self)@): their union with the body tail is the agent's
      -- result (a diverging body's tail is @never@, so the @return@s drive it). An unannotated return type
      -- is exactly that union; an annotated one is the annotation, checked against the union here.
      let (returnExit, residualEffect) = splitExit boundaryId bodyEffect
      inferredReturn <- runNormalizer declaration.sourceSpan (union tailType returnExit)
      -- After discharging its own @return@, any concrete escape left in the effect targets a boundary
      -- that is not in scope — a misplaced jump or an escaping continuation (the soundness check).
      when (hasConcreteEscape residualEffect) $
        reportMisplacedJump declaration.sourceSpan "a `next` / `break` / `return`" "an enclosing `for`, handler, or agent that is still in scope"
      returnType <- case expectedReturn of
        Just expected -> do
          runNormalizer declaration.sourceSpan (subtype inferredReturn expected)
          pure expected
        Nothing -> pure inferredReturn
      finalEffect <- case expectedEffect of
        Just declared -> do
          runNormalizer declaration.sourceSpan (subtype residualEffect declared)
          pure declared
        Nothing -> pure residualEffect
      pure (returnType, finalEffect, typedBody)

-- | Check one acyclic agent, producing its 'Scheme' (its generics plus the function type). The
-- annotation policy is optional: a missing return type is synthesized from the body, a missing
-- effect defaults to the body's inferred effect.
synthAgent :: AgentDeclaration Identified -> Checker (AgentDeclaration Typed, Scheme)
synthAgent declaration = do
  preparation <- prepareAgent declaration
  (returnType, finalEffect, typedBody) <-
    walkAgentBody declaration preparation preparation.annotatedReturnType preparation.annotatedEffect
  let functionType = assembleAgent preparation.outerAttribute preparation.parameterObject returnType finalEffect
  functionSemantic <- denormalizeAt declaration.sourceSpan functionType
  pure
    ( assembleTypedAgentDeclaration declaration preparation.typedParameters typedBody functionSemantic,
      Scheme {genericParameters = preparation.genericParameters, valueType = functionType}
    )

-- | The function type of an acyclic agent, for tests that only need the synthesized type.
synthAgentType :: AgentDeclaration Identified -> Checker NormalizedType
synthAgentType = fmap ((.valueType) . snd) . synthAgent

-- | A recursive-group member's seed return type and effect, used both to build its seed scheme and to
-- check its body so the two agree by construction.
data SeededSignature = SeededSignature
  { returnType :: NormalizedType,
    effect :: NormalizedEffect
  }

-- | The seed return type and effect of a recursive-group member: its required annotations, an absent
-- one defaulting to bottom (the missing-annotation diagnostic is raised in 'seedAgentType').
seedReturnEffect :: AgentPreparation -> SeededSignature
seedReturnEffect preparation =
  SeededSignature
    { returnType = fromMaybe bottomType preparation.annotatedReturnType,
      effect = fromMaybe bottomEffect preparation.annotatedEffect
    }

-- | The seed scheme of one member of a recursive group, from its (required) return / effect
-- annotations. Takes the member's 'prepareAgent' result so the parameters are not elaborated twice
-- (the body pass reuses the same preparation).
seedAgentType :: AgentDeclaration Identified -> AgentPreparation -> Checker Scheme
seedAgentType declaration preparation = do
  when (isNothing declaration.returnType) $
    reportMissingAnnotation declaration.sourceSpan ("agent `" <> declaration.name <> "` in a recursive group requires an explicit return type")
  when (isNothing declaration.effects) $
    reportMissingAnnotation declaration.sourceSpan ("agent `" <> declaration.name <> "` in a recursive group requires an explicit effect annotation")
  let seeded = seedReturnEffect preparation
  pure
    Scheme
      { genericParameters = preparation.genericParameters,
        valueType = assembleAgent preparation.outerAttribute preparation.parameterObject seeded.returnType seeded.effect
      }

-- | Check one recursive-group member's body against its seed return type / effect (the same the seed
-- scheme is built from, via 'seedReturnEffect'), reusing its 'prepareAgent' result.
checkAgentBody :: AgentDeclaration Identified -> AgentPreparation -> Checker (AgentDeclaration Typed)
checkAgentBody declaration preparation = do
  let seeded = seedReturnEffect preparation
  -- The body is synthesized and its result (tail unioned with its @return@s) and effect are checked
  -- against the seed's (annotated, recursive-group-required) return / effect inside 'walkAgentBody'.
  (_, _, typedBody) <- walkAgentBody declaration preparation (Just seeded.returnType) (Just seeded.effect)
  -- The stamped function type uses the seed's (annotated) return / effect, identical to this member's
  -- seed scheme ('seedAgentType'), so the typed declaration and the value environment agree.
  functionSemantic <-
    denormalizeAt declaration.sourceSpan (assembleAgent preparation.outerAttribute preparation.parameterObject seeded.returnType seeded.effect)
  pure (assembleTypedAgentDeclaration declaration preparation.typedParameters typedBody functionSemantic)

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
  genericParameters <- boundedGenericParameters genericDeclarations
  withGenerics genericParameters $ do
    fields <-
      traverse
        ( \signature -> do
            parameterType <- elaborateAndNormalizeType signature.parameterType
            checkParameterDefault parameterType signature.defaultValue
            pure (signature.name, parameterType)
        )
        parameters
    returnNormalized <- elaborateAndNormalizeType returnType
    effectNormalized <- maybe (pure bottomEffect) elaborateAndNormalizeEffect effectExpression
    pure
      Scheme
        { genericParameters = genericParameters,
          -- The call shape makes each defaulted parameter omittable at the call site (the runtime fills
          -- the default), exactly as for data constructors and requests — every signature-determined
          -- callable shares the one 'callShape' rule.
          valueType = assembleAgent bottomAttribute (callShape parameters (namedObjectType fields)) returnNormalized effectNormalized
        }

-- | The value scheme of a data constructor: @agent(constructorObject) -> Data[generics]@ (pure),
-- read from the already-normalized 'DataInformation'. The constructor's parameters are a required
-- field object; the return is the nominal data type applied to the data type's own generics. Each
-- parameter's default is checked against its (already-normalized) field type.
dataValueScheme :: SourceSpan -> QualifiedName -> List (ParameterSignature Identified) -> Checker Scheme
dataValueScheme sourceSpan qualifiedName parameters = do
  dataEnvironment <- asks (\environment -> environment.typeEnvironment.dataEnvironment)
  case Map.lookup qualifiedName dataEnvironment of
    Just info -> do
      let readShape = objectAsType info.constructor
      checkConstructorDefaults info.genericParameters readShape parameters
      arguments <- ownGenericArguments sourceSpan info.genericParameters
      let returnType = layeredOf neverLayer {dataLayer = Map.singleton qualifiedName arguments}
      -- The constructor agent accepts the /call/ shape (defaulted parameters optional); the value it
      -- produces is the nominal type, whose fields are read through the (required) read shape.
      pure Scheme {genericParameters = info.genericParameters, valueType = assembleAgent bottomAttribute (callShape parameters readShape) returnType bottomEffect}
    Nothing -> panic ("dataValueScheme: data type not registered: " <> renderQualifiedName qualifiedName)

-- | The value scheme of a request performed as a value: @agent(param) -> return with {request}@,
-- read from the already-normalized 'RequestInformation'. The effect is the request applied to its
-- own generics.
requestValueScheme :: SourceSpan -> QualifiedName -> List (ParameterSignature Identified) -> Checker Scheme
requestValueScheme sourceSpan qualifiedName parameters = do
  requestEnvironment <- asks (\environment -> environment.typeEnvironment.requestEnvironment)
  case Map.lookup qualifiedName requestEnvironment of
    Just info -> do
      checkConstructorDefaults info.genericParameters info.parameterType parameters
      arguments <- ownGenericArguments sourceSpan info.genericParameters
      let effect = effectRow EffectRow {request = Map.singleton qualifiedName arguments, tails = mempty}
      -- Performing the request accepts the /call/ shape (defaulted parameters optional); the handler
      -- still receives the (required) read shape, the runtime having filled the defaults.
      pure Scheme {genericParameters = info.genericParameters, valueType = assembleAgent bottomAttribute (callShape parameters info.parameterType) info.returnType effect}
    Nothing -> panic ("requestValueScheme: request not registered: " <> renderQualifiedName qualifiedName)

-- | Check each constructor / request parameter's default against its field type in the
-- already-normalized parameter object, with the declaration's own generics in scope (a field type may
-- mention them). Field types are read back from the normalized object so the default is checked
-- against exactly the type the constructor exposes.
checkConstructorDefaults :: GenericParameters -> NormalizedType -> List (ParameterSignature Identified) -> Checker ()
checkConstructorDefaults genericParameters parameterObject parameters =
  withGenerics genericParameters (mapM_ checkOne parameters)
  where
    checkOne signature = case fieldTypeOf signature.name of
      Just fieldType -> checkParameterDefault fieldType signature.defaultValue
      Nothing -> pure ()
    fieldTypeOf name = case parameterObject.baseType of
      NormalizedBaseTypeLayered layer | Just object <- layer.objectLayer -> Just (objectFieldType object name)
      _ -> Nothing

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
  closureWorld <- currentWorld
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

-- | Synthesize the declared type of a binding-site pattern (an agent parameter, a @use@ binder) from
-- its structure — /reverse inference/, the dual of 'checkPattern': a type filter declares its shape
-- (@number(y)@ ~> @number@), a record / tuple declares a record / tuple of its children's synthesized
-- types (@{label => number(y)}@ ~> @{label: number}@), an annotated variable / wildcard declares its
-- annotation. The synthesized type makes the pattern non-refutable by construction (a @number(y)@
-- parameter is declared @number@, so it always matches). A bare variable / wildcard (no annotation), or
-- a shape that cannot be made total here (a constructor / literal pattern), has nothing to synthesize
-- from, so it is reported as needing an annotation and degrades to 'topType'.
--
-- The inner patterns are bound by the caller re-running 'checkPattern' against this type, which narrows
-- them and enforces the supertype-annotation rule — so @number(y : integer)@ fails (@number </:
-- integer@), the binder's annotation having to accept every value the filter admits.
synthBinderPatternType :: Text -> Pattern Identified -> Checker NormalizedType
synthBinderPatternType reason = \case
  PatternVariable variablePattern -> annotationOr variablePattern.sourceSpan variablePattern.typeAnnotation
  PatternWildcard wildcardPattern -> annotationOr wildcardPattern.sourceSpan wildcardPattern.typeAnnotation
  PatternTypeFilter typeFilterPattern -> pure (filterShape typeFilterPattern.matchedType)
  PatternTuple tuplePattern -> tupleOf <$> traverse (synthBinderPatternType reason) tuplePattern.elements
  PatternRecord recordPattern ->
    namedObjectType <$> traverse (\field -> (,) field.name <$> synthBinderPatternType reason field.bindPattern) recordPattern.fields
  PatternConstructor constructorPattern -> missing constructorPattern.sourceSpan
  PatternLiteral literalPattern -> missing literalPattern.sourceSpan
  where
    annotationOr sourceSpan = \case
      Just annotation -> elaborateAndNormalizeType annotation
      Nothing -> missing sourceSpan
    missing sourceSpan = do
      reportMissingAnnotation sourceSpan reason
      pure topType

-- | Check a binding-site pattern that declares its own type (an agent parameter, a @use@ binder). The
-- declared type is synthesized from the pattern ('synthBinderPatternType'), then the pattern is checked
-- against it — so the binder is non-refutable by construction, a variable binder's "must accept every
-- value" obligation holds trivially, and a type-filter / nested binder still narrows.
checkAnnotatedBinder ::
  Text ->
  Pattern Identified ->
  Checker (NormalizedType, Pattern Typed, List (LocalVariableId, Scheme))
checkAnnotatedBinder reason pattern = do
  declaredType <- synthBinderPatternType reason pattern
  (typedPattern, _, bindings) <- checkPattern pattern declaredType
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
  let defaultedNames = Set.fromList [name | (name, _, optional, _, _) <- entries, optional]
      -- The agent's parameter object: defaulted parameters are optional (the caller may omit them);
      -- the binders still see the (non-null) declared type.
      parameterObject = markFieldsOptional defaultedNames (namedObjectType [(name, parameterType) | (name, parameterType, _, _, _) <- entries])
      bindings = concat [bs | (_, _, _, bs, _) <- entries]
      typedParameters = [tp | (_, _, _, _, tp) <- entries]
  pure (parameterObject, bindings, typedParameters)
  where
    buildOne parameter = case parameter.binder of
      BindVariable variableReference typeAnnotation defaultValue -> do
        (parameterType, retaggedAnnotation) <- case typeAnnotation of
          Just annotation -> do
            normalized <- elaborateAndNormalizeType annotation
            pure (normalized, Just (retagSyntacticTypeExpression annotation))
          Nothing -> do
            reportMissingAnnotation parameter.sourceSpan ("agent parameter `" <> parameter.name <> "` requires a type annotation")
            pure (topType, Nothing)
        checkParameterDefault parameterType defaultValue
        let maybeLocal = case variableReference.resolution of
              Just (VariableResolutionLocalVariable localId) -> Just localId
              _ -> Nothing
            bindings = maybe [] (\localId -> [(localId, monoScheme parameterType)]) maybeLocal
            typedBinder = BindVariable (retagReference variableReference) retaggedAnnotation defaultValue
        pure (parameter.name, parameterType, isJust defaultValue, bindings, typedBinding parameter typedBinder)
      BindDestructure pattern -> do
        (parameterType, typedPattern, bindings) <-
          checkAnnotatedBinder ("agent parameter `" <> parameter.name <> "` requires a type annotation") pattern
        pure (parameter.name, parameterType, False, bindings, typedBinding parameter (BindDestructure typedPattern))
    typedBinding parameter binder =
      ParameterBinding
        { annotation = parameter.annotation,
          name = parameter.name,
          labelReference = retagReference parameter.labelReference,
          binder = binder,
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

-- | Check a parameter / pattern default (always a literal) against the parameter's declared type.
checkParameterDefault :: NormalizedType -> Maybe ParameterDefault -> Checker ()
checkParameterDefault declaredType = \case
  Nothing -> pure ()
  Just parameterDefault ->
    runNormalizer parameterDefault.sourceSpan (subtype (synthLiteralValue parameterDefault.value) declaredType)

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

-- | A generic value referenced without explicit type arguments (generic inference is unsupported, so
-- a generic value must be applied at every use site).
reportGenericNotApplied :: SourceSpan -> List Text -> Checker ()
reportGenericNotApplied sourceSpan parameterNames =
  reportType sourceSpan (TypeErrorGenericNotApplied GenericNotAppliedErrorInfo {parameters = parameterNames})

-- | The 'Scheme' a resolved value reference denotes, without instantiating it. Every top-level value
-- is seeded into the value environment by the SCC driver before any reference to it is checked, and
-- the identifier resolves every local, so a resolved reference is always found — a miss is a
-- compiler bug. An /unresolved/ reference (the identifier already reported it) degrades to bottom.
lookupScheme :: Maybe VariableResolution -> Checker Scheme
lookupScheme = \case
  Just (VariableResolutionLocalVariable localId) -> do
    maybeScheme <- asks (\environment -> Map.lookup localId environment.locals)
    case maybeScheme of
      Just scheme -> pure scheme
      Nothing -> panic "lookupScheme: resolved local variable is not in scope"
  Just (VariableResolutionQualifiedName qualifiedName) -> do
    maybeScheme <- asks (\environment -> Map.lookup qualifiedName environment.valueEnvironment)
    case maybeScheme of
      Just scheme -> pure scheme
      Nothing -> panic ("lookupScheme: top-level value not seeded: " <> renderQualifiedName qualifiedName)
  Nothing -> pure (monoScheme bottomType)

-- | The bare type of a value used where it is not explicitly applied. A generic value must be
-- applied first (generic inference is not supported), so a generic scheme here is an error; the
-- result degrades to bottom so no dangling generic leaks into the surrounding type.
instantiateBare :: SourceSpan -> Scheme -> Checker NormalizedType
instantiateBare sourceSpan scheme = case scheme.genericParameters.parameterNames of
  [] -> pure scheme.valueType
  parameterNames -> do
    reportGenericNotApplied sourceSpan parameterNames
    pure bottomType

-- | Bring a declaration's own generic parameters into scope (by id) while its body is checked, so
-- the normalizer consults each generic's bound and a body reference to a generic resolves.
withGenerics :: GenericParameters -> Checker a -> Checker a
withGenerics parameters action =
  foldr (\info -> withGeneric info.genericId info) action (Map.elems parameters.parameterInformation)

denormalizeAt :: SourceSpan -> NormalizedType -> Checker SemanticType
denormalizeAt sourceSpan normalizedType = runNormalizer sourceSpan (denormalize normalizedType)

-- | Build a typed expression node paired with the 'NormalizedType' the checker returns for it: run
-- 'denormalizeAt' once on that type and feed the resulting 'SemanticType' to the node builder. Every
-- @synth*@ ends this way, so routing them through one combinator guarantees a node's recorded @typeOf@
-- is always the denormalization of the very type the checker propagates (the two cannot drift).
typedExpression :: SourceSpan -> NormalizedType -> (SemanticType -> Expression Typed) -> Checker (Expression Typed, NormalizedType)
typedExpression sourceSpan normalizedType build = do
  semantic <- denormalizeAt sourceSpan normalizedType
  pure (build semantic, normalizedType)

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
booleanType = layeredOf neverLayer {booleanLayer = Set.fromList [False, True]}

-- | A boolean singleton (@true@ / @false@): the type a boolean literal /pattern/ covers, so a
-- @{ true => …; false => … }@ match is exhaustive while @{ 1 => … }@ on an integer is not.
booleanSingleton :: Bool -> NormalizedType
booleanSingleton value = layeredOf neverLayer {booleanLayer = Set.singleton value}

stringType :: NormalizedType
stringType = layeredOf neverLayer {stringLayer = True}

integerType :: NormalizedType
integerType = layeredOf neverLayer {numberLayer = NumberSlotInteger}

numberType :: NormalizedType
numberType = layeredOf neverLayer {numberLayer = NumberSlotNumber}

fileType :: NormalizedType
fileType = layeredOf neverLayer {fileLayer = True}
