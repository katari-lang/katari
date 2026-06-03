-- | Bidirectional type checker (replacing constraint generation + the global
-- unification solver + zonking). See
-- @docs/2026-06-04-bidirectional-typechecker.md@ for the full design.
--
-- The checker walks @Identified@ AST top-down, computing concrete
-- @SemanticType Resolved@ types directly — no type variables, no constraint
-- solving — and emits @Zonked@ AST. The only relational machinery it needs is
-- the already-pure subtype / normalise / union / intersect functions from
-- 'Katari.Typechecker.NormalizedType'.
--
-- Two judgments:
--
--   * 'synthExpr' — synthesise an expression's type bottom-up.
--   * 'checkExpr' — check an expression against an expected type (synthesise,
--     then assert @synthesised <: expected@).
--
-- WORK IN PROGRESS: this module is built incrementally alongside the live
-- constraint pipeline (it is not yet wired into 'Katari.Typechecker'). Forms
-- not yet handled go through 'unsupported', which records a diagnostic and
-- yields a placeholder so the walk stays total.
module Katari.Typechecker.Check
  ( CheckError (..),
    toDiagnostic,
    CheckEnv (..),
    Check,
    runCheck,
    elaborateType,
    subtypeAssert,
    synthExpr,
    checkExpr,
    CheckSubject (..),
    checkModule,
  )
where

import Control.Monad (forM, forM_)
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.List (transpose)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
import Katari.Common (LiteralValue (..), QualifiedName (..), TypePatternTag (..))
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Id (VariableResolution (..))
import Katari.Prim (PrimRule (..))
import Katari.SemanticType
import Katari.SemanticType.Render (renderSemanticType)
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Typechecker.Identifier (TypeData (..))
import Katari.Typechecker.AgentGraph (agentSCCs)
import Katari.Typechecker.NormalizedType
  ( DataFieldEnv,
    buildDataFieldEnv,
    normaliseSemantic,
    subtypeNormalizedType,
  )

-- ===========================================================================
-- Errors
-- ===========================================================================

data CheckError
  = -- | @left@ is not a subtype of the expected @right@.
    CheckErrorTypeMismatch SourceSpan (SemanticType Resolved) (SemanticType Resolved)
  | -- | A cyclic type-synonym definition was reached during elaboration.
    CheckErrorTypeSynonymCycle SourceSpan Text
  | -- | A variable reference did not resolve to a known binding (Identifier
    -- should have rejected this already; defensive).
    CheckErrorUnresolvedVariable SourceSpan Text
  | -- | A form the checker does not yet handle (WIP scaffold only).
    CheckErrorUnsupported SourceSpan Text
  deriving (Show)

-- | Convert a 'CheckError' to a unified 'Diagnostic'.
toDiagnostic :: CheckError -> Diagnostic
toDiagnostic = \case
  CheckErrorTypeMismatch sourceSpan actual expected ->
    diagnosticError
      "K0400"
      ("type mismatch: '" <> renderSemanticType actual <> "' is not a subtype of '" <> renderSemanticType expected <> "'")
      sourceSpan
  CheckErrorTypeSynonymCycle sourceSpan name ->
    diagnosticError "K0200" ("cyclic type synonym '" <> name <> "'") sourceSpan
  CheckErrorUnresolvedVariable sourceSpan name ->
    diagnosticError "K0401" ("unresolved variable '" <> name <> "'") sourceSpan
  CheckErrorUnsupported sourceSpan what ->
    diagnosticError "K0499" ("typechecker (bidirectional, WIP): unsupported form: " <> what) sourceSpan

-- ===========================================================================
-- Environment + monad
-- ===========================================================================

data CheckEnv = CheckEnv
  { -- | Type declarations reachable from this module (own + imports). Used to
    -- expand type synonyms during elaboration.
    checkTypeData :: Map QualifiedName TypeData,
    -- | The @data <: object@ field map, built from the resolved data
    -- constructors processed so far.
    checkDataFieldEnv :: DataFieldEnv,
    -- | Type synonyms currently being expanded (cycle detection).
    checkSynonymVisited :: Set QualifiedName,
    -- | Local variable types — parameters, @let@ bindings, pattern bindings,
    -- state vars — and the module's own + imported top-level callable
    -- signatures, all keyed by 'VariableResolution'.
    checkLocals :: Map VariableResolution (SemanticType Resolved),
    -- | Prim rules (operator / array prims whose result type isn't a plain
    -- signature). Keyed by the prim's qualified name.
    checkPrimRules :: Map QualifiedName PrimRule,
    -- | The enclosing agent body's declared / expected return type, if any.
    checkExpectedReturn :: Maybe (SemanticType Resolved)
  }

-- | Where a non-local control transfer goes — used to collect the value types
-- a @for@ / handle expression can produce via @break@ / @next@.
data ExitTag = ForBreakTag | HandleBreakTag | HandleNextTag
  deriving (Eq, Show)

data ExitRecord = ExitRecord ExitTag (SemanticType Resolved)

data CheckState = CheckState
  { stateErrors :: [CheckError],
    -- | Pending @break@ / @next@ value types, consumed by the nearest
    -- enclosing @for@ / handle scope (see 'collectExits').
    stateExits :: [ExitRecord]
  }

type Check = ReaderT CheckEnv (State CheckState)

-- | Run a checker action against an environment, returning the result and the
-- accumulated diagnostics (in source order).
runCheck :: CheckEnv -> Check a -> (a, [CheckError])
runCheck env action =
  let (result, finalState) = runState (runReaderT action env) (CheckState [] [])
   in (result, reverse finalState.stateErrors)

emitError :: CheckError -> Check ()
emitError err = modify' $ \s -> s {stateErrors = err : s.stateErrors}

lookupLocal :: VariableResolution -> Check (Maybe (SemanticType Resolved))
lookupLocal resolution = asks (Map.lookup resolution . (.checkLocals))

-- | Extend the local environment for the duration of an action.
withLocals :: [(VariableResolution, SemanticType Resolved)] -> Check a -> Check a
withLocals bindings =
  local (\e -> e {checkLocals = Map.union (Map.fromList bindings) e.checkLocals})

-- | Set the enclosing agent's expected return type.
withExpectedReturn :: SemanticType Resolved -> Check a -> Check a
withExpectedReturn expected = local (\e -> e {checkExpectedReturn = Just expected})

-- | Record a pending exit value (a @break@ / @next@ payload) for the nearest
-- enclosing scope to collect.
recordExit :: ExitTag -> SemanticType Resolved -> Check ()
recordExit tag semantic = modify' $ \s -> s {stateExits = ExitRecord tag semantic : s.stateExits}

-- | Run an action, then peel off the exits matching @tags@ that it recorded,
-- returning their value types. Non-matching exits are left in place so they
-- propagate to an outer scope (a @break@ inside a @for@ targets an enclosing
-- handle, etc.).
collectExits :: [ExitTag] -> Check a -> Check (a, [SemanticType Resolved])
collectExits tags action = do
  before <- gets (.stateExits)
  result <- action
  after <- gets (.stateExits)
  let added = take (length after - length before) after
      (matching, rest) = foldr partition ([], []) added
      partition rec@(ExitRecord tag semantic) (yes, no) =
        if tag `elem` tags then (semantic : yes, no) else (yes, rec : no)
  modify' $ \s -> s {stateExits = rest ++ before}
  pure (result, matching)

-- ===========================================================================
-- Type elaboration (SyntacticType Identified -> SemanticType Resolved)
-- ===========================================================================

-- | Elaborate a syntactic type into a resolved semantic type, expanding type
-- synonyms transparently (cycles surface as a diagnostic).
elaborateType :: SyntacticType Identified -> Check (SemanticType Resolved)
elaborateType = \case
  TypePrimitive PrimitiveTypeNode {kind} -> pure (primitiveToSemantic kind)
  TypeName TypeNameNode {name} -> resolveTypeRef name
  TypeQualified QualifiedTypeNode {target} -> resolveTypeRef target
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withRequests} -> do
    parameterEntries <- mapM (\(label, pt) -> (,) label <$> elaborateType pt) parameterTypes
    returnSemantic <- elaborateType returnType
    requests <- elaborateRequestList withRequests
    pure (SemanticTypeFunction (requiredParameter <$> Map.fromList parameterEntries) returnSemantic requests)
  TypeArray ArrayTypeNode {elementType} ->
    SemanticTypeArray <$> elaborateType elementType
  TypeTuple TupleTypeNode {elementTypes} ->
    SemanticTypeTuple <$> mapM elaborateType elementTypes
  TypeUnion TypeUnionNode {branches} ->
    unionSemantic <$> mapM elaborateType branches
  TypeLiteral TypeLiteralNode {value} -> pure (literalValueToSemantic value)
  TypeNever _ -> pure SemanticTypeNever
  TypeUnknown _ -> pure SemanticTypeUnknown
  TypeFunctionAny _ -> pure SemanticTypeFunctionAny
  TypeRecord RecordTypeNode {valueType} ->
    SemanticTypeRecord <$> elaborateType valueType
  TypeObject ObjectTypeNode {fields} ->
    SemanticTypeObject . Map.fromList <$> mapM (\(label, fieldSyntactic) -> (label,) <$> elaborateType fieldSyntactic) fields

resolveTypeRef :: NameRef Identified TypeRef -> Check (SemanticType Resolved)
resolveTypeRef nameRef = case nameRef.resolution of
  Just qualifiedName -> do
    types <- asks (.checkTypeData)
    case Map.lookup qualifiedName types of
      Just TypeData {typeSynonymRhs = Just rhs} -> do
        visited <- asks (.checkSynonymVisited)
        if Set.member qualifiedName visited
          then do
            emitError (CheckErrorTypeSynonymCycle nameRef.sourceSpan qualifiedName.name)
            pure SemanticTypeUnknown
          else local (\e -> e {checkSynonymVisited = Set.insert qualifiedName e.checkSynonymVisited}) (elaborateType rhs)
      Just TypeData {typeSynonymRhs = Nothing} ->
        pure (SemanticTypeData qualifiedName)
      Nothing ->
        pure SemanticTypeUnknown
  Nothing -> pure SemanticTypeUnknown

-- | Elaborate a @with@ clause into a concrete request set (only names that are
-- known requests contribute).
elaborateRequestList :: [SyntacticRequest Identified] -> Check (SemanticRequest Resolved)
elaborateRequestList syntacticRequests =
  pure
    ( SemanticRequest
        ( Set.fromList
            [ SemanticRequestElementConcrete qualifiedName
              | SyntacticRequest {name = NameRef {resolution = Just qualifiedName}} <- syntacticRequests
            ]
        )
    )

primitiveToSemantic :: PrimitiveTypeKind -> SemanticType phase
primitiveToSemantic = \case
  PrimitiveTypeKindNull -> SemanticTypeNull
  PrimitiveTypeKindInteger -> SemanticTypeInteger
  PrimitiveTypeKindNumber -> SemanticTypeNumber
  PrimitiveTypeKindString -> SemanticTypeString
  PrimitiveTypeKindSecret -> SemanticTypeSecret
  PrimitiveTypeKindFile -> SemanticTypeFile
  PrimitiveTypeKindBoolean -> SemanticTypeBoolean

literalValueToSemantic :: LiteralValue -> SemanticType phase
literalValueToSemantic = \case
  LiteralValueNull -> SemanticTypeNull
  LiteralValueInteger n -> SemanticTypeLiteralInteger n
  LiteralValueNumber _ -> SemanticTypeNumber
  LiteralValueString s -> SemanticTypeLiteralString s
  LiteralValueBoolean b -> SemanticTypeLiteralBoolean b
  LiteralValueAgent _ -> SemanticTypeUnknown

-- ===========================================================================
-- Subtype assertion
-- ===========================================================================

-- | Assert @actual <: expected@. On failure, record a 'CheckErrorTypeMismatch'
-- and continue (the caller recovers by stamping the expected type).
subtypeAssert :: SourceSpan -> SemanticType Resolved -> SemanticType Resolved -> Check ()
subtypeAssert sourceSpan actual expected = do
  dataFieldEnv <- asks (.checkDataFieldEnv)
  let holds = subtypeNormalizedType dataFieldEnv (normaliseSemantic actual) (normaliseSemantic expected)
  if holds then pure () else emitError (CheckErrorTypeMismatch sourceSpan actual expected)

-- ===========================================================================
-- Expression checking
-- ===========================================================================

-- | Check an expression against an expected type: synthesise it, then assert
-- the synthesised type is a subtype of the expectation.
checkExpr :: Expression Identified -> SemanticType Resolved -> Check (Expression Zonked)
checkExpr expression expected = do
  (zonked, actual) <- synthExpr expression
  subtypeAssert (sourceSpanOf expression) actual expected
  pure zonked

-- | Synthesise an expression's type bottom-up, producing the zonked node.
synthExpr :: Expression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthExpr = \case
  ExpressionLiteral LiteralExpression {value, sourceSpan} ->
    let semantic = literalValueToSemantic value
     in pure (ExpressionLiteral LiteralExpression {value = value, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionVariable VariableExpression {name, sourceSpan} -> do
    semantic <- lookupVariableType sourceSpan name.text name.resolution
    pure (ExpressionVariable VariableExpression {name = retagNameRef name, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionQualifiedReference QualifiedReferenceExpression {moduleQualifier, target, sourceSpan} -> do
    semantic <- lookupVariableType sourceSpan target.text target.resolution
    pure
      ( ExpressionQualifiedReference
          QualifiedReferenceExpression {moduleQualifier = retagNameRef moduleQualifier, target = retagNameRef target, sourceSpan = sourceSpan, typeOf = semantic},
        semantic
      )
  ExpressionTuple TupleExpression {elements, sourceSpan} -> do
    walked <- mapM synthExpr elements
    let semantic = SemanticTypeTuple (map snd walked)
    pure (ExpressionTuple TupleExpression {elements = map fst walked, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionParTuple ParTupleExpression {elements, sourceSpan} -> do
    walked <- mapM synthExpr elements
    let semantic = SemanticTypeTuple (map snd walked)
    pure (ExpressionParTuple ParTupleExpression {elements = map fst walked, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionRecord RecordExpression {entries, sourceSpan} -> do
    walked <- mapM (\(label, e) -> (,) label <$> synthExpr e) entries
    let semantic = SemanticTypeObject (Map.fromList [(label, snd we) | (label, we) <- walked])
    pure
      ( ExpressionRecord RecordExpression {entries = [(label, fst we) | (label, we) <- walked], sourceSpan = sourceSpan, typeOf = semantic},
        semantic
      )
  ExpressionCall callExpr -> synthCall callExpr
  ExpressionIf ifExpr -> synthIf ifExpr
  ExpressionMatch matchExpr -> synthMatch matchExpr
  ExpressionFor forExpr -> synthFor forExpr
  ExpressionHandle handleExpr -> synthHandle handleExpr
  ExpressionBlock BlockExpression {block, sourceSpan} -> do
    (block', semantic) <- walkBlock block
    pure (ExpressionBlock BlockExpression {block = block', sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionFieldAccess FieldAccessExpression {object, fieldName, sourceSpan} -> do
    (object', objectType) <- synthExpr object
    semantic <- fieldType sourceSpan objectType fieldName.text
    pure
      ( ExpressionFieldAccess FieldAccessExpression {object = object', fieldName = retagNameRef fieldName, sourceSpan = sourceSpan, typeOf = semantic},
        semantic
      )
  ExpressionIndexAccess IndexAccessExpression {array, index, sourceSpan} -> do
    (array', arrayType) <- synthExpr array
    index' <- checkExpr index SemanticTypeInteger
    let semantic = seqElementType arrayType
    pure
      ( ExpressionIndexAccess IndexAccessExpression {array = array', index = index', sourceSpan = sourceSpan, typeOf = semantic},
        semantic
      )
  ExpressionTemplate TemplateExpression {elements, sourceSpan} -> do
    walked <- mapM walkTemplateElement elements
    let interpolated = mapMaybe snd walked
    let semantic = unionSemantic (SemanticTypeString : interpolated)
    pure (ExpressionTemplate TemplateExpression {elements = map fst walked, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionBinaryOperator BinaryOperatorExpression {sourceSpan} -> internalNull sourceSpan "BinaryOperator survived past the Identifier desugar"
  ExpressionUnaryOperator UnaryOperatorExpression {sourceSpan} -> internalNull sourceSpan "UnaryOperator survived past the Identifier desugar"

-- | Look up a variable / top-level callable reference's type.
lookupVariableType :: SourceSpan -> Text -> Maybe VariableResolution -> Check (SemanticType Resolved)
lookupVariableType sourceSpan name = \case
  Just resolution ->
    lookupLocal resolution >>= \case
      Just found -> pure found
      Nothing -> emitError (CheckErrorUnresolvedVariable sourceSpan name) >> pure SemanticTypeUnknown
  Nothing -> emitError (CheckErrorUnresolvedVariable sourceSpan name) >> pure SemanticTypeUnknown

-- | A form that the Identifier pass should have eliminated — record an
-- internal-invariant diagnostic and yield a @null@ placeholder.
internalNull :: SourceSpan -> Text -> Check (Expression Zonked, SemanticType Resolved)
internalNull sourceSpan reason = do
  emitError (CheckErrorUnsupported sourceSpan ("internal invariant: " <> reason))
  pure (ExpressionLiteral LiteralExpression {value = LiteralValueNull, sourceSpan = sourceSpan, typeOf = SemanticTypeNull}, SemanticTypeNull)

walkTemplateElement :: TemplateElement Identified -> Check (TemplateElement Zonked, Maybe (SemanticType Resolved))
walkTemplateElement = \case
  TemplateElementString TemplateStringElement {value, sourceSpan} ->
    pure (TemplateElementString TemplateStringElement {value = value, sourceSpan = sourceSpan}, Nothing)
  TemplateElementExpression TemplateExpressionElement {value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    subtypeAssert sourceSpan valueType (SemanticTypeUnion [SemanticTypeString, SemanticTypeSecret])
    pure (TemplateElementExpression TemplateExpressionElement {value = value', sourceSpan = sourceSpan}, Just valueType)

-- ---------------------------------------------------------------------------
-- Call
-- ---------------------------------------------------------------------------

synthCall :: CallExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthCall CallExpression {callee, arguments, sourceSpan} = do
  (callee', calleeType) <- synthExpr callee
  walkedArgs <- mapM walkCallArgument arguments
  let arguments' = map fst walkedArgs
      argTypes = Map.fromList [(label, argType) | (_, (label, argType)) <- walkedArgs]
  primRule <- calleePrimRule callee
  result <- case primRule of
    Just rule | rule /= PrimRuleSimple -> applyPrimRule rule argTypes sourceSpan
    _ -> applyNormalCall sourceSpan calleeType argTypes
  pure (ExpressionCall CallExpression {callee = callee', arguments = arguments', sourceSpan = sourceSpan, typeOf = result}, result)

walkCallArgument :: CallArgument Identified -> Check (CallArgument Zonked, (Text, SemanticType Resolved))
walkCallArgument CallArgument {label, value, sourceSpan} = do
  (value', valueType) <- synthExpr value
  pure (CallArgument {label = retagNameRef label, value = value', sourceSpan = sourceSpan}, (label.text, valueType))

-- | Does the callee resolve to a prim with a special result rule?
calleePrimRule :: Expression Identified -> Check (Maybe PrimRule)
calleePrimRule = \case
  ExpressionVariable VariableExpression {name = NameRef {resolution = Just (ResolvedTopLevel qualifiedName)}} ->
    asks (Map.lookup qualifiedName . (.checkPrimRules))
  ExpressionQualifiedReference QualifiedReferenceExpression {target = NameRef {resolution = Just (ResolvedTopLevel qualifiedName)}} ->
    asks (Map.lookup qualifiedName . (.checkPrimRules))
  _ -> pure Nothing

-- | Generic call: the callee must be a function; each supplied argument is a
-- subtype of its parameter; the result is the declared return type.
applyNormalCall :: SourceSpan -> SemanticType Resolved -> Map Text (SemanticType Resolved) -> Check (SemanticType Resolved)
applyNormalCall sourceSpan calleeType argTypes = case calleeType of
  SemanticTypeFunction params returnType _ -> do
    forM_ (Map.toList params) $ \(label, parameter) ->
      case Map.lookup label argTypes of
        Just argType -> subtypeAssert sourceSpan argType parameter.parameterType
        Nothing
          | parameter.optional -> pure ()
          | otherwise -> emitError (CheckErrorUnsupported sourceSpan ("missing required argument '" <> label <> "'"))
    pure returnType
  SemanticTypeFunctionAny -> pure SemanticTypeUnknown
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  _ -> do
    emitError (CheckErrorTypeMismatch sourceSpan calleeType SemanticTypeFunctionAny)
    pure SemanticTypeUnknown

-- | Result-type rules for the prims whose result is not a plain signature
-- (operators, array shape ops). Computed directly on concrete argument types.
applyPrimRule :: PrimRule -> Map Text (SemanticType Resolved) -> SourceSpan -> Check (SemanticType Resolved)
applyPrimRule rule argTypes sourceSpan =
  let arg label = Map.findWithDefault SemanticTypeUnknown label argTypes
   in case rule of
        PrimRuleNumericJoinBinary -> do
          subtypeAssert sourceSpan (arg "lhs") SemanticTypeNumber
          subtypeAssert sourceSpan (arg "rhs") SemanticTypeNumber
          pure (unionSemantic [arg "lhs", arg "rhs", SemanticTypeInteger])
        PrimRuleNumericJoinUnary -> do
          subtypeAssert sourceSpan (arg "value") SemanticTypeNumber
          pure (unionSemantic [arg "value", SemanticTypeInteger])
        PrimRuleFstringJoin -> do
          let stringOrSecret = SemanticTypeUnion [SemanticTypeString, SemanticTypeSecret]
          mapM_ (\argType -> subtypeAssert sourceSpan argType stringOrSecret) (Map.elems argTypes)
          pure (unionSemantic (SemanticTypeString : Map.elems argTypes))
        PrimRuleArrayGet -> do
          subtypeAssert sourceSpan (arg "index") SemanticTypeInteger
          pure (seqElementType (arg "array"))
        PrimRuleArrayShape ->
          let elements =
                concat
                  [ seqElementType <$> mapMaybe (`Map.lookup` argTypes) ["array", "lhs", "rhs"],
                    maybe [] pure (Map.lookup "value" argTypes)
                  ]
           in pure (SemanticTypeArray (unionSemantic elements))
        PrimRuleSimple -> pure SemanticTypeUnknown

-- ---------------------------------------------------------------------------
-- if / match / for / handle
-- ---------------------------------------------------------------------------

synthIf :: IfExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthIf IfExpression {condition, thenBlock, elseBlock, sourceSpan} = do
  condition' <- checkExpr condition SemanticTypeBoolean
  (thenBlock', thenType) <- walkBlock thenBlock
  (elseBlock', elseType) <- case elseBlock of
    Just b -> do (b', ty) <- walkBlock b; pure (Just b', ty)
    Nothing -> pure (Nothing, SemanticTypeNull)
  let semantic = unionSemantic [thenType, elseType]
  pure
    ( ExpressionIf IfExpression {condition = condition', thenBlock = thenBlock', elseBlock = elseBlock', sourceSpan = sourceSpan, typeOf = semantic},
      semantic
    )

synthMatch :: MatchExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthMatch MatchExpression {subject, cases, sourceSpan} = do
  (subject', subjectType) <- synthExpr subject
  walked <- mapM (walkCaseArm subjectType) cases
  let semantic = unionSemantic (map snd walked)
  pure (ExpressionMatch MatchExpression {subject = subject', cases = map fst walked, sourceSpan = sourceSpan, typeOf = semantic}, semantic)

walkCaseArm :: SemanticType Resolved -> CaseArm Identified -> Check (CaseArm Zonked, SemanticType Resolved)
walkCaseArm subjectType CaseArm {pattern, body, sourceSpan} = do
  (pattern', bindings) <- walkPattern subjectType pattern
  (body', bodyType) <- withLocals bindings (walkBlock body)
  pure (CaseArm {pattern = pattern', body = body', sourceSpan = sourceSpan}, bodyType)

synthFor :: ForExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthFor ForExpression {parallel, inBindings, varBindings, body, thenBlock, sourceSpan} = do
  (inBindings', inLocals) <- unzipBindings <$> mapM walkForInBinding inBindings
  (varBindings', varLocals) <- unzipBindings <$> mapM walkForVarBinding varBindings
  let loopLocals = inLocals ++ varLocals
  ((body', thenBlock', thenType), breakTypes) <-
    collectExits [ForBreakTag] $
      withLocals loopLocals $ do
        (body', _) <- walkBlock body
        (thenBlock', thenType) <- case thenBlock of
          Just b -> do (b', ty) <- walkBlock b; pure (Just b', ty)
          Nothing -> pure (Nothing, SemanticTypeNull)
        pure (body', thenBlock', thenType)
  let semantic = unionSemantic (thenType : breakTypes)
  pure
    ( ExpressionFor ForExpression {parallel = parallel, inBindings = inBindings', varBindings = varBindings', body = body', thenBlock = thenBlock', sourceSpan = sourceSpan, typeOf = semantic},
      semantic
    )

unzipBindings :: [(a, [b])] -> ([a], [b])
unzipBindings xs = (map fst xs, concatMap snd xs)

walkForInBinding :: ForInBinding Identified -> Check (ForInBinding Zonked, [(VariableResolution, SemanticType Resolved)])
walkForInBinding ForInBinding {pattern, source, sourceSpan} = do
  (source', sourceType) <- synthExpr source
  let elementType = seqElementType sourceType
  (pattern', bindings) <- walkPattern elementType pattern
  pure (ForInBinding {pattern = pattern', source = source', sourceSpan = sourceSpan}, bindings)

walkForVarBinding :: ForVarBinding Identified -> Check (ForVarBinding Zonked, [(VariableResolution, SemanticType Resolved)])
walkForVarBinding ForVarBinding {name, typeAnnotation, initial, sourceSpan} = do
  (initial', binding) <- walkInitializer name typeAnnotation initial
  pure
    ( ForVarBinding {name = retagNameRef name, typeAnnotation = fmap retagSyntacticType typeAnnotation, initial = initial', sourceSpan = sourceSpan},
      binding
    )

synthHandle :: HandleExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthHandle HandleExpression {parallel, stateVariables, handlers, thenClause, body, sourceSpan} = do
  (stateVariables', stateLocals) <- unzipBindings <$> mapM walkStateVariable stateVariables
  ((body', bodyType, handlers', thenClause', thenType), breakTypes) <-
    collectExits [HandleBreakTag, HandleNextTag] $
      withLocals stateLocals $ do
        (body', bodyType) <- walkBlock body
        handlers' <- mapM walkRequestHandler handlers
        (thenClause', thenType) <- case thenClause of
          Nothing -> pure (Nothing, Nothing)
          Just (maybePattern, thenBody) -> do
            (pattern', bindings) <- case maybePattern of
              Just p -> do (p', bs) <- walkPattern bodyType p; pure (Just p', bs)
              Nothing -> pure (Nothing, [])
            (thenBody', thenBodyType) <- withLocals bindings (walkBlock thenBody)
            pure (Just (pattern', thenBody'), Just thenBodyType)
        pure (body', bodyType, handlers', thenClause', thenType)
  let semantic = unionSemantic (maybe bodyType id thenType : breakTypes)
  pure
    ( ExpressionHandle HandleExpression {parallel = parallel, stateVariables = stateVariables', handlers = handlers', thenClause = thenClause', body = body', sourceSpan = sourceSpan, typeOf = semantic},
      semantic
    )

walkStateVariable :: StateVariableBinding Identified -> Check (StateVariableBinding Zonked, [(VariableResolution, SemanticType Resolved)])
walkStateVariable StateVariableBinding {name, typeAnnotation, initial, sourceSpan} = do
  (initial', binding) <- walkInitializer name typeAnnotation initial
  pure
    ( StateVariableBinding {name = retagNameRef name, typeAnnotation = fmap retagSyntacticType typeAnnotation, initial = initial', sourceSpan = sourceSpan},
      binding
    )

walkRequestHandler :: RequestHandler Identified -> Check (RequestHandler Zonked)
walkRequestHandler RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  (parameters', _, paramLocals) <- elaborateParameters parameters
  (body', _) <- withLocals paramLocals (walkBlock body)
  pure
    RequestHandler
      { moduleQualifier = fmap retagNameRef moduleQualifier,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        body = body',
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Blocks and statements
-- ---------------------------------------------------------------------------

-- | Walk a block: thread @let@ bindings into the env for later statements and
-- the tail expression. The block's type is its tail expression's type (or
-- @null@ when absent / @never@ when an exit statement precedes the tail).
walkBlock :: Block Identified -> Check (Block Zonked, SemanticType Resolved)
walkBlock Block {statements, returnExpression, sourceSpan} = do
  (statements', returnExpression') <- walkStatements statements returnExpression
  let semantic
        | any isExitStatement statements = SemanticTypeNever
        | otherwise = maybe SemanticTypeNull snd returnExpression'
  pure (Block {statements = statements', returnExpression = fmap fst returnExpression', sourceSpan = sourceSpan}, semantic)

isExitStatement :: Statement phase -> Bool
isExitStatement = \case
  StatementReturn _ -> True
  StatementNext _ -> True
  StatementBreak _ -> True
  StatementForNext _ -> True
  StatementForBreak _ -> True
  _ -> False

-- | Walk statements left-to-right, extending the env with each binding so
-- subsequent statements + the tail see it.
walkStatements ::
  [Statement Identified] ->
  Maybe (Expression Identified) ->
  Check ([Statement Zonked], Maybe (Expression Zonked, SemanticType Resolved))
walkStatements [] returnExpression = do
  tail' <- traverse synthExpr returnExpression
  pure ([], tail')
walkStatements (statement : rest) returnExpression = do
  (statement', bindings) <- walkStatement statement
  (rest', tail') <- withLocals bindings (walkStatements rest returnExpression)
  pure (statement' : rest', tail')

walkStatement :: Statement Identified -> Check (Statement Zonked, [(VariableResolution, SemanticType Resolved)])
walkStatement = \case
  StatementLet LetStatement {pattern, value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    (pattern', bindings) <- walkPattern valueType pattern
    pure (StatementLet LetStatement {pattern = pattern', value = value', sourceSpan = sourceSpan}, bindings)
  StatementReturn ReturnStatement {value, sourceSpan} -> do
    expected <- asks (.checkExpectedReturn)
    value' <- case expected of
      Just t -> checkExpr value t
      Nothing -> fst <$> synthExpr value
    pure (StatementReturn ReturnStatement {value = value', sourceSpan = sourceSpan}, [])
  StatementExpression expr -> do
    (expr', _) <- synthExpr expr
    pure (StatementExpression expr', [])
  StatementBreak BreakStatement {value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    recordExit HandleBreakTag valueType
    pure (StatementBreak BreakStatement {value = value', sourceSpan = sourceSpan}, [])
  StatementNext NextStatement {value, modifiers, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    modifiers' <- mapM walkModifier modifiers
    recordExit HandleNextTag valueType
    pure (StatementNext NextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}, [])
  StatementForBreak ForBreakStatement {value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    recordExit ForBreakTag valueType
    pure (StatementForBreak ForBreakStatement {value = value', sourceSpan = sourceSpan}, [])
  StatementForNext ForNextStatement {modifiers, sourceSpan} -> do
    modifiers' <- mapM walkModifier modifiers
    pure (StatementForNext ForNextStatement {modifiers = modifiers', sourceSpan = sourceSpan}, [])
  StatementAgent agentStatement -> walkLocalAgent agentStatement
  StatementError span_ -> pure (StatementError span_, [])

walkModifier :: Modifier Identified -> Check (Modifier Zonked)
walkModifier Modifier {name, value, sourceSpan} = do
  semantic <- lookupVariableType sourceSpan name.text name.resolution
  value' <- checkExpr value semantic
  pure Modifier {name = retagNameRef name, value = value', sourceSpan = sourceSpan}

-- | A @let@ / state-var initializer: check against the annotation if present,
-- else synthesise. Returns the variable's binding.
walkInitializer ::
  NameRef Identified VariableRef ->
  Maybe (SyntacticType Identified) ->
  Expression Identified ->
  Check (Expression Zonked, [(VariableResolution, SemanticType Resolved)])
walkInitializer name typeAnnotation initial = do
  (initial', bindingType) <- case typeAnnotation of
    Just t -> do
      annotated <- elaborateType t
      initial' <- checkExpr initial annotated
      pure (initial', annotated)
    Nothing -> synthExpr initial
  let bindings = maybe [] (\resolution -> [(resolution, bindingType)]) name.resolution
  pure (initial', bindings)

-- | A nested @agent@ statement. Elaborate its signature, bind its parameters,
-- check its body, and bind the agent's own name to its function type for the
-- rest of the scope. Effects are computed by the SCC effect pass (not here).
walkLocalAgent :: AgentStatement Identified -> Check (Statement Zonked, [(VariableResolution, SemanticType Resolved)])
walkLocalAgent AgentStatement {annotation, name, parameters, returnType, withRequests, body, sourceSpan} = do
  (parameters', paramSig, paramLocals) <- elaborateParameters parameters
  declaredReturn <- traverse elaborateType returnType
  -- Recursive local agents need their return annotation; bind the signature up
  -- front when one is present so recursive calls resolve.
  let selfBinding ret = maybe [] (\resolution -> [(resolution, SemanticTypeFunction paramSig ret emptyRequest)]) name.resolution
  (body', bodyType) <-
    withLocals (paramLocals ++ maybe [] selfBinding declaredReturn) $
      case declaredReturn of
        Just ret -> withExpectedReturn ret (walkBlock body)
        Nothing -> walkBlock body
  let returnSemantic = maybe bodyType id declaredReturn
      functionType = SemanticTypeFunction paramSig returnSemantic emptyRequest
      bindings = maybe [] (\resolution -> [(resolution, functionType)]) name.resolution
  pure
    ( StatementAgent
        AgentStatement
          { annotation = annotation,
            name = retagNameRef name,
            parameters = parameters',
            returnType = fmap retagSyntacticType returnType,
            withRequests = fmap (fmap retagSyntacticRequest) withRequests,
            body = body',
            sourceSpan = sourceSpan
          },
      bindings
    )

-- | Elaborate a parameter list into zonked params, the function-signature
-- parameter map, and the env bindings for the parameters.
elaborateParameters ::
  [ParameterBinding Identified] ->
  Check ([ParameterBinding Zonked], Map Text (Parameter Resolved), [(VariableResolution, SemanticType Resolved)])
elaborateParameters parameters = do
  walked <- mapM walkOne parameters
  pure
    ( map (\(p, _, _) -> p) walked,
      Map.fromList [entry | (_, entry, _) <- walked],
      mapMaybe (\(_, _, binding) -> binding) walked
    )
  where
    walkOne ParameterBinding {annotation, name, typeAnnotation, defaultValue, sourceSpan} = do
      paramType <- maybe (pure SemanticTypeUnknown) elaborateType typeAnnotation
      case defaultValue of
        Just paramDefault -> subtypeAssert sourceSpan (literalValueToSemantic paramDefault.value) paramType
        Nothing -> pure ()
      let parameter = Parameter {parameterType = paramType, optional = case defaultValue of Just _ -> True; Nothing -> False}
          rebuilt =
            ParameterBinding
              { annotation = annotation,
                name = retagNameRef name,
                typeAnnotation = fmap retagSyntacticType typeAnnotation,
                defaultValue = defaultValue,
                sourceSpan = sourceSpan
              }
          binding = fmap (\resolution -> (resolution, paramType)) name.resolution
      pure (rebuilt, (name.text, parameter), binding)

-- ---------------------------------------------------------------------------
-- Patterns (projection over a known subject type)
-- ---------------------------------------------------------------------------

-- | Walk a pattern against a known subject type, returning the zonked pattern
-- and the variable bindings it introduces. The subject type is concrete (it
-- was synthesised), so projection is a direct structural read.
walkPattern :: SemanticType Resolved -> Pattern Identified -> Check (Pattern Zonked, [(VariableResolution, SemanticType Resolved)])
walkPattern subject = \case
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan} -> do
    bindingType <- case typeAnnotation of
      Just t -> elaborateType t
      Nothing -> pure subject
    let bindings = maybe [] (\resolution -> [(resolution, bindingType)]) name.resolution
    pure (PatternVariable VariablePattern {name = retagNameRef name, typeAnnotation = fmap retagSyntacticType typeAnnotation, sourceSpan = sourceSpan, typeOf = bindingType}, bindings)
  PatternWildcard WildcardPattern {typeAnnotation, sourceSpan} -> do
    patternType <- maybe (pure subject) elaborateType typeAnnotation
    pure (PatternWildcard WildcardPattern {typeAnnotation = fmap retagSyntacticType typeAnnotation, sourceSpan = sourceSpan, typeOf = patternType}, [])
  PatternLiteral LiteralPattern {value, sourceSpan} ->
    pure (PatternLiteral LiteralPattern {value = value, sourceSpan = sourceSpan, typeOf = literalValueToSemantic value}, [])
  PatternTuple TuplePattern {elements, sourceSpan} -> do
    let componentTypes = projectTupleComponents (length elements) subject
    walked <- mapM (\(componentType, element) -> walkPattern componentType element) (zip componentTypes elements)
    let patternType = SemanticTypeTuple (map (patternTypeOf . fst) walked)
    pure (PatternTuple TuplePattern {elements = map fst walked, sourceSpan = sourceSpan, typeOf = patternType}, concatMap snd walked)
  PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier, constructorName, parameters, sourceSpan} -> do
    fieldSubjects <- constructorFieldTypes constructorName.resolution
    walked <-
      forM parameters $ \(label, sub) -> do
        let fieldSubject = Map.findWithDefault SemanticTypeUnknown label.text fieldSubjects
        (sub', bindings) <- walkPattern fieldSubject sub
        pure ((retagNameRef label, sub'), bindings)
    let patternType = maybe SemanticTypeUnknown SemanticTypeData constructorName.resolution
    pure
      ( PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier = fmap retagNameRef moduleQualifier, constructorName = retagNameRef constructorName, parameters = map fst walked, sourceSpan = sourceSpan, typeOf = patternType},
        concatMap snd walked
      )
  PatternType TypePattern {typeTag, inner, sourceSpan} -> do
    let narrowedType = typePatternTagToSemantic typeTag
    (inner', bindings) <- walkPattern narrowedType inner
    pure (PatternType TypePattern {typeTag = typeTag, inner = inner', sourceSpan = sourceSpan, typeOf = narrowedType}, bindings)
  PatternRecord RecordPattern {entries, sourceSpan} -> do
    walked <-
      forM entries $ \(entryLabel, entryPattern) -> do
        valueSubject <- fieldType sourceSpan subject entryLabel
        (entryPattern', bindings) <- walkPattern valueSubject entryPattern
        pure ((entryLabel, entryPattern'), bindings)
    pure (PatternRecord RecordPattern {entries = map fst walked, sourceSpan = sourceSpan, typeOf = subject}, concatMap snd walked)

patternTypeOf :: Pattern Zonked -> SemanticType Resolved
patternTypeOf = \case
  PatternVariable p -> p.typeOf
  PatternWildcard p -> p.typeOf
  PatternLiteral p -> p.typeOf
  PatternTuple p -> p.typeOf
  PatternQualifiedConstructor p -> p.typeOf
  PatternType p -> p.typeOf
  PatternRecord p -> p.typeOf

typePatternTagToSemantic :: TypePatternTag -> SemanticType Resolved
typePatternTagToSemantic = \case
  TypePatternTagInteger -> SemanticTypeInteger
  TypePatternTagNumber -> SemanticTypeNumber
  TypePatternTagString -> SemanticTypeString
  TypePatternTagBoolean -> SemanticTypeBoolean
  TypePatternTagAgent -> SemanticTypeFunctionAny

-- | The declared field types of a data constructor (its signature's
-- parameters), keyed by field label.
constructorFieldTypes :: Maybe QualifiedName -> Check (Map Text (SemanticType Resolved))
constructorFieldTypes = \case
  Just qualifiedName ->
    lookupLocal (ResolvedTopLevel qualifiedName) >>= \case
      Just (SemanticTypeFunction params _ _) -> pure (Map.map (.parameterType) params)
      _ -> pure Map.empty
  Nothing -> pure Map.empty

-- ---------------------------------------------------------------------------
-- Type projections over concrete subject types
-- ---------------------------------------------------------------------------

-- | The component subject types for a tuple pattern of the given arity.
-- Minimum-elements: positions past those the static type names are @unknown@.
projectTupleComponents :: Int -> SemanticType Resolved -> [SemanticType Resolved]
projectTupleComponents arity = \case
  SemanticTypeTuple ts -> take arity (ts ++ repeat SemanticTypeUnknown)
  SemanticTypeArray e -> replicate arity e
  SemanticTypeUnion branches ->
    case [projectTupleComponents arity b | b <- branches] of
      [] -> replicate arity SemanticTypeUnknown
      projections -> map unionSemantic (transpose projections)
  _ -> replicate arity SemanticTypeUnknown

-- | The element type of a sequence (array / tuple) subject.
seqElementType :: SemanticType Resolved -> SemanticType Resolved
seqElementType = \case
  SemanticTypeArray e -> e
  SemanticTypeTuple ts -> unionSemantic ts
  SemanticTypeUnion branches -> unionSemantic (map seqElementType branches)
  _ -> SemanticTypeUnknown

-- | The type of field @label@ read from a map-layer (object / data / record)
-- subject. A missing field on an object / data is a hard error.
fieldType :: SourceSpan -> SemanticType Resolved -> Text -> Check (SemanticType Resolved)
fieldType sourceSpan subject label = case subject of
  SemanticTypeObject fields -> case Map.lookup label fields of
    Just t -> pure t
    Nothing -> missing
  SemanticTypeRecord valueType -> pure valueType
  SemanticTypeData qualifiedName ->
    constructorFieldTypes (Just qualifiedName) >>= \fields ->
      case Map.lookup label fields of
        Just t -> pure t
        Nothing -> missing
  SemanticTypeUnion branches -> unionSemantic <$> mapM (\b -> fieldType sourceSpan b label) branches
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  _ -> missing
  where
    missing = emitError (CheckErrorUnsupported sourceSpan ("no field '" <> label <> "' on the accessed value")) >> pure SemanticTypeUnknown

-- ===========================================================================
-- Module entry point
-- ===========================================================================

-- | Everything the checker needs for one module. Mirrors the constraint
-- pipeline's 'TypecheckSubject'.
data CheckSubject = CheckSubject
  { csModuleName :: Text,
    csModuleAST :: Module Identified,
    csTypeData :: Map QualifiedName TypeData,
    csKnownRequests :: Set QualifiedName,
    csPrimRules :: Map QualifiedName PrimRule,
    csImportedTypes :: Map QualifiedName (SemanticType Resolved)
  }

-- | Type-check a module bidirectionally, returning every diagnostic. (Module
-- @Zonked@ assembly + the effect SCC fixpoint land when the checker is wired
-- into 'Katari.Typechecker'; this entry validates the type-checking core.)
checkModule :: CheckSubject -> [Diagnostic]
checkModule subject =
  let elaborationEnv =
        CheckEnv
          { checkTypeData = subject.csTypeData,
            checkDataFieldEnv = mempty,
            checkSynonymVisited = Set.empty,
            checkLocals = Map.empty,
            checkPrimRules = subject.csPrimRules,
            checkExpectedReturn = Nothing
          }
      (nonAgentSignatures, signatureErrors) =
        runCheck elaborationEnv (computeNonAgentSignatures subject.csModuleAST.declarations)
      resolvedCallables = Map.union subject.csImportedTypes nonAgentSignatures
      fullEnv =
        elaborationEnv
          { checkDataFieldEnv = buildDataFieldEnv resolvedCallables,
            checkLocals = Map.mapKeys ResolvedTopLevel resolvedCallables
          }
      (_, bodyErrors) = runCheck fullEnv (processAgentSCCs subject)
   in map toDiagnostic (signatureErrors ++ bodyErrors)

-- | Signatures of the non-agent callables (data ctors, requests, externals,
-- prims) — all derivable from annotations alone (no body to check).
computeNonAgentSignatures :: [Declaration Identified] -> Check (Map QualifiedName (SemanticType Resolved))
computeNonAgentSignatures declarations =
  Map.fromList . concat <$> mapM one declarations
  where
    bind nameRef sig = pure (maybe [] (\qualifiedName -> [(qualifiedName, sig)]) (topLevelQName nameRef))
    one = \case
      DeclarationData DataDeclaration {name, typeName, parameters} -> do
        fields <- mapM (\DataParameter {name = fieldName, parameterType} -> (fieldName,) <$> elaborateType parameterType) parameters
        let returnType = maybe SemanticTypeUnknown SemanticTypeData typeName.resolution
        bind name (SemanticTypeFunction (requiredParameter <$> Map.fromList fields) returnType emptyRequest)
      DeclarationRequest RequestDeclaration {name, requestName, parameters, returnType} -> do
        (_, paramSig, _) <- elaborateParameters parameters
        ret <- elaborateType returnType
        let effect = case requestName.resolution of
              Just qualifiedName | not (isThrow qualifiedName) -> SemanticRequest (Set.singleton (SemanticRequestElementConcrete qualifiedName))
              _ -> emptyRequest
        bind name (SemanticTypeFunction paramSig ret effect)
      DeclarationExternalAgent ExternalAgentDeclaration {name, parameters, returnType, withRequests} -> do
        (_, paramSig, _) <- elaborateParameters parameters
        ret <- elaborateType returnType
        effect <- elaborateRequestList withRequests
        bind name (SemanticTypeFunction paramSig ret effect)
      DeclarationPrimAgent PrimAgentDeclaration {name, parameters, returnType, withRequests} -> do
        (_, paramSig, _) <- elaborateParameters parameters
        ret <- elaborateType returnType
        effect <- elaborateRequestList withRequests
        bind name (SemanticTypeFunction paramSig ret effect)
      _ -> pure []
    isThrow qualifiedName = qualifiedName.module_ == "primitive" && qualifiedName.name == "throw"

-- | Process the agent SCCs in topological order, extending the environment
-- with each SCC's finalised signatures before the next.
processAgentSCCs :: CheckSubject -> Check ()
processAgentSCCs subject = go (agentSCCs subject.csModuleName subject.csModuleAST)
  where
    declMap = Map.fromList (mapMaybe agentEntry subject.csModuleAST.declarations)
    agentEntry = \case
      DeclarationAgent decl -> (\qualifiedName -> (qualifiedName, decl)) <$> topLevelQName decl.name
      _ -> Nothing
    go [] = pure ()
    go (scc : rest) = do
      bindings <- processAgentSCC declMap scc
      withLocals bindings (go rest)

-- | Type-check one SCC of mutually-recursive agents. A multi-member (hence
-- recursive) SCC requires every member to annotate its return type, which
-- breaks the recursion for checking; a non-recursive singleton infers its
-- return from the body.
processAgentSCC ::
  Map QualifiedName (AgentDeclaration Identified) ->
  Set QualifiedName ->
  Check [(VariableResolution, SemanticType Resolved)]
processAgentSCC declMap scc = do
  let members = mapMaybe (`Map.lookup` declMap) (Set.toList scc)
      recursive = Set.size scc > 1
  if recursive
    then do
      seeds <- mapM seedRecursiveSignature members
      let bindings = [(ResolvedTopLevel qualifiedName, sig) | (qualifiedName, sig) <- concat seeds]
      withLocals bindings $ mapM_ checkAgentBodyAgainstReturn members
      pure bindings
    else case members of
      [decl] -> do
        sig <- checkAgentBodyInferring decl
        pure (maybe [] (\resolution -> [(resolution, sig)]) decl.name.resolution)
      _ -> pure []

-- | A recursive agent's seeded signature, from its (mandatory) return
-- annotation. A missing annotation is the recursive-return diagnostic.
seedRecursiveSignature :: AgentDeclaration Identified -> Check [(QualifiedName, SemanticType Resolved)]
seedRecursiveSignature AgentDeclaration {name, parameters, returnType, sourceSpan} = do
  (_, paramSig, _) <- elaborateParameters parameters
  ret <- case returnType of
    Just t -> elaborateType t
    Nothing -> do
      emitError (CheckErrorUnsupported sourceSpan "a recursive agent needs an explicit return type — it can't be inferred through the recursion")
      pure SemanticTypeUnknown
  pure (maybe [] (\qualifiedName -> [(qualifiedName, SemanticTypeFunction paramSig ret emptyRequest)]) (topLevelQName name))

-- | Check a recursive agent's body against its (already-seeded) declared
-- return type.
checkAgentBodyAgainstReturn :: AgentDeclaration Identified -> Check ()
checkAgentBodyAgainstReturn AgentDeclaration {parameters, returnType, body} = do
  (_, _, paramLocals) <- elaborateParameters parameters
  ret <- maybe (pure SemanticTypeUnknown) elaborateType returnType
  withLocals paramLocals . withExpectedReturn ret $ do
    (_, bodyType) <- walkBlock body
    subtypeAssert (sourceSpanOf body) bodyType ret

-- | Check a non-recursive agent's body, inferring its return type when no
-- annotation is present. Returns the finalised signature.
checkAgentBodyInferring :: AgentDeclaration Identified -> Check (SemanticType Resolved)
checkAgentBodyInferring AgentDeclaration {parameters, returnType, body} = do
  (_, paramSig, paramLocals) <- elaborateParameters parameters
  declaredReturn <- traverse elaborateType returnType
  bodyType <-
    withLocals paramLocals $ case declaredReturn of
      Just ret -> withExpectedReturn ret $ do
        (_, bodyType) <- walkBlock body
        subtypeAssert (sourceSpanOf body) bodyType ret
        pure ret
      Nothing -> snd <$> walkBlock body
  pure (SemanticTypeFunction paramSig bodyType emptyRequest)

topLevelQName :: NameRef Identified VariableRef -> Maybe QualifiedName
topLevelQName nameRef = case nameRef.resolution of
  Just (ResolvedTopLevel qualifiedName) -> Just qualifiedName
  _ -> Nothing
