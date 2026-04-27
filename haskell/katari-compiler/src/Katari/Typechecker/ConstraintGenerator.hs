-- | Typechecker phase 2: Constraint generation.
--
-- Walks the @Identified@ AST, attaches an 'SemanticType' 'Unresolved' to every
-- expression and pattern, and emits a list of subtype constraints (over
-- types and effects) for the solver. The output AST is parameterised by the
-- 'Constrained' phase marker.
--
-- Design notes (see also: doc/spec and the ConstraintGenerator plan):
--
--   * Constraints are subtype-only, with a 'ConstraintReason' attached for
--     diagnostics. Equality constraints (e.g. for definition signatures) are
--     desugared into two subtype constraints in opposite directions.
--   * Definitions ('agent' / 'req' / 'ext-agent' / 'data' constructor) emit
--     equality constraints between the type variable allocated for the
--     declared name and the function signature derived from its declaration.
--     Request handlers, by contrast, emit subtype constraints (handlers are
--     conceptually re-assignments of the underlying request).
--   * Effect inference uses the same context-passing trick as @return@ and
--     @break@: each scope (agent body / req handler / @where@ block body)
--     allocates a fresh 'EffectVarId'. Function-call subtyping cascades
--     callee effects into the enclosing effect variable.
--   * @where@ blocks /discharge/ the requests they handle: the inner block's
--     effect set is constrained to be a subset of @outer ∪ handled-reqs@.
--   * 'CG' never traverses the AST a second time to "collect" structural
--     information. Anything CG needs that isn't immediately visible at a
--     node lives in 'IdentifierResult' and is read locally.
module Katari.Typechecker.ConstraintGenerator
  ( -- * Phase marker
    Constrained (..),

    -- * Constraint and reason
    Constraint (..),
    ConstraintReason (..),
    ConstraintError (..),

    -- * Result
    ConstraintGenResult (..),
    TypeEnvironment,

    -- * Entry point
    generateConstraints,
  )
where

import Control.Monad (foldM, void, when)
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Control.Monad.Trans (lift)
import Data.Foldable (foldl')
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
import Katari.Typechecker.Identifier
  ( Identified (..),
    IdentifierResult (..),
    ModuleId,
    TypeData (..),
    TypeId,
    VariableId,
  )
import Katari.Typechecker.SemanticType

-- ===========================================================================
-- Constrained phase metadata
-- ===========================================================================

-- | Phase marker for the AST after constraint generation. Carries the
-- inferred (yet-unresolved) 'SemanticType' on each expression and pattern;
-- variable / type / module references inherit their @Identified@ ids
-- unchanged.
data Constrained (s :: SymbolKind) where
  ConstrainedVariable           :: VariableId -> Constrained 'VariableRef
  ConstrainedUnresolvedVariable :: Constrained 'VariableRef
  ConstrainedType               :: TypeId -> Constrained 'TypeRef
  ConstrainedUnresolvedType     :: Constrained 'TypeRef
  ConstrainedModule             :: ModuleId -> Constrained 'ModuleRef
  ConstrainedUnresolvedModule   :: Constrained 'ModuleRef
  ConstrainedExpression         :: SemanticType Unresolved -> Constrained 'Expression
  ConstrainedPattern            :: SemanticType Unresolved -> Constrained 'Pattern
  -- | Labels are still resolved later (post-solving). The constraint
  -- generation phase keeps them trivial.
  ConstrainedLabel              :: Constrained 'LabelRef

deriving instance Show (Constrained s)

deriving instance Eq (Constrained s)

-- ===========================================================================
-- Constraint and reason
-- ===========================================================================

-- | A single subtyping constraint, either between two semantic types or
-- between two effect sets. Equality is encoded as two subtype constraints in
-- opposite directions.
data Constraint
  = TypeConstraint
      { typeLhs :: !(SemanticType Unresolved),
        typeRhs :: !(SemanticType Unresolved),
        reason :: !ConstraintReason
      }
  | EffectConstraint
      { effectLhs :: !(SemanticEffect Unresolved),
        effectRhs :: !(SemanticEffect Unresolved),
        reason :: !ConstraintReason
      }
  deriving (Eq, Show)

-- | Where the constraint came from. Drives diagnostics; callers should pick
-- the most specific reason that applies. Each reason carries the source span
-- of the syntactic site that triggered it.
data ConstraintReason
  = ReasonAgentSignature SourceSpan
  | ReasonRequestSignature SourceSpan
  | ReasonExternalAgentSignature SourceSpan
  | ReasonDataConstructorSignature SourceSpan
  | ReasonRequestHandlerSignature SourceSpan
  | ReasonReturnTypeAnnotation SourceSpan
  | ReasonReturnStatement SourceSpan
  | ReasonEffectBound SourceSpan
  | ReasonHandleEffectDischarge SourceSpan
  | ReasonHandleNext SourceSpan
  | ReasonHandleBreak SourceSpan
  | ReasonForBreak SourceSpan
  | ReasonForBody SourceSpan
  | ReasonForIn SourceSpan
  | ReasonModifierUpdate SourceSpan
  | ReasonLetPattern SourceSpan
  | ReasonStateVarAnnotation SourceSpan
  | ReasonVariablePatternAnnotation SourceSpan
  | ReasonCallArgument SourceSpan
  | ReasonBinaryOperator SourceSpan
  | ReasonUnaryOperator SourceSpan
  | ReasonIfCondition SourceSpan
  | ReasonIfBranch SourceSpan
  | ReasonMatchSubject SourceSpan
  | ReasonMatchArm SourceSpan
  | ReasonFieldAccess SourceSpan
  | ReasonIndexAccessArray SourceSpan
  | ReasonIndexAccessIndex SourceSpan
  | ReasonTemplateInterpolation SourceSpan
  | ReasonArrayElement SourceSpan
  | ReasonConstructorPattern SourceSpan
  deriving (Eq, Show)

-- | Errors emitted by the constraint generator itself (separate from solver
-- errors). Currently the only failure mode is a cyclic type synonym.
data ConstraintError
  = ErrorTypeSynonymCycle SourceSpan TypeId
  deriving (Eq, Show)

-- ===========================================================================
-- Result
-- ===========================================================================

-- | Type environment: maps each 'VariableId' (allocated by the Identifier
-- pass) to the 'SemanticType' Unresolved that the constraint generator
-- assigned to it.
type TypeEnvironment = Map VariableId (SemanticType Unresolved)

data ConstraintGenResult = ConstraintGenResult
  { constrainedModules :: !(Map ModuleId (Module Constrained)),
    typeEnvironment :: !TypeEnvironment,
    constraints :: ![Constraint],
    nextTypeVarId :: !Int,
    nextEffectVarId :: !Int,
    errors :: ![ConstraintError]
  }
  deriving (Show)

-- ===========================================================================
-- Monad
-- ===========================================================================

data ConstraintState = ConstraintState
  { stateNextTypeVarId :: !Int,
    stateNextEffectVarId :: !Int,
    stateTypeEnvironment :: !TypeEnvironment,
    stateConstraints :: ![Constraint],
    stateErrors :: ![ConstraintError]
  }

data ConstraintContext = ConstraintContext
  { contextIdentifiedTypes :: !(Map TypeId TypeData),
    contextSynonymVisited :: !(Set TypeId),
    contextEnclosingReturn :: !(Maybe TypeVarId),
    contextEnclosingEffects :: !(Maybe EffectVarId),
    contextEnclosingForBreak :: !(Maybe TypeVarId),
    contextEnclosingForBody :: !(Maybe TypeVarId),
    contextEnclosingHandleResult :: !(Maybe TypeVarId),
    contextEnclosingHandleNext :: !(Map VariableId TypeVarId)
  }

type CG = ReaderT ConstraintContext (State ConstraintState)

initialState :: ConstraintState
initialState =
  ConstraintState
    { stateNextTypeVarId = 0,
      stateNextEffectVarId = 0,
      stateTypeEnvironment = Map.empty,
      stateConstraints = [],
      stateErrors = []
    }

initialContext :: Map TypeId TypeData -> ConstraintContext
initialContext types =
  ConstraintContext
    { contextIdentifiedTypes = types,
      contextSynonymVisited = Set.empty,
      contextEnclosingReturn = Nothing,
      contextEnclosingEffects = Nothing,
      contextEnclosingForBreak = Nothing,
      contextEnclosingForBody = Nothing,
      contextEnclosingHandleResult = Nothing,
      contextEnclosingHandleNext = Map.empty
    }

-- ---------------------------------------------------------------------------
-- Helpers: fresh ids, env, constraint emission
-- ---------------------------------------------------------------------------

freshTypeVarId :: CG TypeVarId
freshTypeVarId = lift $ do
  current <- gets (.stateNextTypeVarId)
  modify $ \s -> s {stateNextTypeVarId = current + 1}
  pure (TypeVarId current)

freshTypeVar :: CG (SemanticType Unresolved)
freshTypeVar = SemanticTypeVariable <$> freshTypeVarId

freshEffectVarId :: CG EffectVarId
freshEffectVarId = lift $ do
  current <- gets (.stateNextEffectVarId)
  modify $ \s -> s {stateNextEffectVarId = current + 1}
  pure (EffectVarId current)

bindVariable :: VariableId -> SemanticType Unresolved -> CG ()
bindVariable variableId semanticType = lift . modify $ \s ->
  s {stateTypeEnvironment = Map.insert variableId semanticType s.stateTypeEnvironment}

-- | Look up a 'VariableId' in the type environment. Phase A binds every
-- VariableId in 'IdentifierResult.identifiedVariables', so this should
-- always hit. Defensive fallback: allocate a fresh type var and bind it.
lookupVariable :: VariableId -> CG (SemanticType Unresolved)
lookupVariable variableId = do
  existing <- lift $ gets (Map.lookup variableId . (.stateTypeEnvironment))
  case existing of
    Just t -> pure t
    Nothing -> do
      fresh <- freshTypeVar
      bindVariable variableId fresh
      pure fresh

addTypeConstraint
  :: SemanticType Unresolved
  -> SemanticType Unresolved
  -> ConstraintReason
  -> CG ()
addTypeConstraint lhs rhs r = lift . modify $ \s ->
  s {stateConstraints = TypeConstraint lhs rhs r : s.stateConstraints}

-- | Equality is two subtype constraints in opposite directions.
addEqTypeConstraint
  :: SemanticType Unresolved
  -> SemanticType Unresolved
  -> ConstraintReason
  -> CG ()
addEqTypeConstraint lhs rhs r = do
  addTypeConstraint lhs rhs r
  addTypeConstraint rhs lhs r

addEffectConstraint
  :: SemanticEffect Unresolved
  -> SemanticEffect Unresolved
  -> ConstraintReason
  -> CG ()
addEffectConstraint lhs rhs r = lift . modify $ \s ->
  s {stateConstraints = EffectConstraint lhs rhs r : s.stateConstraints}

emitError :: ConstraintError -> CG ()
emitError err = lift . modify $ \s -> s {stateErrors = err : s.stateErrors}

-- ---------------------------------------------------------------------------
-- Reader updates (scope context)
-- ---------------------------------------------------------------------------

withReturn :: TypeVarId -> CG a -> CG a
withReturn tv = local $ \c -> c {contextEnclosingReturn = Just tv}

withEnclosingEffects :: EffectVarId -> CG a -> CG a
withEnclosingEffects ev = local $ \c -> c {contextEnclosingEffects = Just ev}

withForLoop :: TypeVarId -> TypeVarId -> CG a -> CG a
withForLoop breakTv bodyTv = local $ \c ->
  c {contextEnclosingForBreak = Just breakTv, contextEnclosingForBody = Just bodyTv}

withHandleScope :: TypeVarId -> Map VariableId TypeVarId -> CG a -> CG a
withHandleScope resultTv nexts = local $ \c ->
  c {contextEnclosingHandleResult = Just resultTv, contextEnclosingHandleNext = nexts}

withSynonymVisit :: TypeId -> CG a -> CG a
withSynonymVisit tid = local $ \c ->
  c {contextSynonymVisited = Set.insert tid c.contextSynonymVisited}

-- ===========================================================================
-- Type elaboration (SyntacticType Identified -> SemanticType Unresolved)
-- ===========================================================================

-- | Elaborate a syntactic type expression into a semantic type, expanding
-- type synonyms transparently. Cycles in synonym definitions are detected
-- via a visited set in the reader context.
elaborateType :: SyntacticType Identified -> CG (SemanticType Unresolved)
elaborateType = \case
  TypePrimitive PrimitiveTypeNode {kind} -> pure (primitiveToSemantic kind)
  TypeName TypeNameNode {name} -> resolveTypeRef name
  TypeQualified QualifiedTypeNode {target} -> resolveTypeRef target
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withEffects} -> do
    parameters <- mapM (\(label, pt) -> (,) label <$> elaborateType pt) parameterTypes
    returnSemantic <- elaborateType returnType
    effects <- elaborateRequestList withEffects
    pure (SemanticTypeFunction parameters returnSemantic effects)
  TypeArray ArrayTypeNode {elementType} ->
    SemanticTypeArray <$> elaborateType elementType
  TypeTuple TupleTypeNode {elementTypes} ->
    SemanticTypeTuple <$> mapM elaborateType elementTypes
  TypeUnion TypeUnionNode {branches} ->
    SemanticTypeUnion <$> mapM elaborateType branches
  TypeLiteral TypeLiteralNode {value} -> pure (literalValueToSemantic value)
  TypeNever _ -> pure SemanticTypeNever
  TypeUnknown _ -> pure SemanticTypeUnknown

-- | Map a 'PrimitiveTypeKind' to the matching 'SemanticType' constructor.
primitiveToSemantic :: PrimitiveTypeKind -> SemanticType phase
primitiveToSemantic = \case
  PrimitiveTypeKindNull -> SemanticTypeNull
  PrimitiveTypeKindInteger -> SemanticTypeInteger
  PrimitiveTypeKindNumber -> SemanticTypeNumber
  PrimitiveTypeKindString -> SemanticTypeString
  PrimitiveTypeKindBoolean -> SemanticTypeBoolean

-- | Map a 'LiteralValue' (used for both syntactic literal types and
-- expression literals) to the corresponding 'SemanticType'. Float literals
-- become the broader @SemanticTypeNumber@ — there is no float-literal type.
literalValueToSemantic :: LiteralValue -> SemanticType phase
literalValueToSemantic = \case
  LiteralValueNull -> SemanticTypeNull
  LiteralValueInteger n -> SemanticTypeLiteralInteger n
  LiteralValueNumber _ -> SemanticTypeNumber
  LiteralValueString s -> SemanticTypeLiteralString s
  LiteralValueBoolean b -> SemanticTypeLiteralBoolean b

-- | Resolve a 'TypeRef' name to its semantic counterpart, expanding
-- synonyms on the fly with cycle detection.
resolveTypeRef :: NameRef Identified 'TypeRef -> CG (SemanticType Unresolved)
resolveTypeRef nameRef = case nameRef.metadata of
  IdentifiedType tid -> do
    types <- asks (.contextIdentifiedTypes)
    case Map.lookup tid types of
      Just TypeData {typeSynonymRhs = Just rhs} -> do
        visited <- asks (.contextSynonymVisited)
        if Set.member tid visited
          then do
            emitError (ErrorTypeSynonymCycle nameRef.sourceSpan tid)
            freshTypeVar
          else withSynonymVisit tid (elaborateType rhs)
      Just TypeData {typeSynonymRhs = Nothing} ->
        pure (SemanticTypeData tid)
      Nothing ->
        -- Identifier should have populated all entries; fall back defensively.
        freshTypeVar
  IdentifiedUnresolvedType -> freshTypeVar

-- | Elaborate a list of @with@-clause request references into a single
-- effect set (concrete VariableIds; effect type variables come into play
-- only for inference, not for explicit annotations).
elaborateRequestList :: [SyntacticRequest Identified] -> CG (SemanticEffect Unresolved)
elaborateRequestList requests =
  pure $
    SemanticEffect
      { effectVars = Set.empty,
        effectReqs = Set.fromList (concatMap requestVarId requests)
      }
  where
    requestVarId SyntacticRequest {name} = case name.metadata of
      IdentifiedVariable vid -> [vid]
      IdentifiedUnresolvedVariable -> []

-- | Optional @with@ clause — present only on agent / req-handler type-context
-- declarations. @Nothing@ means "no annotation"; the caller decides whether
-- to allocate a fresh effect variable in that case.
elaborateOptionalEffects :: Maybe [SyntacticRequest Identified] -> CG (Maybe (SemanticEffect Unresolved))
elaborateOptionalEffects = traverse elaborateRequestList

-- ===========================================================================
-- Phase A: allocate type vars for every VariableId
-- ===========================================================================

-- | Walk @identifiedVariables@ once and bind each id to a fresh type
-- variable. Done before any constraint generation so forward references and
-- mutual recursion just work.
allocateAllVariables :: IdentifierResult -> CG ()
allocateAllVariables result = mapM_ allocate (Map.keys result.identifiedVariables)
  where
    allocate vid = do
      tv <- freshTypeVar
      bindVariable vid tv

-- ===========================================================================
-- Phase B: walk modules, declarations, statements, expressions, patterns
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Module / declaration
-- ---------------------------------------------------------------------------

walkModule :: Module Identified -> CG (Module Constrained)
walkModule Module {declarations, sourceSpan} = do
  declarations' <- mapM walkDeclaration declarations
  pure Module {declarations = declarations', sourceSpan = sourceSpan}

walkDeclaration :: Declaration Identified -> CG (Declaration Constrained)
walkDeclaration = \case
  DeclarationAgent decl -> DeclarationAgent <$> walkAgentDecl decl
  DeclarationRequest decl -> DeclarationRequest <$> walkRequestDecl decl
  DeclarationExternalAgent decl -> DeclarationExternalAgent <$> walkExternalAgentDecl decl
  DeclarationData decl -> DeclarationData <$> walkDataDecl decl
  DeclarationTypeSynonym decl -> DeclarationTypeSynonym <$> walkTypeSynonymDecl decl
  DeclarationImport decl -> pure (DeclarationImport (passThroughImport decl))
  DeclarationError span_ -> pure (DeclarationError span_)

passThroughImport :: ImportDeclaration Identified -> ImportDeclaration Constrained
passThroughImport ImportDeclaration {kind, sourceSpan} =
  ImportDeclaration {kind = kind, sourceSpan = sourceSpan}

-- ---------------------------------------------------------------------------
-- Agent declaration
-- ---------------------------------------------------------------------------

walkAgentDecl :: AgentDeclaration Identified -> CG (AgentDeclaration Constrained)
walkAgentDecl AgentDeclaration {annotation, name, parameters, returnType, withEffects, body, sourceSpan} = do
  tFoo <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateOrFresh returnType
  effDeclared <- maybe (effectFromVar <$> freshEffectVarId) pure =<< elaborateOptionalEffects withEffects
  bodyEffectVarId <- freshEffectVarId
  retTvId <- freshReturnTypeVar retSemantic
  body' <-
    withReturn retTvId . withEnclosingEffects bodyEffectVarId $ walkBlock body
  let bodyType = blockType body'
  -- body の return / 末尾値は ret_t に流す
  addTypeConstraint bodyType (SemanticTypeVariable retTvId) (ReasonReturnStatement sourceSpan)
  -- ret_t と annotated return 型 (annotation か fresh var) は eq
  addEqTypeConstraint (SemanticTypeVariable retTvId) retSemantic (ReasonReturnTypeAnnotation sourceSpan)
  -- body の effect var は declared effect (annotation か fresh var) に bound
  addEffectConstraint
    (effectFromVar bodyEffectVarId)
    effDeclared
    (ReasonEffectBound sourceSpan)
  -- signature 全体と t_foo は eq
  let signature = SemanticTypeFunction paramSig retSemantic effDeclared
  addEqTypeConstraint signature tFoo (ReasonAgentSignature sourceSpan)
  pure
    AgentDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = fmap passThroughType returnType,
        withEffects = fmap (fmap passThroughRequest) withEffects,
        body = body',
        sourceSpan = sourceSpan
      }

walkRequestDecl :: RequestDeclaration Identified -> CG (RequestDeclaration Constrained)
walkRequestDecl RequestDeclaration {annotation, name, parameters, returnType, sourceSpan} = do
  tReq <- variableTypeFromName name
  reqVarId <- variableIdOfName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateType returnType
  let signature =
        SemanticTypeFunction
          paramSig
          retSemantic
          (maybe emptyEffect singletonEffect reqVarId)
  addEqTypeConstraint signature tReq (ReasonRequestSignature sourceSpan)
  pure
    RequestDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = passThroughType returnType,
        sourceSpan = sourceSpan
      }

walkExternalAgentDecl :: ExternalAgentDeclaration Identified -> CG (ExternalAgentDeclaration Constrained)
walkExternalAgentDecl ExternalAgentDeclaration {annotation, name, parameters, returnType, withEffects, sourceSpan} = do
  tExt <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateType returnType
  effects <- elaborateRequestList withEffects
  let signature = SemanticTypeFunction paramSig retSemantic effects
  addEqTypeConstraint signature tExt (ReasonExternalAgentSignature sourceSpan)
  pure
    ExternalAgentDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = passThroughType returnType,
        withEffects = fmap passThroughRequest withEffects,
        sourceSpan = sourceSpan
      }

walkDataDecl :: DataDeclaration Identified -> CG (DataDeclaration Constrained)
walkDataDecl DataDeclaration {annotation, name, parameters, sourceSpan} = do
  tCtor <- variableTypeFromName name
  -- data の TypeId は同名の type slot に登録されている。Identifier 出力経由で取得。
  tid <- typeIdForDataName name
  fields <- mapM elaborateDataParameter parameters
  let signature =
        SemanticTypeFunction
          fields
          (maybe SemanticTypeUnknown SemanticTypeData tid)
          emptyEffect
  addEqTypeConstraint signature tCtor (ReasonDataConstructorSignature sourceSpan)
  parameters' <- mapM walkDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        sourceSpan = sourceSpan
      }

walkTypeSynonymDecl :: TypeSynonymDeclaration Identified -> CG (TypeSynonymDeclaration Constrained)
walkTypeSynonymDecl TypeSynonymDeclaration {name, rhs, sourceSpan} =
  pure
    TypeSynonymDeclaration
      { name = passThroughTypeName name,
        rhs = passThroughType rhs,
        sourceSpan = sourceSpan
      }

elaborateDataParameter :: DataParameter Identified -> CG (Text, SemanticType Unresolved)
elaborateDataParameter DataParameter {name, parameterType} = do
  semantic <- elaborateType parameterType
  pure (name, semantic)

walkDataParameter :: DataParameter Identified -> CG (DataParameter Constrained)
walkDataParameter DataParameter {annotation, name, parameterType, sourceSpan} =
  pure
    DataParameter
      { annotation = annotation,
        name = name,
        parameterType = passThroughType parameterType,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Parameters / patterns
-- ---------------------------------------------------------------------------

-- | Walk a parameter list, returning the rebuilt 'ParameterBinding' list and
-- the @[(label, pattern type)]@ pairs that go into the function signature.
walkParameterListForSignature
  :: [ParameterBinding Identified]
  -> CG ([ParameterBinding Constrained], [(Text, SemanticType Unresolved)])
walkParameterListForSignature params = do
  let walkOne ParameterBinding {annotation, label, pattern, sourceSpan} = do
        (pattern', patternType) <- walkPattern pattern
        let rebuilt =
              ParameterBinding
                { annotation = annotation,
                  label = label,
                  pattern = pattern',
                  sourceSpan = sourceSpan
                }
        pure (rebuilt, (label, patternType))
  rebuilt <- mapM walkOne params
  pure (map fst rebuilt, map snd rebuilt)

-- | Walk a 'Pattern', returning the rebuilt Constrained pattern and its
-- inferred type (as a 'SemanticType' Unresolved). Variable bindings are
-- registered in the type environment as a side effect.
walkPattern :: Pattern Identified -> CG (Pattern Constrained, SemanticType Unresolved)
walkPattern = \case
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan} -> do
    tx <- variableTypeFromName name
    patternType <- case typeAnnotation of
      Just t -> do
        annotated <- elaborateType t
        addEqTypeConstraint tx annotated (ReasonVariablePatternAnnotation sourceSpan)
        pure annotated
      Nothing -> pure tx
    pure
      ( PatternVariable
          VariablePattern
            { name = passThroughVariableName name,
              typeAnnotation = fmap passThroughType typeAnnotation,
              sourceSpan = sourceSpan,
              metadata = ConstrainedPattern patternType
            },
        patternType
      )
  PatternWildcard WildcardPattern {typeAnnotation, sourceSpan} -> do
    patternType <- case typeAnnotation of
      Just t -> elaborateType t
      Nothing -> freshTypeVar
    pure
      ( PatternWildcard
          WildcardPattern
            { typeAnnotation = fmap passThroughType typeAnnotation,
              sourceSpan = sourceSpan,
              metadata = ConstrainedPattern patternType
            },
        patternType
      )
  PatternLiteral LiteralPattern {value, sourceSpan} -> do
    let patternType = literalValueToSemantic value
    pure
      ( PatternLiteral
          LiteralPattern
            { value = value,
              sourceSpan = sourceSpan,
              metadata = ConstrainedPattern patternType
            },
        patternType
      )
  PatternTuple TuplePattern {elements, sourceSpan} -> do
    pairs <- mapM walkPattern elements
    let patternType = SemanticTypeTuple (map snd pairs)
    pure
      ( PatternTuple
          TuplePattern
            { elements = map fst pairs,
              sourceSpan = sourceSpan,
              metadata = ConstrainedPattern patternType
            },
        patternType
      )
  PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier, constructorName, parameters, sourceSpan} -> do
    -- "reverse call": pretend the pattern constructs a value via the ctor,
    -- and constrain the synthesised function type to be a subtype of the
    -- ctor's known function type. Field-typed sub-patterns flow into place
    -- via the function-subtype rule (parameter-contravariant).
    tCtor <- variableTypeFromName constructorName
    paramPairs <- mapM walkPatternField parameters
    let argSig = map snd paramPairs
        parameters' = map fst paramPairs
    patternResult <- freshTypeVar
    let synthesised =
          SemanticTypeFunction argSig patternResult emptyEffect
    addTypeConstraint synthesised tCtor (ReasonConstructorPattern sourceSpan)
    pure
      ( PatternQualifiedConstructor
          QualifiedConstructorPattern
            { moduleQualifier = fmap passThroughModuleName moduleQualifier,
              constructorName = passThroughVariableName constructorName,
              parameters = parameters',
              sourceSpan = sourceSpan,
              metadata = ConstrainedPattern patternResult
            },
        patternResult
      )
  where
    walkPatternField (label, sub) = do
      (sub', subType) <- walkPattern sub
      pure ((passThroughLabelName label, sub'), (label.text, subType))

-- ---------------------------------------------------------------------------
-- Block walking (with where-block effect discharge)
-- ---------------------------------------------------------------------------

blockType :: Block Constrained -> SemanticType Unresolved
blockType Block {returnExpression} = case returnExpression of
  Just expression -> case sourceSpanOfConstrainedExpr expression of
    semanticType -> semanticType
  Nothing -> SemanticTypeNull

-- | Read the inferred type out of a Constrained Expression metadata.
sourceSpanOfConstrainedExpr :: Expression Constrained -> SemanticType Unresolved
sourceSpanOfConstrainedExpr expr = case expressionMetadata expr of
  ConstrainedExpression t -> t

-- | Pull the metadata out of a Constrained Expression in a way that exposes
-- the carried 'SemanticType'.
expressionMetadata :: Expression Constrained -> Constrained 'Expression
expressionMetadata = \case
  ExpressionLiteral LiteralExpression {metadata} -> metadata
  ExpressionVariable VariableExpression {metadata} -> metadata
  ExpressionTuple TupleExpression {metadata} -> metadata
  ExpressionArray ArrayExpression {metadata} -> metadata
  ExpressionCall CallExpression {metadata} -> metadata
  ExpressionBinaryOperator BinaryOperatorExpression {metadata} -> metadata
  ExpressionUnaryOperator UnaryOperatorExpression {metadata} -> metadata
  ExpressionIf IfExpression {metadata} -> metadata
  ExpressionMatch MatchExpression {metadata} -> metadata
  ExpressionFor ForExpression {metadata} -> metadata
  ExpressionBlock BlockExpression {metadata} -> metadata
  ExpressionFieldAccess FieldAccessExpression {metadata} -> metadata
  ExpressionIndexAccess IndexAccessExpression {metadata} -> metadata
  ExpressionTemplate TemplateExpression {metadata} -> metadata
  ExpressionQualifiedReference QualifiedReferenceExpression {metadata} -> metadata

walkBlock :: Block Identified -> CG (Block Constrained)
walkBlock Block {statements, returnExpression, whereBlock, sourceSpan} = do
  case whereBlock of
    Nothing -> do
      (statements', returnExpression') <- walkBlockBody statements returnExpression
      pure
        Block
          { statements = statements',
            returnExpression = returnExpression',
            whereBlock = Nothing,
            sourceSpan = sourceSpan
          }
    Just wb -> do
      outerEff <- asks (.contextEnclosingEffects)
      innerEffId <- freshEffectVarId
      (statements', returnExpression') <-
        withEnclosingEffects innerEffId (walkBlockBody statements returnExpression)
      whereBlock' <- walkWhereBlock outerEff innerEffId wb
      pure
        Block
          { statements = statements',
            returnExpression = returnExpression',
            whereBlock = Just whereBlock',
            sourceSpan = sourceSpan
          }

walkBlockBody
  :: [Statement Identified]
  -> Maybe (Expression Identified)
  -> CG ([Statement Constrained], Maybe (Expression Constrained))
walkBlockBody statements returnExpression = do
  statements' <- mapM walkStatement statements
  returnExpression' <- traverse walkExpression returnExpression
  pure (statements', returnExpression')

walkWhereBlock
  :: Maybe EffectVarId
  -> EffectVarId
  -> WhereBlock Identified
  -> CG (WhereBlock Constrained)
walkWhereBlock outerEff innerEffId WhereBlock {stateVariables, handlers, thenClause, sourceSpan} = do
  stateVariables' <- mapM walkStateVariable stateVariables
  handlers' <- mapM (walkRequestHandler outerEff) handlers
  thenClause' <- traverse walkThenClause thenClause
  let handledIds =
        Set.fromList
          [ vid
          | RequestHandler {name} <- handlers,
            IdentifiedVariable vid <- [name.metadata]
          ]
  let outerEffPart = maybe emptyEffect effectFromVar outerEff
      handledPart = SemanticEffect Set.empty handledIds
  addEffectConstraint
    (effectFromVar innerEffId)
    (unionEffects outerEffPart handledPart)
    (ReasonHandleEffectDischarge sourceSpan)
  pure
    WhereBlock
      { stateVariables = stateVariables',
        handlers = handlers',
        thenClause = thenClause',
        sourceSpan = sourceSpan
      }

walkStateVariable :: StateVariableBinding Identified -> CG (StateVariableBinding Constrained)
walkStateVariable StateVariableBinding {name, typeAnnotation, initial, sourceSpan} = do
  tVar <- variableTypeFromName name
  case typeAnnotation of
    Just t -> do
      annotated <- elaborateType t
      addEqTypeConstraint tVar annotated (ReasonStateVarAnnotation sourceSpan)
    Nothing -> pure ()
  initial' <- walkExpression initial
  let initialType = sourceSpanOfConstrainedExpr initial'
  addTypeConstraint initialType tVar (ReasonStateVarAnnotation sourceSpan)
  pure
    StateVariableBinding
      { name = passThroughVariableName name,
        typeAnnotation = fmap passThroughType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkRequestHandler
  :: Maybe EffectVarId
  -> RequestHandler Identified
  -> CG (RequestHandler Constrained)
walkRequestHandler outerEff RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  -- Handler body has no fresh effect var of its own: effects raised inside
  -- bind to the surrounding agent (= outer effect var).
  let walkBody = case outerEff of
        Just ev -> withEnclosingEffects ev
        Nothing -> id
  tHandled <- variableTypeFromName name
  reqVarId <- variableIdOfName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateOrFresh returnType
  retTvId <- freshReturnTypeVar retSemantic
  body' <- walkBody . withReturn retTvId $ walkBlock body
  let bodyType = blockType body'
  addTypeConstraint bodyType (SemanticTypeVariable retTvId) (ReasonReturnStatement sourceSpan)
  addEqTypeConstraint (SemanticTypeVariable retTvId) retSemantic (ReasonReturnTypeAnnotation sourceSpan)
  let handlerSignature =
        SemanticTypeFunction
          paramSig
          retSemantic
          (maybe emptyEffect singletonEffect reqVarId)
  -- subtype only (handler is a re-assignment of the underlying req)
  addTypeConstraint handlerSignature tHandled (ReasonRequestHandlerSignature sourceSpan)
  pure
    RequestHandler
      { moduleQualifier = fmap passThroughModuleName moduleQualifier,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = fmap passThroughType returnType,
        body = body',
        sourceSpan = sourceSpan
      }

walkThenClause
  :: (Maybe (Pattern Identified), Block Identified)
  -> CG (Maybe (Pattern Constrained), Block Constrained)
walkThenClause (maybePattern, block) = do
  maybePattern' <- traverse (fmap fst . walkPattern) maybePattern
  block' <- walkBlock block
  pure (maybePattern', block')

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

walkStatement :: Statement Identified -> CG (Statement Constrained)
walkStatement = \case
  StatementLet stmt -> StatementLet <$> walkLet stmt
  StatementAgent stmt -> StatementAgent <$> walkAgentStatement stmt
  StatementReturn stmt -> StatementReturn <$> walkReturn stmt
  StatementExpression expr -> StatementExpression <$> walkExpression expr
  StatementNext stmt -> StatementNext <$> walkNext stmt
  StatementBreak stmt -> StatementBreak <$> walkBreak stmt
  StatementForNext stmt -> StatementForNext <$> walkForNext stmt
  StatementForBreak stmt -> StatementForBreak <$> walkForBreak stmt
  StatementError span_ -> pure (StatementError span_)

walkLet :: LetStatement Identified -> CG (LetStatement Constrained)
walkLet LetStatement {pattern, value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = sourceSpanOfConstrainedExpr value'
  (pattern', patternType) <- walkPattern pattern
  addTypeConstraint valueType patternType (ReasonLetPattern sourceSpan)
  pure LetStatement {pattern = pattern', value = value', sourceSpan = sourceSpan}

walkAgentStatement :: AgentStatement Identified -> CG (AgentStatement Constrained)
walkAgentStatement AgentStatement {name, parameters, returnType, withEffects, body, sourceSpan} = do
  tFoo <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateOrFresh returnType
  effDeclared <- maybe (effectFromVar <$> freshEffectVarId) pure =<< elaborateOptionalEffects withEffects
  bodyEffectVarId <- freshEffectVarId
  retTvId <- freshReturnTypeVar retSemantic
  body' <- withReturn retTvId . withEnclosingEffects bodyEffectVarId $ walkBlock body
  let bodyType = blockType body'
  addTypeConstraint bodyType (SemanticTypeVariable retTvId) (ReasonReturnStatement sourceSpan)
  addEqTypeConstraint (SemanticTypeVariable retTvId) retSemantic (ReasonReturnTypeAnnotation sourceSpan)
  addEffectConstraint
    (effectFromVar bodyEffectVarId)
    effDeclared
    (ReasonEffectBound sourceSpan)
  let signature = SemanticTypeFunction paramSig retSemantic effDeclared
  addEqTypeConstraint signature tFoo (ReasonAgentSignature sourceSpan)
  pure
    AgentStatement
      { name = passThroughVariableName name,
        parameters = parameters',
        returnType = fmap passThroughType returnType,
        withEffects = fmap (fmap passThroughRequest) withEffects,
        body = body',
        sourceSpan = sourceSpan
      }

walkReturn :: ReturnStatement Identified -> CG (ReturnStatement Constrained)
walkReturn ReturnStatement {value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = sourceSpanOfConstrainedExpr value'
  retContext <- asks (.contextEnclosingReturn)
  case retContext of
    Just rt -> addTypeConstraint valueType (SemanticTypeVariable rt) (ReasonReturnStatement sourceSpan)
    Nothing -> pure ()
  pure ReturnStatement {value = value', sourceSpan = sourceSpan}

walkNext :: NextStatement Identified -> CG (NextStatement Constrained)
walkNext NextStatement {value, modifiers, sourceSpan} = do
  value' <- walkExpression value
  let valueType = sourceSpanOfConstrainedExpr value'
  modifiers' <- mapM walkModifier modifiers
  -- Tie the value to the appropriate handler-next type variable. Currently
  -- the surrounding handler context doesn't tell us which req we're in (the
  -- map is keyed by VariableId), so we conservatively pick the single entry
  -- if present. In the multi-handler case this needs refinement once the
  -- enclosing handler's identity is exposed to the body.
  nexts <- asks (.contextEnclosingHandleNext)
  case Map.elems nexts of
    [tv] -> addTypeConstraint valueType (SemanticTypeVariable tv) (ReasonHandleNext sourceSpan)
    _ -> pure ()  -- 0 or 2+; defer for later precision
  pure NextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}

walkBreak :: BreakStatement Identified -> CG (BreakStatement Constrained)
walkBreak BreakStatement {value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = sourceSpanOfConstrainedExpr value'
  resultContext <- asks (.contextEnclosingHandleResult)
  case resultContext of
    Just rt -> addTypeConstraint valueType (SemanticTypeVariable rt) (ReasonHandleBreak sourceSpan)
    Nothing -> pure ()
  pure BreakStatement {value = value', sourceSpan = sourceSpan}

walkForNext :: ForNextStatement Identified -> CG (ForNextStatement Constrained)
walkForNext ForNextStatement {modifiers, sourceSpan} = do
  modifiers' <- mapM walkModifier modifiers
  -- For-body's iteration value is null when next has no expression.
  bodyContext <- asks (.contextEnclosingForBody)
  case bodyContext of
    Just bv -> addTypeConstraint SemanticTypeNull (SemanticTypeVariable bv) (ReasonForBody sourceSpan)
    Nothing -> pure ()
  pure ForNextStatement {modifiers = modifiers', sourceSpan = sourceSpan}

walkForBreak :: ForBreakStatement Identified -> CG (ForBreakStatement Constrained)
walkForBreak ForBreakStatement {value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = sourceSpanOfConstrainedExpr value'
  breakContext <- asks (.contextEnclosingForBreak)
  case breakContext of
    Just bv -> addTypeConstraint valueType (SemanticTypeVariable bv) (ReasonForBreak sourceSpan)
    Nothing -> pure ()
  pure ForBreakStatement {value = value', sourceSpan = sourceSpan}

walkModifier :: Modifier Identified -> CG (Modifier Constrained)
walkModifier Modifier {name, value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = sourceSpanOfConstrainedExpr value'
  tVar <- variableTypeFromName name
  addTypeConstraint valueType tVar (ReasonModifierUpdate sourceSpan)
  pure Modifier {name = passThroughVariableName name, value = value', sourceSpan = sourceSpan}

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

walkExpression :: Expression Identified -> CG (Expression Constrained)
walkExpression = \case
  ExpressionLiteral expr -> walkLiteralExpr expr
  ExpressionVariable expr -> walkVariableExpr expr
  ExpressionTuple expr -> walkTupleExpr expr
  ExpressionArray expr -> walkArrayExpr expr
  ExpressionCall expr -> walkCallExpr expr
  ExpressionBinaryOperator expr -> walkBinaryExpr expr
  ExpressionUnaryOperator expr -> walkUnaryExpr expr
  ExpressionIf expr -> walkIfExpr expr
  ExpressionMatch expr -> walkMatchExpr expr
  ExpressionFor expr -> walkForExpr expr
  ExpressionBlock expr -> walkBlockExpr expr
  ExpressionFieldAccess expr -> walkFieldAccessExpr expr
  ExpressionIndexAccess expr -> walkIndexAccessExpr expr
  ExpressionTemplate expr -> walkTemplateExpr expr
  ExpressionQualifiedReference expr -> walkQualifiedReferenceExpr expr

walkLiteralExpr :: LiteralExpression Identified -> CG (Expression Constrained)
walkLiteralExpr LiteralExpression {value, sourceSpan} = do
  let semantic = literalValueToSemantic value
  pure
    ( ExpressionLiteral
        LiteralExpression
          { value = value,
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression semantic
          }
    )

walkVariableExpr :: VariableExpression Identified -> CG (Expression Constrained)
walkVariableExpr VariableExpression {name, sourceSpan} = do
  semantic <- variableTypeFromName name
  pure
    ( ExpressionVariable
        VariableExpression
          { name = passThroughVariableName name,
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression semantic
          }
    )

walkTupleExpr :: TupleExpression Identified -> CG (Expression Constrained)
walkTupleExpr TupleExpression {elements, sourceSpan} = do
  elements' <- mapM walkExpression elements
  let semantic = SemanticTypeTuple (map sourceSpanOfConstrainedExpr elements')
  pure
    ( ExpressionTuple
        TupleExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression semantic
          }
    )

walkArrayExpr :: ArrayExpression Identified -> CG (Expression Constrained)
walkArrayExpr ArrayExpression {elements, sourceSpan} = do
  elements' <- mapM walkExpression elements
  tElem <- freshTypeVar
  mapM_
    ( \e ->
        addTypeConstraint
          (sourceSpanOfConstrainedExpr e)
          tElem
          (ReasonArrayElement sourceSpan)
    )
    elements'
  pure
    ( ExpressionArray
        ArrayExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression (SemanticTypeArray tElem)
          }
    )

walkCallExpr :: CallExpression Identified -> CG (Expression Constrained)
walkCallExpr CallExpression {callee, arguments, sourceSpan} = do
  callee' <- walkExpression callee
  let calleeType = sourceSpanOfConstrainedExpr callee'
  arguments' <- mapM walkCallArgument arguments
  let argSig =
        [ (label, sourceSpanOfConstrainedExpr value')
        | CallArgument {label, value = value'} <- arguments',
          let _ = label.text  -- silence unused; we use label below
        ]
      argSigCorrected =
        map
          (\CallArgument {label, value = value'} -> (label.text, sourceSpanOfConstrainedExpr value'))
          arguments'
  tResult <- freshTypeVar
  enclosing <- asks (.contextEnclosingEffects)
  let calleeEff = maybe emptyEffect effectFromVar enclosing
      expected = SemanticTypeFunction argSigCorrected tResult calleeEff
  addTypeConstraint calleeType expected (ReasonCallArgument sourceSpan)
  -- Suppress unused binding while keeping clear naming.
  _ <- pure argSig
  pure
    ( ExpressionCall
        CallExpression
          { callee = callee',
            arguments = arguments',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression tResult
          }
    )

walkCallArgument :: CallArgument Identified -> CG (CallArgument Constrained)
walkCallArgument CallArgument {label, value, sourceSpan} = do
  value' <- walkExpression value
  pure
    CallArgument
      { label = passThroughLabelName label,
        value = value',
        sourceSpan = sourceSpan
      }

walkBinaryExpr :: BinaryOperatorExpression Identified -> CG (Expression Constrained)
walkBinaryExpr BinaryOperatorExpression {operator, left, right, sourceSpan} = do
  left' <- walkExpression left
  right' <- walkExpression right
  let lt = sourceSpanOfConstrainedExpr left'
      rt = sourceSpanOfConstrainedExpr right'
  resultType <- binaryOperatorConstraints operator lt rt sourceSpan
  pure
    ( ExpressionBinaryOperator
        BinaryOperatorExpression
          { operator = operator,
            left = left',
            right = right',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression resultType
          }
    )

binaryOperatorConstraints
  :: BinaryOperator
  -> SemanticType Unresolved
  -> SemanticType Unresolved
  -> SourceSpan
  -> CG (SemanticType Unresolved)
binaryOperatorConstraints operator lhs rhs sourceSpan = case operator of
  BinaryOperatorAdd -> arithmetic
  BinaryOperatorSubtract -> arithmetic
  BinaryOperatorMultiply -> arithmetic
  BinaryOperatorDivide -> arithmetic
  BinaryOperatorEqual -> noConstraintBoolean
  BinaryOperatorNotEqual -> noConstraintBoolean
  BinaryOperatorLessThan -> compareNumeric
  BinaryOperatorLessOrEqual -> compareNumeric
  BinaryOperatorGreaterThan -> compareNumeric
  BinaryOperatorGreaterOrEqual -> compareNumeric
  BinaryOperatorAnd -> logical
  BinaryOperatorOr -> logical
  BinaryOperatorConcat -> concatString
  where
    arithmetic = do
      addTypeConstraint lhs SemanticTypeNumber (ReasonBinaryOperator sourceSpan)
      addTypeConstraint rhs SemanticTypeNumber (ReasonBinaryOperator sourceSpan)
      pure SemanticTypeNumber
    noConstraintBoolean = pure SemanticTypeBoolean
    compareNumeric = do
      addTypeConstraint lhs SemanticTypeNumber (ReasonBinaryOperator sourceSpan)
      addTypeConstraint rhs SemanticTypeNumber (ReasonBinaryOperator sourceSpan)
      pure SemanticTypeBoolean
    logical = do
      addTypeConstraint lhs SemanticTypeBoolean (ReasonBinaryOperator sourceSpan)
      addTypeConstraint rhs SemanticTypeBoolean (ReasonBinaryOperator sourceSpan)
      pure SemanticTypeBoolean
    concatString = do
      addTypeConstraint lhs SemanticTypeString (ReasonBinaryOperator sourceSpan)
      addTypeConstraint rhs SemanticTypeString (ReasonBinaryOperator sourceSpan)
      pure SemanticTypeString

walkUnaryExpr :: UnaryOperatorExpression Identified -> CG (Expression Constrained)
walkUnaryExpr UnaryOperatorExpression {operator, operand, sourceSpan} = do
  operand' <- walkExpression operand
  let ot = sourceSpanOfConstrainedExpr operand'
  resultType <- case operator of
    UnaryOperatorNegate -> do
      addTypeConstraint ot SemanticTypeNumber (ReasonUnaryOperator sourceSpan)
      pure SemanticTypeNumber
    UnaryOperatorNot -> do
      addTypeConstraint ot SemanticTypeBoolean (ReasonUnaryOperator sourceSpan)
      pure SemanticTypeBoolean
  pure
    ( ExpressionUnaryOperator
        UnaryOperatorExpression
          { operator = operator,
            operand = operand',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression resultType
          }
    )

walkIfExpr :: IfExpression Identified -> CG (Expression Constrained)
walkIfExpr IfExpression {condition, thenBlock, elseBlock, sourceSpan} = do
  condition' <- walkExpression condition
  let condType = sourceSpanOfConstrainedExpr condition'
  addTypeConstraint condType SemanticTypeBoolean (ReasonIfCondition sourceSpan)
  thenBlock' <- walkBlock thenBlock
  let thenType = blockType thenBlock'
  elseBlock' <- traverse walkBlock elseBlock
  let elseType = case elseBlock' of
        Just b -> blockType b
        Nothing -> SemanticTypeNull
  tResult <- freshTypeVar
  addTypeConstraint thenType tResult (ReasonIfBranch sourceSpan)
  addTypeConstraint elseType tResult (ReasonIfBranch sourceSpan)
  pure
    ( ExpressionIf
        IfExpression
          { condition = condition',
            thenBlock = thenBlock',
            elseBlock = elseBlock',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression tResult
          }
    )

walkMatchExpr :: MatchExpression Identified -> CG (Expression Constrained)
walkMatchExpr MatchExpression {subject, cases, sourceSpan} = do
  subject' <- walkExpression subject
  let subjectType = sourceSpanOfConstrainedExpr subject'
  tMatch <- freshTypeVar
  (cases', patternTypes) <-
    foldM
      ( \(accCases, accPats) caseArm -> do
          (caseArm', patType) <- walkCaseArm tMatch caseArm
          pure (accCases ++ [caseArm'], accPats ++ [patType])
      )
      ([], [])
      cases
  let patternUnion = case patternTypes of
        [] -> SemanticTypeNever
        [single] -> single
        many -> SemanticTypeUnion many
  addTypeConstraint subjectType patternUnion (ReasonMatchSubject sourceSpan)
  pure
    ( ExpressionMatch
        MatchExpression
          { subject = subject',
            cases = cases',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression tMatch
          }
    )

walkCaseArm
  :: SemanticType Unresolved
  -> CaseArm Identified
  -> CG (CaseArm Constrained, SemanticType Unresolved)
walkCaseArm tMatch CaseArm {pattern, body, sourceSpan} = do
  (pattern', patternType) <- walkPattern pattern
  body' <- walkBlock body
  let bodyTy = blockType body'
  addTypeConstraint bodyTy tMatch (ReasonMatchArm sourceSpan)
  pure
    ( CaseArm
        { pattern = pattern',
          body = body',
          sourceSpan = sourceSpan
        },
      patternType
    )

walkForExpr :: ForExpression Identified -> CG (Expression Constrained)
walkForExpr ForExpression {inBindings, varBindings, body, thenBlock, sourceSpan} = do
  -- in-bindings: source は外側 scope で walk
  inBindings' <- mapM walkForInBinding inBindings
  varBindings' <- mapM walkForVarBinding varBindings
  tForBreakId <- freshTypeVarId
  tForBodyId <- freshTypeVarId
  body' <-
    withForLoop tForBreakId tForBodyId $ walkBlock body
  let bodyTy = blockType body'
  addTypeConstraint bodyTy (SemanticTypeVariable tForBodyId) (ReasonForBody sourceSpan)
  thenBlock' <- traverse walkBlock thenBlock
  let thenType = case thenBlock' of
        Just b -> blockType b
        Nothing -> SemanticTypeNull
  let resultType =
        SemanticTypeUnion [thenType, SemanticTypeVariable tForBreakId]
  pure
    ( ExpressionFor
        ForExpression
          { inBindings = inBindings',
            varBindings = varBindings',
            body = body',
            thenBlock = thenBlock',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression resultType
          }
    )

walkForInBinding :: ForInBinding Identified -> CG (ForInBinding Constrained)
walkForInBinding ForInBinding {pattern, source, sourceSpan} = do
  source' <- walkExpression source
  let sourceType = sourceSpanOfConstrainedExpr source'
  tElem <- freshTypeVar
  addTypeConstraint sourceType (SemanticTypeArray tElem) (ReasonForIn sourceSpan)
  (pattern', patternType) <- walkPattern pattern
  addTypeConstraint tElem patternType (ReasonForIn sourceSpan)
  pure ForInBinding {pattern = pattern', source = source', sourceSpan = sourceSpan}

walkForVarBinding :: ForVarBinding Identified -> CG (ForVarBinding Constrained)
walkForVarBinding ForVarBinding {name, typeAnnotation, initial, sourceSpan} = do
  tVar <- variableTypeFromName name
  case typeAnnotation of
    Just t -> do
      annotated <- elaborateType t
      addEqTypeConstraint tVar annotated (ReasonStateVarAnnotation sourceSpan)
    Nothing -> pure ()
  initial' <- walkExpression initial
  let initialType = sourceSpanOfConstrainedExpr initial'
  addTypeConstraint initialType tVar (ReasonStateVarAnnotation sourceSpan)
  pure
    ForVarBinding
      { name = passThroughVariableName name,
        typeAnnotation = fmap passThroughType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkBlockExpr :: BlockExpression Identified -> CG (Expression Constrained)
walkBlockExpr BlockExpression {block, sourceSpan} = do
  block' <- walkBlock block
  let semantic = blockType block'
  pure
    ( ExpressionBlock
        BlockExpression
          { block = block',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression semantic
          }
    )

walkFieldAccessExpr :: FieldAccessExpression Identified -> CG (Expression Constrained)
walkFieldAccessExpr FieldAccessExpression {object, fieldName, sourceSpan} = do
  object' <- walkExpression object
  let objectType = sourceSpanOfConstrainedExpr object'
  tField <- freshTypeVar
  addTypeConstraint
    objectType
    (SemanticTypeObject (Map.singleton fieldName.text tField))
    (ReasonFieldAccess sourceSpan)
  pure
    ( ExpressionFieldAccess
        FieldAccessExpression
          { object = object',
            fieldName = passThroughLabelName fieldName,
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression tField
          }
    )

walkIndexAccessExpr :: IndexAccessExpression Identified -> CG (Expression Constrained)
walkIndexAccessExpr IndexAccessExpression {array, index, sourceSpan} = do
  array' <- walkExpression array
  let arrayType = sourceSpanOfConstrainedExpr array'
  index' <- walkExpression index
  let indexType = sourceSpanOfConstrainedExpr index'
  tElem <- freshTypeVar
  addTypeConstraint arrayType (SemanticTypeArray tElem) (ReasonIndexAccessArray sourceSpan)
  addTypeConstraint indexType SemanticTypeInteger (ReasonIndexAccessIndex sourceSpan)
  pure
    ( ExpressionIndexAccess
        IndexAccessExpression
          { array = array',
            index = index',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression tElem
          }
    )

walkTemplateExpr :: TemplateExpression Identified -> CG (Expression Constrained)
walkTemplateExpr TemplateExpression {elements, sourceSpan} = do
  elements' <- mapM walkTemplateElement elements
  pure
    ( ExpressionTemplate
        TemplateExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression SemanticTypeString
          }
    )

walkTemplateElement :: TemplateElement Identified -> CG (TemplateElement Constrained)
walkTemplateElement = \case
  TemplateElementString TemplateStringElement {value, sourceSpan} ->
    pure (TemplateElementString TemplateStringElement {value = value, sourceSpan = sourceSpan})
  TemplateElementExpression TemplateExpressionElement {value, sourceSpan} -> do
    value' <- walkExpression value
    let valueType = sourceSpanOfConstrainedExpr value'
    addTypeConstraint valueType SemanticTypeString (ReasonTemplateInterpolation sourceSpan)
    pure (TemplateElementExpression TemplateExpressionElement {value = value', sourceSpan = sourceSpan})

walkQualifiedReferenceExpr
  :: QualifiedReferenceExpression Identified
  -> CG (Expression Constrained)
walkQualifiedReferenceExpr QualifiedReferenceExpression {moduleQualifier, target, sourceSpan} = do
  semantic <- variableTypeFromName target
  pure
    ( ExpressionQualifiedReference
        QualifiedReferenceExpression
          { moduleQualifier = passThroughModuleName moduleQualifier,
            target = passThroughVariableName target,
            sourceSpan = sourceSpan,
            metadata = ConstrainedExpression semantic
          }
    )

-- ===========================================================================
-- Pass-through helpers (Identified -> Constrained for ref-only nodes)
-- ===========================================================================

passThroughVariableName :: NameRef Identified 'VariableRef -> NameRef Constrained 'VariableRef
passThroughVariableName ref =
  NameRef
    { text = ref.text,
      sourceSpan = ref.sourceSpan,
      metadata = case ref.metadata of
        IdentifiedVariable vid -> ConstrainedVariable vid
        IdentifiedUnresolvedVariable -> ConstrainedUnresolvedVariable
    }

passThroughTypeName :: NameRef Identified 'TypeRef -> NameRef Constrained 'TypeRef
passThroughTypeName ref =
  NameRef
    { text = ref.text,
      sourceSpan = ref.sourceSpan,
      metadata = case ref.metadata of
        IdentifiedType tid -> ConstrainedType tid
        IdentifiedUnresolvedType -> ConstrainedUnresolvedType
    }

passThroughModuleName :: NameRef Identified 'ModuleRef -> NameRef Constrained 'ModuleRef
passThroughModuleName ref =
  NameRef
    { text = ref.text,
      sourceSpan = ref.sourceSpan,
      metadata = case ref.metadata of
        IdentifiedModule mid -> ConstrainedModule mid
        IdentifiedUnresolvedModule -> ConstrainedUnresolvedModule
    }

passThroughLabelName :: NameRef Identified 'LabelRef -> NameRef Constrained 'LabelRef
passThroughLabelName ref =
  NameRef
    { text = ref.text,
      sourceSpan = ref.sourceSpan,
      metadata = ConstrainedLabel
    }

passThroughType :: SyntacticType Identified -> SyntacticType Constrained
passThroughType = \case
  TypePrimitive PrimitiveTypeNode {kind, sourceSpan} ->
    TypePrimitive PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan}
  TypeName TypeNameNode {name, sourceSpan} ->
    TypeName TypeNameNode {name = passThroughTypeName name, sourceSpan = sourceSpan}
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withEffects, sourceSpan} ->
    TypeFunction
      FunctionTypeNode
        { parameterTypes = map (\(l, t) -> (l, passThroughType t)) parameterTypes,
          returnType = passThroughType returnType,
          withEffects = map passThroughRequest withEffects,
          sourceSpan = sourceSpan
        }
  TypeArray ArrayTypeNode {elementType, sourceSpan} ->
    TypeArray ArrayTypeNode {elementType = passThroughType elementType, sourceSpan = sourceSpan}
  TypeTuple TupleTypeNode {elementTypes, sourceSpan} ->
    TypeTuple TupleTypeNode {elementTypes = map passThroughType elementTypes, sourceSpan = sourceSpan}
  TypeQualified QualifiedTypeNode {qualifier, target, sourceSpan} ->
    TypeQualified
      QualifiedTypeNode
        { qualifier = passThroughModuleName qualifier,
          target = passThroughTypeName target,
          sourceSpan = sourceSpan
        }
  TypeLiteral node -> TypeLiteral node
  TypeUnion TypeUnionNode {branches, sourceSpan} ->
    TypeUnion TypeUnionNode {branches = map passThroughType branches, sourceSpan = sourceSpan}
  TypeNever NeverTypeNode {sourceSpan} ->
    TypeNever NeverTypeNode {sourceSpan = sourceSpan}
  TypeUnknown UnknownTypeNode {sourceSpan} ->
    TypeUnknown UnknownTypeNode {sourceSpan = sourceSpan}

passThroughRequest :: SyntacticRequest Identified -> SyntacticRequest Constrained
passThroughRequest SyntacticRequest {name, sourceSpan} =
  SyntacticRequest {name = passThroughVariableName name, sourceSpan = sourceSpan}

-- ===========================================================================
-- Small accessors and conveniences
-- ===========================================================================

-- | Look up a variable's type via the @Identified@ name reference.
-- Unresolved references get a fresh type variable (Identifier already
-- reported the original error).
variableTypeFromName :: NameRef Identified 'VariableRef -> CG (SemanticType Unresolved)
variableTypeFromName nameRef = case nameRef.metadata of
  IdentifiedVariable vid -> lookupVariable vid
  IdentifiedUnresolvedVariable -> freshTypeVar

variableIdOfName :: NameRef Identified 'VariableRef -> CG (Maybe VariableId)
variableIdOfName nameRef = pure $ case nameRef.metadata of
  IdentifiedVariable vid -> Just vid
  IdentifiedUnresolvedVariable -> Nothing

typeIdForDataName :: NameRef Identified 'VariableRef -> CG (Maybe TypeId)
typeIdForDataName nameRef = do
  -- Data constructors share their name with the type they construct. The
  -- Identifier pass registers the type id under the same text label, so
  -- we look it up in @identifiedTypes@ keyed by name text.
  types <- asks (.contextIdentifiedTypes)
  let matches =
        [ tid
        | (tid, td) <- Map.toList types,
          td.typeName == nameRef.text
        ]
  pure $ case matches of
    [tid] -> Just tid
    _ -> Nothing

-- | If the optional type annotation is present, elaborate it; otherwise
-- allocate a fresh type variable so the solver can infer it.
elaborateOrFresh :: Maybe (SyntacticType Identified) -> CG (SemanticType Unresolved)
elaborateOrFresh = \case
  Just t -> elaborateType t
  Nothing -> freshTypeVar

-- | Allocate a type variable id whose 'SemanticTypeVariable' wrapper matches
-- the supplied semantic type when that semantic type already is a fresh
-- type variable. Otherwise allocate a fresh one. Used to bridge the
-- "context's enclosing return type variable" plumbing — the variable id is
-- needed both to push into the context and to compose constraints.
freshReturnTypeVar :: SemanticType Unresolved -> CG TypeVarId
freshReturnTypeVar = \case
  SemanticTypeVariable tv -> pure tv
  _ -> freshTypeVarId

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- | Run constraint generation over an 'IdentifierResult' (which may contain
-- multiple modules). All variables across all modules are allocated a type
-- variable in Phase A, then declarations are walked in Phase B to emit
-- constraints and produce the @Constrained@-phase ASTs.
generateConstraints :: IdentifierResult -> ConstraintGenResult
generateConstraints result = case runState (runReaderT action ctx) initialState of
  (modulesPair, finalState) ->
    ConstraintGenResult
      { constrainedModules = Map.fromList modulesPair,
        typeEnvironment = finalState.stateTypeEnvironment,
        constraints = reverse finalState.stateConstraints,
        nextTypeVarId = finalState.stateNextTypeVarId,
        nextEffectVarId = finalState.stateNextEffectVarId,
        errors = reverse finalState.stateErrors
      }
  where
    ctx = initialContext result.identifiedTypes
    action = do
      allocateAllVariables result
      mapM walkOne (Map.toList result.moduleASTs)
    walkOne (mid, mod') = do
      mod'' <- walkModule mod'
      pure (mid, mod'')
