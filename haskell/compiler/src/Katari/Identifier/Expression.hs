-- | Resolving expressions, statements, blocks, handlers, and the (locally declarable) agent
-- declaration — the bulk of the walk. Three things are more than a mechanical rebuild:
--
--   * A block resolves its statements with a sequential scope: a @let@ binds for the statements after
--     it (non-recursive — the value resolves first), a local @agent@ binds before its own body
--     (self-recursive), a @use@ binds its optional pattern over its continuation block. Each binding is
--     recorded with the exact region it is visible over.
--
--   * @object.field@ becomes a module-qualified reference when @object@ is a bare name that resolves to
--     a module and /not/ to a value (a value shadows a like-named module); otherwise it stays a field
--     access (the field label is resolved type-directed by the checker).
--
--   * A @for@ / @handler@ binds its @var@ state over the body and the @then@ clause, the loop pattern
--     over the body only, and parameters over their bodies. The @var@ state is also installed as the
--     enclosing state ('withStateVariables') so a @with@ modifier can target exactly those names.
module Katari.Identifier.Expression where

import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Id (VariableResolution (..))
import Katari.Data.ModuleName (ModuleName, renderModuleName)
import Katari.Data.SourceSpan (SourceSpan (..))
import Katari.Identifier.Monad
import Katari.Identifier.Pattern (resolveParameterBinding, resolvePattern)
import Katari.Identifier.Type (resolveType, withGenericParameters)
import Katari.Panic (panic)
import Katari.Primitive
  ( binaryOperatorLeftLabel,
    binaryOperatorName,
    binaryOperatorRightLabel,
    primitiveModuleName,
    unaryOperatorName,
    unaryOperatorOperandLabel,
  )

---------------------------------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------------------------------

resolveExpression :: Expression Parsed -> Identifier (Expression Identified)
resolveExpression = \case
  ExpressionLiteral node ->
    pure (ExpressionLiteral LiteralExpression {value = node.value, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionVariable node -> do
    variableReference <- resolveVariableReference node.sourceSpan node.name
    pure (ExpressionVariable VariableExpression {name = node.name, variableReference = variableReference, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionTuple node -> do
    elements <- traverse resolveExpression node.elements
    pure (ExpressionTuple TupleExpression {parallel = node.parallel, elements = elements, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionRecord node -> do
    entries <- traverse resolveRecordEntry node.entries
    pure (ExpressionRecord RecordExpression {entries = entries, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionCall node -> do
    callee <- resolveExpression node.callee
    reportDuplicateLabels [(argument.name, argument.sourceSpan) | argument <- node.arguments]
    arguments <- traverse resolveCallArgument node.arguments
    pure (ExpressionCall CallExpression {callee = callee, arguments = arguments, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionBinaryOperator node -> resolveBinaryOperator node
  ExpressionUnaryOperator node -> resolveUnaryOperator node
  ExpressionIf node -> do
    condition <- resolveExpression node.condition
    thenBlock <- resolveBlock node.thenBlock
    elseBlock <- traverse resolveBlock node.elseBlock
    pure (ExpressionIf IfExpression {condition = condition, thenBlock = thenBlock, elseBlock = elseBlock, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionMatch node -> do
    subject <- resolveExpression node.subject
    cases <- traverse resolveCaseArm node.cases
    pure (ExpressionMatch MatchExpression {subject = subject, cases = cases, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionFor node -> resolveFor node
  ExpressionBlock node -> do
    block <- resolveBlock node.block
    pure (ExpressionBlock BlockExpression {block = block, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionFieldAccess node -> resolveFieldAccess node
  ExpressionTypeApplication node -> do
    callee <- resolveExpression node.callee
    typeArguments <- traverse resolveType node.typeArguments
    pure (ExpressionTypeApplication TypeApplicationExpression {callee = callee, typeArguments = typeArguments, instantiation = (), sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionTemplate node -> do
    elements <- traverse resolveTemplateElement node.elements
    pure (ExpressionTemplate TemplateExpression {elements = elements, sourceSpan = node.sourceSpan, typeOf = ()})
  ExpressionHandler node -> resolveHandler node
  ExpressionQualifiedReference _ ->
    panic "Identifier.resolveExpression: the parser never produces ExpressionQualifiedReference"

resolveRecordEntry :: RecordEntry Parsed -> Identifier (RecordEntry Identified)
resolveRecordEntry entry = do
  value <- resolveExpression entry.value
  pure RecordEntry {name = entry.name, value = value, sourceSpan = entry.sourceSpan}

resolveCallArgument :: CallArgument Parsed -> Identifier (CallArgument Identified)
resolveCallArgument argument = do
  value <- resolveExpression argument.value
  pure CallArgument {name = argument.name, labelReference = retagReference argument.labelReference, value = value, sourceSpan = argument.sourceSpan}

resolveTemplateElement :: TemplateElement Parsed -> Identifier (TemplateElement Identified)
resolveTemplateElement = \case
  TemplateElementString element -> pure (TemplateElementString element)
  TemplateElementExpression element -> do
    value <- resolveExpression element.value
    pure (TemplateElementExpression TemplateExpressionElement {value = value, sourceSpan = element.sourceSpan})

---------------------------------------------------------------------------------------------------
-- Field access / module-qualified reference
---------------------------------------------------------------------------------------------------

-- | @object.field@ is a module-qualified reference when @object@ is a bare name bound to a module
-- and not to a value (a value of the same name shadows the module); otherwise an ordinary field
-- access.
resolveFieldAccess :: FieldAccessExpression Parsed -> Identifier (Expression Identified)
resolveFieldAccess node = case node.object of
  ExpressionVariable variableExpression -> do
    asValue <- lookupVariable variableExpression.name
    asModule <- lookupModule variableExpression.name
    case (asValue, asModule) of
      -- A value shadows a like-named module, so a bound value (or neither) is an ordinary field access.
      (Nothing, Just moduleName) -> qualifiedReference node variableExpression moduleName
      _ -> ordinaryFieldAccess node
  _ -> ordinaryFieldAccess node

ordinaryFieldAccess :: FieldAccessExpression Parsed -> Identifier (Expression Identified)
ordinaryFieldAccess node = do
  object <- resolveExpression node.object
  pure
    ( ExpressionFieldAccess
        FieldAccessExpression
          { object = object,
            fieldName = node.fieldName,
            labelReference = retagReference node.labelReference,
            sourceSpan = node.sourceSpan,
            typeOf = ()
          }
    )

qualifiedReference :: FieldAccessExpression Parsed -> VariableExpression Parsed -> ModuleName -> Identifier (Expression Identified)
qualifiedReference node variableExpression moduleName = do
  memberResolution <- resolveVariableMember node.labelReference.sourceSpan moduleName node.fieldName
  pure
    ( ExpressionQualifiedReference
        QualifiedReferenceExpression
          { moduleQualifier =
              ModuleQualifier
                { name = variableExpression.name,
                  moduleReference = identifiedReference variableExpression.sourceSpan (Just moduleName),
                  sourceSpan = variableExpression.sourceSpan
                },
            name = node.fieldName,
            variableReference = identifiedReference node.labelReference.sourceSpan memberResolution,
            sourceSpan = node.sourceSpan,
            typeOf = ()
          }
    )

---------------------------------------------------------------------------------------------------
-- Operator desugar (@a \<op\> b@ ~> @primitive.\<name\>(left = a, right = b)@)
---------------------------------------------------------------------------------------------------

-- | Desugar a binary operator @a \<op\> b@ into @primitive.\<name\>(left = a, right = b)@.
resolveBinaryOperator :: BinaryOperatorExpression Parsed -> Identifier (Expression Identified)
resolveBinaryOperator node = do
  left <- resolveExpression node.left
  right <- resolveExpression node.right
  pure
    ( primitiveCall
        node.sourceSpan
        (binaryOperatorName node.operator)
        [(binaryOperatorLeftLabel, left), (binaryOperatorRightLabel, right)]
    )

resolveUnaryOperator :: UnaryOperatorExpression Parsed -> Identifier (Expression Identified)
resolveUnaryOperator node = do
  operand <- resolveExpression node.operand
  pure (primitiveCall node.sourceSpan (unaryOperatorName node.operator) [(unaryOperatorOperandLabel, operand)])

-- | A call to a member of the wired-in @primitive@ module: @primitive.\<member\>(label = value, ...)@.
-- The callee's qualified reference is constructed directly, not resolved through scope, so the desugar
-- is immune to a user binding that shadows the name and needs no @primitive@ interface in scope (the
-- 'Katari.Primitive' table and the embedded module are kept in agreement by "Katari.StdlibSpec"). Every
-- synthetic node is anchored to @sourceSpan@ (the operator's own span) so diagnostics and LSP point at
-- what the user wrote.
primitiveCall :: SourceSpan -> Text -> List (Text, Expression Identified) -> Expression Identified
primitiveCall sourceSpan member arguments =
  ExpressionCall
    CallExpression
      { callee = callee,
        arguments = buildArgument <$> arguments,
        sourceSpan = sourceSpan,
        typeOf = ()
      }
  where
    callee =
      ExpressionQualifiedReference
        QualifiedReferenceExpression
          { moduleQualifier =
              ModuleQualifier
                { name = renderModuleName primitiveModuleName,
                  moduleReference = identifiedReference sourceSpan (Just primitiveModuleName),
                  sourceSpan = sourceSpan
                },
            name = member,
            variableReference = identifiedReference sourceSpan (Just (qualifiedVariableResolution primitiveModuleName member)),
            sourceSpan = sourceSpan,
            typeOf = ()
          }
    -- Synthetic labels carry no navigable source (label resolution is @()@), so the reference is built directly.
    buildArgument (label, value) =
      CallArgument {name = label, labelReference = Reference {sourceSpan = sourceSpan, resolution = ()}, value = value, sourceSpan = sourceSpan}

---------------------------------------------------------------------------------------------------
-- match / for / handler
---------------------------------------------------------------------------------------------------

resolveCaseArm :: CaseArm Parsed -> Identifier (CaseArm Identified)
resolveCaseArm arm = do
  (casePattern, bindings) <- resolvePattern arm.pattern
  body <- bindInScope arm.body.sourceSpan bindings (resolveBlock arm.body)
  pure CaseArm {pattern = casePattern, body = body, sourceSpan = arm.sourceSpan}

-- | Bind a @for@ / request-handler body under its state: the @var@ state and the body-local bindings
-- (loop pattern or handler parameters) both scope over the body, while the @var@ state alone is
-- installed as the @with@-modifier target set. Pairing the two here keeps them in step — a @then@
-- clause deliberately omits the install, so its @with@ sees the enclosing loop's state (see
-- 'resolveThenClause').
bindBodyWithState :: SourceSpan -> List Binding -> List Binding -> Identifier a -> Identifier a
bindBodyWithState region stateBindings localBindings =
  bindInScope region (stateBindings <> localBindings) . withStateVariables (stateVariableMap stateBindings)

-- | The loop pattern's variables scope over the body only; the @var@ state scopes over the body and
-- the @then@ clause (and is the only thing a @with@ modifier may target there); @var@ / loop-source
-- expressions are resolved in the enclosing scope.
resolveFor :: ForExpression Parsed -> Identifier (Expression Identified)
resolveFor node = do
  source <- resolveExpression node.inBinding.source
  (varBindings, varScope) <- resolveVariableBindings node.varBindings
  (loopPattern, loopBindings) <- resolvePattern node.inBinding.pattern
  body <- bindBodyWithState node.body.sourceSpan varScope loopBindings (resolveBlock node.body)
  thenClause <- traverse (resolveThenClause varScope) node.thenClause
  pure
    ( ExpressionFor
        ForExpression
          { parallel = node.parallel,
            inBinding = ForInBinding {pattern = loopPattern, source = source, sourceSpan = node.inBinding.sourceSpan},
            varBindings = varBindings,
            body = body,
            thenClause = thenClause,
            sourceSpan = node.sourceSpan,
            typeOf = ()
          }
    )

-- | @then [(pattern)] { body }@ — the @then@ pattern and the in-scope @var@ state bind over the body.
resolveThenClause :: List Binding -> ThenClause Parsed -> Identifier (ThenClause Identified)
resolveThenClause varScope thenClause = do
  (binder, binderBindings) <- resolveMaybePattern thenClause.binder
  body <- bindInScope thenClause.body.sourceSpan (varScope <> binderBindings) (resolveBlock thenClause.body)
  pure ThenClause {binder = binder, body = body, sourceSpan = thenClause.sourceSpan}

-- | @var name [: T] = initial@ — the initial is resolved in the enclosing scope; the name gets a
-- fresh local id. Returns the identified bindings and the scope additions they make. No sibling @var@
-- is in scope while its initial resolves, so the initials are mutually blind — a later @var@'s
-- initial cannot reference an earlier sibling (they are all one-time values of the enclosing scope).
resolveVariableBindings :: List (VariableBinding Parsed) -> Identifier (List (VariableBinding Identified), List Binding)
resolveVariableBindings bindings = unzip <$> traverse resolveVariableBinding bindings

resolveVariableBinding :: VariableBinding Parsed -> Identifier (VariableBinding Identified, Binding)
resolveVariableBinding binding = do
  initial <- resolveExpression binding.initial
  typeAnnotation <- traverse resolveType binding.typeAnnotation
  localVariableId <- freshLocalVariableId
  let resolution = VariableResolutionLocalVariable localVariableId
  pure
    ( VariableBinding
        { name = binding.name,
          variableReference = identifiedReference binding.variableReference.sourceSpan (Just resolution),
          typeAnnotation = typeAnnotation,
          initial = initial,
          sourceSpan = binding.sourceSpan
        },
      variableBinding binding.name binding.variableReference.sourceSpan resolution
    )

resolveHandler :: HandlerExpression Parsed -> Identifier (Expression Identified)
resolveHandler node = do
  genericArguments <- traverse resolveType node.genericArguments
  (stateVariables, stateScope) <- resolveVariableBindings node.stateVariables
  handlers <- traverse (resolveRequestHandler stateScope) node.handlers
  thenClause <- traverse (resolveThenClause stateScope) node.thenClause
  pure
    ( ExpressionHandler
        HandlerExpression
          { parallel = node.parallel,
            genericArguments = genericArguments,
            instantiation = (),
            stateVariables = stateVariables,
            handlers = handlers,
            thenClause = thenClause,
            sourceSpan = node.sourceSpan,
            typeOf = ()
          }
    )

-- | @request [module.]name[args](params) [-> T] { body }@ — the handled request is a name in the
-- type namespace; the parameters bind over the body, alongside the handler's @var@ state (which is
-- also the @with@-modifier target set within the body).
resolveRequestHandler :: List Binding -> RequestHandler Parsed -> Identifier (RequestHandler Identified)
resolveRequestHandler stateScope handler = do
  (moduleQualifier, typeReference) <- resolveRequestReference handler.moduleQualifier handler.name handler.typeReference
  genericArguments <- traverse resolveType handler.genericArguments
  (parameters, parameterBindings) <- resolveParameterBindings handler.parameters
  returnType <- traverse resolveType handler.returnType
  body <- bindBodyWithState handler.body.sourceSpan stateScope parameterBindings (resolveBlock handler.body)
  pure
    RequestHandler
      { moduleQualifier = moduleQualifier,
        name = handler.name,
        typeReference = typeReference,
        genericArguments = genericArguments,
        instantiation = (),
        parameters = parameters,
        returnType = returnType,
        body = body,
        sourceSpan = handler.sourceSpan
      }

-- | Resolve a handled request's name (qualified or not) in the type namespace.
resolveRequestReference ::
  Maybe (ModuleQualifier Parsed) ->
  Text ->
  Reference Parsed TypeReference ->
  Identifier (Maybe (ModuleQualifier Identified), Reference Identified TypeReference)
resolveRequestReference = resolveQualifiedReference resolveTypeReference resolveTypeMember

---------------------------------------------------------------------------------------------------
-- Blocks and statements
---------------------------------------------------------------------------------------------------

resolveBlock :: Block Parsed -> Identifier (Block Identified)
resolveBlock block = do
  (statements, returnExpression) <- resolveStatements block.sourceSpan block.statements block.returnExpression
  pure Block {statements = statements, returnExpression = returnExpression, sourceSpan = block.sourceSpan}

-- | Resolve a block's statements with a sequential scope, ending with the optional trailing value
-- (resolved in the scope every preceding statement has extended). Each statement wraps the
-- resolution of the rest in any scope it introduces, recording each binding over the exact region it
-- is visible (a @let@ / local @agent@ from its point to the block's end).
resolveStatements :: SourceSpan -> List (Statement Parsed) -> Maybe (Expression Parsed) -> Identifier (List (Statement Identified), Maybe (Expression Identified))
resolveStatements blockSpan statements returnExpression = foldr (resolveStatement blockSpan) resolveReturn statements
  where
    resolveReturn = do
      resolved <- traverse resolveExpression returnExpression
      pure ([], resolved)

-- | Resolve one statement, then resolve the rest of the block (the @continueRest@ action) within any
-- scope the statement introduces.
resolveStatement ::
  SourceSpan ->
  Statement Parsed ->
  Identifier (List (Statement Identified), Maybe (Expression Identified)) ->
  Identifier (List (Statement Identified), Maybe (Expression Identified))
resolveStatement blockSpan statement continueRest = case statement of
  StatementLet node -> do
    value <- resolveExpression node.value
    (letPattern, bindings) <- resolvePattern node.pattern
    bindInScope (restOfBlock node.sourceSpan blockSpan) bindings (prepend (StatementLet LetStatement {pattern = letPattern, value = value, sourceSpan = node.sourceSpan}) continueRest)
  StatementUse node -> do
    provider <- resolveExpression node.provider
    (binder, bindings) <- resolveMaybePattern node.binder
    body <- bindInScope node.body.sourceSpan bindings (resolveBlock node.body)
    prepend (StatementUse UseStatement {binder = binder, provider = provider, body = body, sourceSpan = node.sourceSpan}) continueRest
  StatementAgent node -> do
    localVariableId <- freshLocalVariableId
    let resolution = VariableResolutionLocalVariable localVariableId
        agentBinding = variableBinding node.name node.variableReference.sourceSpan resolution
    bindInScope (localAgentScope node.sourceSpan blockSpan) [agentBinding] $ do
      identified <- resolveAgentDeclaration resolution node
      prepend (StatementAgent identified) continueRest
  StatementReturn node -> do
    value <- resolveExpression node.value
    prepend (StatementReturn ReturnStatement {value = value, sourceSpan = node.sourceSpan}) continueRest
  StatementExpression expression -> do
    resolved <- resolveExpression expression
    prepend (StatementExpression resolved) continueRest
  StatementNext node -> do
    value <- resolveExpression node.value
    modifiers <- traverse resolveModifier node.modifiers
    prepend (StatementNext NextStatement {value = value, modifiers = modifiers, sourceSpan = node.sourceSpan}) continueRest
  StatementBreak node -> do
    value <- resolveExpression node.value
    prepend (StatementBreak BreakStatement {value = value, sourceSpan = node.sourceSpan}) continueRest
  StatementForNext node -> do
    value <- resolveExpression node.value
    modifiers <- traverse resolveModifier node.modifiers
    prepend (StatementForNext ForNextStatement {value = value, modifiers = modifiers, sourceSpan = node.sourceSpan}) continueRest
  StatementForBreak node -> do
    value <- resolveExpression node.value
    prepend (StatementForBreak ForBreakStatement {value = value, sourceSpan = node.sourceSpan}) continueRest
  StatementError sourceSpan -> prepend (StatementError sourceSpan) continueRest

prepend ::
  Statement Identified ->
  Identifier (List (Statement Identified), Maybe (Expression Identified)) ->
  Identifier (List (Statement Identified), Maybe (Expression Identified))
prepend statement continueRest = do
  (statements, returnExpression) <- continueRest
  pure (statement : statements, returnExpression)

-- | The region a non-recursive @let@ binding is visible over: from just after the @let@ statement to
-- the end of the enclosing block.
restOfBlock :: SourceSpan -> SourceSpan -> SourceSpan
restOfBlock statementSpan blockSpan = SourceSpan {filePath = blockSpan.filePath, start = statementSpan.end, end = blockSpan.end}

-- | The region a local @agent@ is visible over: from its declaration (self-recursive — visible in
-- its own body) to the end of the enclosing block. Because the region starts at the declaration (not
-- the block top), sibling local agents are /not/ mutually recursive: only a later statement sees an
-- earlier local agent. (Top-level declarations, whose scope is the whole module, are.)
localAgentScope :: SourceSpan -> SourceSpan -> SourceSpan
localAgentScope declarationSpan blockSpan = SourceSpan {filePath = blockSpan.filePath, start = declarationSpan.start, end = blockSpan.end}

-- | @with { name = expression, ... }@ — each name targets an enclosing @for@ / @handler@ state
-- variable (K2007 if it is not one).
resolveModifier :: Modifier Parsed -> Identifier (Modifier Identified)
resolveModifier modifier = do
  variableReference <- resolveStateVariableReference modifier.variableReference.sourceSpan modifier.name
  value <- resolveExpression modifier.value
  pure Modifier {name = modifier.name, variableReference = variableReference, value = value, sourceSpan = modifier.sourceSpan}

resolveMaybePattern :: Maybe (Pattern Parsed) -> Identifier (Maybe (Pattern Identified), List Binding)
resolveMaybePattern = \case
  Nothing -> pure (Nothing, [])
  Just pattern -> do
    (resolved, bindings) <- resolvePattern pattern
    pure (Just resolved, bindings)

---------------------------------------------------------------------------------------------------
-- Agent declaration (top-level and local)
---------------------------------------------------------------------------------------------------

-- | Resolve an agent declaration. The @ownResolution@ is what the agent's own name resolves to (a
-- qualified name top-level, a fresh local id for a local agent); the caller has already bound the
-- name in scope (so the body is self-recursive). Generics scope over the signature and body;
-- parameters bind over the body.
resolveAgentDeclaration :: VariableResolution -> AgentDeclaration Parsed -> Identifier (AgentDeclaration Identified)
resolveAgentDeclaration ownResolution declaration =
  withGenericParameters declaration.sourceSpan declaration.genericParameters $ \genericParameters -> do
    (parameters, parameterBindings) <- resolveParameterBindings declaration.parameters
    returnType <- traverse resolveType declaration.returnType
    effects <- traverse resolveType declaration.effects
    body <- bindInScope declaration.body.sourceSpan parameterBindings (resolveBlock declaration.body)
    pure
      AgentDeclaration
        { annotation = declaration.annotation,
          private = declaration.private,
          name = declaration.name,
          variableReference = identifiedReference declaration.variableReference.sourceSpan (Just ownResolution),
          genericParameters = genericParameters,
          parameters = parameters,
          returnType = returnType,
          effects = effects,
          body = body,
          sourceSpan = declaration.sourceSpan
        }

resolveParameterBindings :: List (ParameterBinding Parsed) -> Identifier (List (ParameterBinding Identified), List Binding)
resolveParameterBindings parameters = do
  reportDuplicateLabels [(parameter.name, parameter.sourceSpan) | parameter <- parameters]
  resolveAll resolveParameterBinding parameters
