-- | Typechecker phase 2: Constraint generation.
--
-- Walks the @Identified@ AST, attaches an 'SemanticType' 'Unresolved' to every
-- expression and pattern, and emits a list of subtype constraints (over
-- types and requests) for the solver. The output AST is parameterised by the
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
--   * Request inference uses the same context-passing trick as @return@ and
--     @break@: each scope (agent body / req handler / @where@ block body)
--     allocates a fresh 'RequestVariableId'. Function-call subtyping cascades
--     callee requests into the enclosing request variable.
--   * @where@ blocks /discharge/ the requests they handle: the inner block's
--     request set is constrained to be a subset of @outer ∪ handled-reqs@.
--   * 'CG' never traverses the AST a second time to "collect" structural
--     information. Anything CG needs that isn't immediately visible at a
--     node lives in 'IdentifierResult' and is read locally.
module Katari.Typechecker.ConstraintGenerator
  ( -- * Constraint and reason
    Constraint (..),
    ConstraintReason (..),
    ReasonKind (..),
    ConstraintError (..),

    -- * Result
    ConstraintGenResult (..),
    VariableSupply (..),
    TypeEnvironment,

    -- * Diagnostics
    toDiagnostic,

    -- * Entry point
    generateConstraints,
  )
where

import Control.Monad (replicateM, unless)
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Control.Monad.Trans (lift)
import Data.List (transpose)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
import Katari.Common (LiteralValue (..))
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Id
  ( ConstructorId,
    ModuleId,
    QualifiedName (..),
    RequestId,
    TypeId (..),
    VariableId,
  )
import Katari.Prim (PrimRule (..))
import Katari.SemanticType
import Katari.SourceSpan
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
    RequestData (..),
    TypeData (..),
    VariableData (..),
  )

-- The 'Constrained' phase reuses the 'NameRefResolution Constrained s' family for
-- name resolution (identical to 'Identified'), and stores the inferred
-- @SemanticType Unresolved@ on each expression / pattern via the
-- @ExpressionType Constrained@ / @PatternType Constrained@ instances defined in
-- 'Katari.SemanticType'.

-- ===========================================================================
-- Constraint and reason
-- ===========================================================================

-- | A single subtyping constraint, either between two semantic types or
-- between two request sets. Equality is encoded as two subtype constraints in
-- opposite directions.
data Constraint where
  TypeConstraint ::
    { typeLhs :: SemanticType Unresolved,
      typeRhs :: SemanticType Unresolved,
      reason :: ConstraintReason
    } ->
    Constraint
  RequestConstraint ::
    { requestLhs :: SemanticRequest Unresolved,
      requestRhs :: SemanticRequest Unresolved,
      reason :: ConstraintReason
    } ->
    Constraint
  deriving (Eq, Ord, Show)

-- | Where the constraint came from. Drives diagnostics; callers should pick
-- the most specific reason that applies. The 'sourceSpan' is the syntactic
-- site that triggered the constraint — the 'kind' identifies the variety.
data ConstraintReason = ConstraintReason
  { kind :: ReasonKind,
    sourceSpan :: SourceSpan
  }
  deriving (Eq, Ord, Show)

instance HasSourceSpan ConstraintReason where
  sourceSpanOf reason = reason.sourceSpan

-- | Variety of a 'ConstraintReason'. Mirrors the previous tagged-union
-- 'ConstraintReason' shape, but factored out so each constructor is a
-- pure tag — the 'SourceSpan' lives once on the wrapper instead of being
-- duplicated on every constructor.
data ReasonKind where
  ReasonKindAgentSignature :: ReasonKind
  ReasonKindRequestSignature :: ReasonKind
  ReasonKindExternalAgentSignature :: ReasonKind
  ReasonKindDataConstructorSignature :: ReasonKind
  ReasonKindRequestHandlerSignature :: ReasonKind
  ReasonKindReturnTypeAnnotation :: ReasonKind
  ReasonKindReturnStatement :: ReasonKind
  -- | Implicit fall-through return of the body (the case where the
  -- function exits via the tail expression of a block rather than an
  -- explicit @return@ statement). A separate reason from
  -- 'ReasonKindReturnStatement' so the diagnostic messages can differ.
  ReasonKindImplicitReturn :: ReasonKind
  ReasonKindRequestBound :: ReasonKind
  ReasonKindHandleRequestDischarge :: ReasonKind
  ReasonKindHandlerRequestBound :: ReasonKind
  ReasonKindHandleNext :: ReasonKind
  -- | A request handler body must terminate with @break@ or @next@ — i.e.
  -- the body's inferred type must be 'SemanticTypeNever'. Falling through
  -- to a value would mean the body returned past the request handler
  -- frame with nothing to do with the value, which is now a type error
  -- (replaces the prior implicit-break behavior).
  ReasonKindRequestHandlerNever :: ReasonKind
  ReasonKindHandleBreak :: ReasonKind
  ReasonKindHandleResultBody :: ReasonKind
  -- | The body's normal-completion (tail) value of a block-with-then
  -- must match the @then@ clause's pattern type (@bodyTail <: patternType@).
  -- break / return / next from inside the body do NOT pass through this
  -- pattern — they target their outer boundaries directly.
  ReasonKindThenPattern :: ReasonKind
  -- | The @then@ body's tail value flows into the whole-block type
  -- (the "result of the entire block-with-where-and-then expression").
  ReasonKindThenBodyToWhole :: ReasonKind
  ReasonKindForBreak :: ReasonKind
  ReasonKindForIn :: ReasonKind
  ReasonKindModifierUpdate :: ReasonKind
  ReasonKindLetPattern :: ReasonKind
  ReasonKindStateVarAnnotation :: ReasonKind
  ReasonKindForVarAnnotation :: ReasonKind
  ReasonKindVariablePatternAnnotation :: ReasonKind
  ReasonKindCallArgument :: ReasonKind
  ReasonKindBinaryOperator :: ReasonKind
  ReasonKindUnaryOperator :: ReasonKind
  ReasonKindIfCondition :: ReasonKind
  ReasonKindIfBranch :: ReasonKind
  ReasonKindMatchSubject :: ReasonKind
  ReasonKindMatchArm :: ReasonKind
  ReasonKindFieldAccess :: ReasonKind
  ReasonKindIndexAccessArray :: ReasonKind
  ReasonKindIndexAccessIndex :: ReasonKind
  ReasonKindTemplateInterpolation :: ReasonKind
  ReasonKindArrayElement :: ReasonKind
  ReasonKindConstructorPattern :: ReasonKind
  -- | Marker for structural breakdowns that originate inside the Solver
  -- (e.g. "all branches failed") and whose syntactic source cannot be
  -- pinned down. Since Diagnostics need some span, we attach the source
  -- span of the first related constraint. Should not occur on the normal
  -- code path (if it does, it surfaces as a user-visible error).
  ReasonKindSolverInternal :: ReasonKind
  deriving (Eq, Ord, Show)

-- | Errors emitted by the constraint generator itself (separate from solver
-- errors). Currently the only failure mode is a cyclic type synonym.
data ConstraintError
  = ConstraintErrorTypeSynonymCycle SourceSpan TypeId
  deriving (Eq, Show)

-- | Convert a 'ConstraintError' to a unified 'Diagnostic'. Codes
-- K0200-K0219 are reserved for the constraint generator. The name map
-- (= 'TypeId' → user-declared name) lets us print
-- /"cyclic type synonym 'Foo'"/ instead of /"cyclic type synonym (TypeId 7)"/.
toDiagnostic :: Map TypeId Text -> ConstraintError -> Diagnostic
toDiagnostic typeNames = \case
  ConstraintErrorTypeSynonymCycle sourceSpan tid@(TypeId rawId) ->
    diagnosticError
      "K0200"
      ( "cyclic type synonym "
          <> case Map.lookup tid typeNames of
            Just n -> "'" <> n <> "'"
            Nothing -> "(TypeId " <> T.pack (show rawId) <> ")"
      )
      sourceSpan

-- ===========================================================================
-- Result
-- ===========================================================================

-- | Type environment: maps each 'VariableId' (allocated by the Identifier
-- pass) to the 'SemanticType' Unresolved that the constraint generator
-- assigned to it.
type TypeEnvironment = Map VariableId (SemanticType Unresolved)

-- | High-water marks of fresh-id supplies left over from constraint
-- generation. The Solver consumes these to allocate further fresh
-- variables during branching.
data VariableSupply = VariableSupply
  { typeVarSupply :: Int,
    requestVarSupply :: Int
  }
  deriving (Eq, Show)

-- | Output of the constraint-generation pass. Carries the phase-advanced
-- AST ('Constrained' phase, with each expression / pattern annotated by
-- an unresolved 'SemanticType'), the seeded type environment, the
-- accumulated subtype / effect 'Constraint' set the solver must
-- discharge, and the next-id supply so the solver can keep allocating
-- fresh variables consistently.
data ConstraintGenResult = ConstraintGenResult
  { constrainedModules :: Map ModuleId (Module Constrained),
    typeEnvironment :: TypeEnvironment,
    constraints :: Set Constraint,
    variableSupply :: VariableSupply
  }
  deriving (Show)

-- ===========================================================================
-- Monad
-- ===========================================================================

data ConstraintState = ConstraintState
  { stateNextTypeVariableId :: Int,
    stateNextRequestVariableId :: Int,
    stateTypeEnvironment :: TypeEnvironment,
    stateConstraints :: Set Constraint,
    stateErrors :: [ConstraintError]
  }

data ConstraintContext = ConstraintContext
  { contextIdentifiedTypes :: Map TypeId TypeData,
    -- | Reverse map for the 'RequestId' / 'ConstructorId' namespaces:
    -- given a request or constructor id, find the call-side 'VariableId'
    -- whose type lives in 'stateTypeEnvironment'. Populated from
    -- 'IdentifierResult.identifiedRequests' / 'identifiedConstructors'.
    contextIdentifiedRequests :: Map RequestId RequestData,
    contextIdentifiedConstructors :: Map ConstructorId ConstructorData,
    -- | Forward cross-link: 'VariableId' → 'RequestId'. Built from the
    -- 'requestVariableId' fields of 'identifiedRequests' so the request
    -- declaration walker can populate the singleton request for @req foo@'s
    -- own signature without re-walking the AST.
    contextRequestOfVariable :: Map VariableId RequestId,
    -- | For cycle detection
    contextSynonymVisited :: Set TypeId,
    contextEnclosingReturn :: Maybe TypeVariableId,
    contextEnclosingRequests :: Maybe RequestVariableId,
    contextEnclosingForBreak :: Maybe TypeVariableId,
    -- | The type of the entire @block + where + then@ expression. @break e@
    -- inside a request handler flows into this variable (skipping the then
    -- clause).
    contextEnclosingHandleBreak :: Maybe TypeVariableId,
    -- | The "resume" type variable for the innermost enclosing request
    -- handler. @next e@ inside a handler body flows into this. There is at
    -- most one in scope: 'NextStatement' is a lexically-scoped construct and
    -- always refers to the innermost handler.
    contextEnclosingHandleNext :: Maybe TypeVariableId,
    -- | Prim constraint-rule lookup, indexed by 'VariableId'. Populated
    -- from 'IdentifierResult.primitiveRulesByVariableId' at the
    -- pipeline entry. Empty for non-prim variables.
    contextPrimRules :: Map VariableId PrimRule
  }

type CG = ReaderT ConstraintContext (State ConstraintState)

initialState :: ConstraintState
initialState =
  ConstraintState
    { stateNextTypeVariableId = 0,
      stateNextRequestVariableId = 0,
      stateTypeEnvironment = Map.empty,
      stateConstraints = Set.empty,
      stateErrors = []
    }

-- | Does the given 'RequestId' point at the stdlib-provided
-- @prim.throw@ request? Used to special-case the universal
-- recoverable-error capability throughout the constraint generator
-- so callers never need a @with throw@ annotation.
isThrowRequestId :: RequestId -> Map RequestId RequestData -> Bool
isThrowRequestId rid requests = case Map.lookup rid requests of
  Just RequestData {requestQualifiedName = QualifiedName {module_, name}} ->
    module_ == "prim" && name == "throw"
  Nothing -> False

initialContext ::
  Map TypeId TypeData ->
  Map RequestId RequestData ->
  Map ConstructorId ConstructorData ->
  Map VariableId PrimRule ->
  ConstraintContext
initialContext types requests constructors primRules =
  ConstraintContext
    { contextIdentifiedTypes = types,
      contextIdentifiedRequests = requests,
      contextIdentifiedConstructors = constructors,
      contextRequestOfVariable =
        Map.fromList
          [ (rd.requestVariableId, rid)
            | (rid, rd) <- Map.toList requests
          ],
      contextSynonymVisited = Set.empty,
      contextEnclosingReturn = Nothing,
      contextEnclosingRequests = Nothing,
      contextEnclosingForBreak = Nothing,
      contextEnclosingHandleBreak = Nothing,
      contextEnclosingHandleNext = Nothing,
      contextPrimRules = primRules
    }

-- ---------------------------------------------------------------------------
-- Helpers: fresh ids, env, constraint emission
-- ---------------------------------------------------------------------------

freshTypeVariableId :: CG TypeVariableId
freshTypeVariableId = lift $ do
  current <- gets (.stateNextTypeVariableId)
  modify $ \state -> state {stateNextTypeVariableId = current + 1}
  pure (TypeVariableId current)

freshTypeVar :: CG (SemanticType Unresolved)
freshTypeVar = SemanticTypeVariable <$> freshTypeVariableId

freshRequestVariableId :: CG RequestVariableId
freshRequestVariableId = lift $ do
  current <- gets (.stateNextRequestVariableId)
  modify $ \state -> state {stateNextRequestVariableId = current + 1}
  pure (RequestVariableId current)

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

addTypeConstraint ::
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  CG ()
addTypeConstraint lhs rhs r = lift . modify $ \s ->
  s {stateConstraints = Set.insert (TypeConstraint lhs rhs r) s.stateConstraints}

-- | Equality is two subtype constraints in opposite directions.
addEqTypeConstraint ::
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  CG ()
addEqTypeConstraint lhs rhs r = do
  addTypeConstraint lhs rhs r
  addTypeConstraint rhs lhs r

addRequestConstraint ::
  SemanticRequest Unresolved ->
  SemanticRequest Unresolved ->
  ConstraintReason ->
  CG ()
addRequestConstraint lhs rhs r = lift . modify $ \s ->
  s {stateConstraints = Set.insert (RequestConstraint lhs rhs r) s.stateConstraints}

-- | Tie a return-type variable to the (possibly fresh) declared return
-- type. Skip the eq when both sides denote the same type variable —
-- 'freshReturnTypeVar' deliberately reuses the inner var when the declared
-- return type already is one, so emitting eq there would just produce two
-- @tv = tv@ no-ops.
addReturnAnnotationEq :: TypeVariableId -> SemanticType Unresolved -> SourceSpan -> CG ()
addReturnAnnotationEq retTvId retSemantic sourceSpan =
  unless (SemanticTypeVariable retTvId == retSemantic) $
    addEqTypeConstraint
      (SemanticTypeVariable retTvId)
      retSemantic
      (ConstraintReason ReasonKindReturnTypeAnnotation sourceSpan)

emitError :: ConstraintError -> CG ()
emitError err = lift . modify $ \state -> state {stateErrors = err : state.stateErrors}

-- ---------------------------------------------------------------------------
-- Reader updates (scope context)
-- ---------------------------------------------------------------------------

withReturn :: TypeVariableId -> CG a -> CG a
withReturn tv = local $ \c -> c {contextEnclosingReturn = Just tv}

withEnclosingRequests :: RequestVariableId -> CG a -> CG a
withEnclosingRequests ev = local $ \c -> c {contextEnclosingRequests = Just ev}

withForLoop :: TypeVariableId -> CG a -> CG a
withForLoop breakTv = local $ \c -> c {contextEnclosingForBreak = Just breakTv}

-- | Set up the handler-scope context. @resultTv@ is the type of the entire
-- @block + where + then@ expression (where 'break' flows). @nextTv@ is the
-- "resume" type for the innermost handler (where 'next' flows).
withHandleScope :: TypeVariableId -> TypeVariableId -> CG a -> CG a
withHandleScope resultTv nextTv = local $ \c ->
  c {contextEnclosingHandleBreak = Just resultTv, contextEnclosingHandleNext = Just nextTv}

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
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withRequests} -> do
    parameterEntries <- mapM (\(label, pt) -> (,) label <$> elaborateType pt) parameterTypes
    returnSemantic <- elaborateType returnType
    requests <- elaborateRequestList withRequests
    pure (SemanticTypeFunction (Map.fromList parameterEntries) returnSemantic requests)
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
  TypeRecord RecordTypeNode {keyType, valueType} ->
    SemanticTypeRecord <$> elaborateType keyType <*> elaborateType valueType

-- | Map a 'PrimitiveTypeKind' to the matching 'SemanticType' constructor.
primitiveToSemantic :: PrimitiveTypeKind -> SemanticType phase
primitiveToSemantic = \case
  PrimitiveTypeKindNull -> SemanticTypeNull
  PrimitiveTypeKindInteger -> SemanticTypeInteger
  PrimitiveTypeKindNumber -> SemanticTypeNumber
  PrimitiveTypeKindString -> SemanticTypeString
  PrimitiveTypeKindSecret -> SemanticTypeSecret
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
  -- 'LiteralValueAgent' is created only by Lowering when resolving a
  -- top-level callable as a value; it must never appear in an AST
  -- literal node, so the typechecker should never see it.
  -- An ill-formed AST that smuggles in 'LiteralValueAgent' here is a
  -- compiler bug, not user error. Returning 'Unknown' lets the
  -- surrounding constraint set still be solved (= the LSP keeps
  -- working) instead of crashing the entire process.
  LiteralValueAgent _ -> SemanticTypeUnknown

-- | Resolve a TypeRef' name to its semantic counterpart, expanding
-- synonyms on the fly with cycle detection.
resolveTypeRef :: NameRef Identified TypeRef -> CG (SemanticType Unresolved)
resolveTypeRef nameRef = case nameRef.resolution of
  Just tid -> do
    types <- asks (.contextIdentifiedTypes)
    case Map.lookup tid types of
      Just TypeData {typeSynonymRhs = Just rhs} -> do
        visited <- asks (.contextSynonymVisited)
        if Set.member tid visited
          then do
            emitError (ConstraintErrorTypeSynonymCycle nameRef.sourceSpan tid)
            freshTypeVar
          else withSynonymVisit tid (elaborateType rhs)
      Just TypeData {typeSynonymRhs = Nothing} ->
        pure (SemanticTypeData tid)
      Nothing ->
        -- Identifier should have populated all entries; fall back defensively.
        freshTypeVar
  Nothing -> freshTypeVar

-- | Elaborate a list of @with@-clause request references into a single
-- request set (concrete VariableIds; request type variables come into play
-- only for inference, not for explicit annotations).
elaborateRequestList :: [SyntacticRequest Identified] -> CG (SemanticRequest Unresolved)
elaborateRequestList requests = do
  pure
    ( SemanticRequest
        ( Set.fromList
            [ SemanticRequestElementConcrete requestId
              | SyntacticRequest {name = NameRef {resolution = Just requestId}} <- requests
            ]
        )
    )

-- | Optional @with@ clause — present only on agent / req-handler type-context
-- declarations. @Nothing@ means "no annotation"; the caller decides whether
-- to allocate a fresh request variable in that case.
elaborateOptionalRequests :: Maybe [SyntacticRequest Identified] -> CG (Maybe (SemanticRequest Unresolved))
elaborateOptionalRequests = traverse elaborateRequestList

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
  DeclarationPrimAgent decl -> DeclarationPrimAgent <$> walkPrimAgentDecl decl
  DeclarationData decl -> DeclarationData <$> walkDataDecl decl
  DeclarationTypeSynonym decl -> DeclarationTypeSynonym <$> walkTypeSynonymDecl decl
  DeclarationImport decl -> pure (DeclarationImport decl)
  DeclarationError span_ -> pure (DeclarationError span_)

-- ---------------------------------------------------------------------------
-- Agent declaration
-- ---------------------------------------------------------------------------

walkAgentDecl :: AgentDeclaration Identified -> CG (AgentDeclaration Constrained)
walkAgentDecl AgentDeclaration {annotation, name, parameters, returnType, withRequests, body, sourceSpan} = do
  (parameters', body') <- processAgentLike sourceSpan name parameters returnType withRequests body
  pure
    AgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        withRequests = fmap (fmap retagSyntacticRequest) withRequests,
        body = body',
        sourceSpan = sourceSpan
      }

-- | Shared body for @agent@ declarations and statements. Allocates the
-- declared / body request variables, walks the body under the appropriate
-- @return@ context, and emits the signature-equality and request-bound
-- constraints. Returns the rebuilt parameter list and body block.
processAgentLike ::
  SourceSpan ->
  NameRef Identified VariableRef ->
  [ParameterBinding Identified] ->
  Maybe (SyntacticType Identified) ->
  Maybe [SyntacticRequest Identified] ->
  Block Identified ->
  CG ([ParameterBinding Constrained], Block Constrained)
processAgentLike sourceSpan name parameters returnType withRequests body = do
  tFoo <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateOrFresh returnType
  declaredRequest <- maybe (singletonRequestVariable <$> freshRequestVariableId) pure =<< elaborateOptionalRequests withRequests
  bodyRequestVariableId <- freshRequestVariableId
  retTvId <- freshReturnTypeVar retSemantic
  (body', bodyType) <-
    withReturn retTvId . withEnclosingRequests bodyRequestVariableId $ walkBlock body
  addTypeConstraint bodyType (SemanticTypeVariable retTvId) (ConstraintReason ReasonKindImplicitReturn sourceSpan)
  addReturnAnnotationEq retTvId retSemantic sourceSpan
  addRequestConstraint
    (singletonRequestVariable bodyRequestVariableId)
    declaredRequest
    (ConstraintReason ReasonKindRequestBound sourceSpan)
  let signature = SemanticTypeFunction paramSig retSemantic declaredRequest
  addEqTypeConstraint signature tFoo (ConstraintReason ReasonKindAgentSignature sourceSpan)
  pure (parameters', body')

walkRequestDecl :: RequestDeclaration Identified -> CG (RequestDeclaration Constrained)
walkRequestDecl RequestDeclaration {annotation, name, requestName, parameters, returnType, sourceSpan} = do
  tReq <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateType returnType
  -- The request's signature includes itself in its request set (a @req foo@
  -- raises @foo@). Identifier issued a 'RequestId' alongside the call-side
  -- 'VariableId' for this declaration; we translate via 'contextRequestOfVariable'.
  reqId <- case variableIdOfName name of
    Nothing -> pure Nothing
    Just vid -> asks (Map.lookup vid . (.contextRequestOfVariable))
  -- Special-case: `throw` is the universal recoverable-error capability.
  -- Its signature carries an *empty* request set so callers never need to
  -- write `with throw` — every agent can raise it implicitly. Handlers
  -- still catch it through the regular `req throw(msg) { ... }` form
  -- because the RequestId is unchanged; we only suppress the effect-set
  -- contribution at the signature level.
  isThrow <- case reqId of
    Just rid -> asks (isThrowRequestId rid . (.contextIdentifiedRequests))
    Nothing -> pure False
  let signatureEff =
        if isThrow
          then emptyRequest
          else maybe emptyRequest singletonRequest reqId
      signature = SemanticTypeFunction paramSig retSemantic signatureEff
  addEqTypeConstraint signature tReq (ConstraintReason ReasonKindRequestSignature sourceSpan)
  pure
    RequestDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        requestName = retagNameRef requestName,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        sourceSpan = sourceSpan
      }

walkExternalAgentDecl :: ExternalAgentDeclaration Identified -> CG (ExternalAgentDeclaration Constrained)
walkExternalAgentDecl ExternalAgentDeclaration {annotation, name, parameters, returnType, withRequests, endpoint, dispatchName, sourceSpan} = do
  tExt <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateType returnType
  requests <- elaborateRequestList withRequests
  let signature = SemanticTypeFunction paramSig retSemantic requests
  addEqTypeConstraint signature tExt (ConstraintReason ReasonKindExternalAgentSignature sourceSpan)
  pure
    ExternalAgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        withRequests = fmap retagSyntacticRequest withRequests,
        endpoint = endpoint,
        dispatchName = dispatchName,
        sourceSpan = sourceSpan
      }

walkPrimAgentDecl :: PrimAgentDeclaration Identified -> CG (PrimAgentDeclaration Constrained)
walkPrimAgentDecl PrimAgentDeclaration {annotation, name, parameters, returnType, withRequests, using, sourceSpan} = do
  tPrim <- variableTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateType returnType
  requests <- elaborateRequestList withRequests
  let signature = SemanticTypeFunction paramSig retSemantic requests
  addEqTypeConstraint signature tPrim (ConstraintReason ReasonKindExternalAgentSignature sourceSpan)
  pure
    PrimAgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        withRequests = fmap retagSyntacticRequest withRequests,
        using = using,
        sourceSpan = sourceSpan
      }

walkDataDecl :: DataDeclaration Identified -> CG (DataDeclaration Constrained)
walkDataDecl DataDeclaration {annotation, name, typeName, constructorName, parameters, sourceSpan} = do
  tCtor <- variableTypeFromName name
  -- The TypeId of a data declaration is held directly by the AST. Only on
  -- the @Unresolved@ side (parse / identify errors) is it @Nothing@, in
  -- which case we fall back to @SemanticTypeUnknown@.
  let tid = typeName.resolution
  fields <- mapM elaborateDataParameter parameters
  let signature =
        SemanticTypeFunction
          (Map.fromList fields)
          (maybe SemanticTypeUnknown SemanticTypeData tid)
          emptyRequest
  addEqTypeConstraint signature tCtor (ConstraintReason ReasonKindDataConstructorSignature sourceSpan)
  parameters' <- mapM walkDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        typeName = retagNameRef typeName,
        constructorName = retagNameRef constructorName,
        parameters = parameters',
        sourceSpan = sourceSpan
      }

walkTypeSynonymDecl :: TypeSynonymDeclaration Identified -> CG (TypeSynonymDeclaration Constrained)
walkTypeSynonymDecl TypeSynonymDeclaration {name, rhs, sourceSpan} =
  pure
    TypeSynonymDeclaration
      { name = retagNameRef name,
        rhs = retagSyntacticType rhs,
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
        parameterType = retagSyntacticType parameterType,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Parameters / patterns
-- ---------------------------------------------------------------------------

-- | Walk a parameter list, returning the rebuilt 'ParameterBinding' list and
-- a 'Map' from parameter label to inferred type, ready to drop into a
-- 'SemanticTypeFunction' signature.
walkParameterListForSignature ::
  [ParameterBinding Identified] ->
  CG ([ParameterBinding Constrained], Map Text (SemanticType Unresolved))
walkParameterListForSignature parameters = do
  let walkOne ParameterBinding {annotation, label, pattern, sourceSpan} = do
        (pattern', patternType) <- walkPattern Nothing pattern
        let rebuilt =
              ParameterBinding
                { annotation = annotation,
                  label = label,
                  pattern = pattern',
                  sourceSpan = sourceSpan
                }
        pure (rebuilt, (label, patternType))
  rebuilt <- mapM walkOne parameters
  pure (map fst rebuilt, Map.fromList (map snd rebuilt))

-- | Walk a 'Pattern', returning the rebuilt Constrained pattern and its
-- inferred type (as a 'SemanticType' Unresolved). Variable bindings are
-- registered in the type environment as a side effect.
--
-- 'maybeSubject': when 'Just subject', the subject type is the type of the
-- value being matched against this pattern at this position. Variable
-- patterns emit @subject <: varType@ so the binding captures the full
-- range of values the subject can carry. Tuple patterns project the subject
-- into component subjects and recurse. Pass 'Nothing' for irrefutable
-- contexts (let / for / parameter) where the caller adds its own bridge
-- constraint after the fact.
walkPattern ::
  Maybe (SemanticType Unresolved) ->
  Pattern Identified ->
  CG (Pattern Constrained, SemanticType Unresolved)
walkPattern maybeSubject = \case
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan} -> do
    -- When a subject is supplied (= a refutable pattern position like a
    -- match arm or a destructured tuple element), the binding's type IS
    -- the subject's type. Rebind the variable to point directly at the
    -- subject so any downstream reference (e.g. inside the arm body)
    -- propagates to the subject's concrete type instead of stranding
    -- the original fresh type var with only a phantom @subject \<:
    -- tv@ link that bound-aggregation can't resolve through type-var
    -- indirection. Without a subject (= an irrefutable let / parameter
    -- pattern), fall back to the variable's pre-allocated fresh tv;
    -- the caller is expected to bridge from outside.
    tx <- case maybeSubject of
      Just subject -> do
        case name.resolution of
          Just vid -> bindVariable vid subject
          Nothing -> pure ()
        pure subject
      Nothing -> variableTypeFromName name
    case typeAnnotation of
      Just t -> do
        annotated <- elaborateType t
        addEqTypeConstraint tx annotated (ConstraintReason ReasonKindVariablePatternAnnotation sourceSpan)
      Nothing -> pure ()
    pure
      ( PatternVariable
          VariablePattern
            { name = retagNameRef name,
              typeAnnotation = fmap retagSyntacticType typeAnnotation,
              sourceSpan = sourceSpan,
              typeOf = tx
            },
        tx
      )
  PatternWildcard WildcardPattern {typeAnnotation, sourceSpan} -> do
    patternType <- maybe freshTypeVar elaborateType typeAnnotation
    pure
      ( PatternWildcard
          WildcardPattern
            { typeAnnotation = fmap retagSyntacticType typeAnnotation,
              sourceSpan = sourceSpan,
              typeOf = patternType
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
              typeOf = patternType
            },
        patternType
      )
  PatternTuple TuplePattern {elements, sourceSpan} -> do
    componentSubjects <- case maybeSubject of
      Just subject -> projectTupleSubjectTypesLinked (length elements) subject sourceSpan
      Nothing -> replicateM (length elements) freshTypeVar
    pairs <- mapM (\(cs, el) -> walkPattern (Just cs) el) (zip componentSubjects elements)
    let patternType = SemanticTypeTuple (map snd pairs)
    pure
      ( PatternTuple
          TuplePattern
            { elements = map fst pairs,
              sourceSpan = sourceSpan,
              typeOf = patternType
            },
        patternType
      )
  PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier, constructorName, parameters, sourceSpan} -> do
    -- "reverse call": pretend the pattern constructs a value via the ctor,
    -- and constrain the synthesised function type to be a subtype of the
    -- ctor's known function type. Field-typed sub-patterns flow into place
    -- via the function-subtype rule (parameter-contravariant).
    tCtor <- constructorTypeFromName constructorName
    paramPairs <- mapM walkPatternField parameters
    let argSig = Map.fromList (map snd paramPairs)
        parameters' = map fst paramPairs
    patternResult <- freshTypeVar
    let synthesised =
          SemanticTypeFunction argSig patternResult emptyRequest
    addTypeConstraint synthesised tCtor (ConstraintReason ReasonKindConstructorPattern sourceSpan)
    pure
      ( PatternQualifiedConstructor
          QualifiedConstructorPattern
            { moduleQualifier = fmap retagNameRef moduleQualifier,
              constructorName = retagNameRef constructorName,
              parameters = parameters',
              sourceSpan = sourceSpan,
              typeOf = patternResult
            },
        patternResult
      )
  where
    walkPatternField (label, sub) = do
      (sub', subType) <- walkPattern Nothing sub
      pure ((retagNameRef label, sub'), (label.text, subType))

-- | Project the component subject types from a subject type for a tuple
-- pattern of the given arity. For union subjects, only the tuple-shaped
-- branches with the right arity are considered; their components are
-- unioned position-wise. For type variables or non-tuple concretes a fresh
-- type variable is used per slot (no useful static information available).
projectTupleSubjectTypes ::
  Int ->
  SemanticType Unresolved ->
  SourceSpan ->
  CG [SemanticType Unresolved]
projectTupleSubjectTypes arity subjectType _sourceSpan = case subjectType of
  SemanticTypeTuple ts
    | length ts == arity -> pure ts
    | otherwise -> replicateM arity freshTypeVar
  SemanticTypeUnion branches ->
    let tupleBranches = [ts | SemanticTypeTuple ts <- branches, length ts == arity]
     in if null tupleBranches
          then replicateM arity freshTypeVar
          else pure (map unionSemantic (transpose tupleBranches))
  SemanticTypeUnknown -> pure (replicate arity SemanticTypeUnknown)
  _ -> replicateM arity freshTypeVar

-- | Like 'projectTupleSubjectTypes', but for cases where the subject
-- is still a type variable (or otherwise unknown shape): generates
-- fresh component type variables AND emits a flow constraint
-- @SemanticTypeTuple [tv1, ..., tvN] \<: subject@ so propagation can
-- push the subject's actual component types down into the patterns.
--
-- Without this link, pattern-bound variables under a tuple pattern
-- end up with no concrete bound and zonk to 'SemanticTypeUnknown',
-- which leaks into hover / completion as a useless display.
projectTupleSubjectTypesLinked ::
  Int ->
  SemanticType Unresolved ->
  SourceSpan ->
  CG [SemanticType Unresolved]
projectTupleSubjectTypesLinked arity subjectType sourceSpan = case subjectType of
  SemanticTypeTuple ts
    | length ts == arity -> pure ts
  SemanticTypeUnion branches
    | not (null [ts | SemanticTypeTuple ts <- branches, length ts == arity]) ->
        projectTupleSubjectTypes arity subjectType sourceSpan
  SemanticTypeUnknown -> pure (replicate arity SemanticTypeUnknown)
  _ -> do
    -- Subject is a type variable or an unrelated shape. Fall back to
    -- fresh component vars, but also emit a bridging constraint so
    -- propagation can flow the subject's eventual tuple components
    -- back into each fresh component var.
    fresh <- replicateM arity freshTypeVar
    addTypeConstraint
      (SemanticTypeTuple fresh)
      subjectType
      (ConstraintReason ReasonKindMatchArm sourceSpan)
    pure fresh

-- ---------------------------------------------------------------------------
-- Block walking (with where-block request discharge)
-- ---------------------------------------------------------------------------

-- | Read the inferred type out of a 'Constrained' expression. Reads the
-- @typeOf@ field directly via the 'ExpressionType Constrained = SemanticType Unresolved'
-- type-family equation.
constrainedExpressionType :: Expression Constrained -> SemanticType Unresolved
constrainedExpressionType = \case
  ExpressionLiteral LiteralExpression {typeOf} -> typeOf
  ExpressionVariable VariableExpression {typeOf} -> typeOf
  ExpressionTuple TupleExpression {typeOf} -> typeOf
  ExpressionArray ArrayExpression {typeOf} -> typeOf
  ExpressionCall CallExpression {typeOf} -> typeOf
  ExpressionBinaryOperator BinaryOperatorExpression {typeOf} -> typeOf
  ExpressionUnaryOperator UnaryOperatorExpression {typeOf} -> typeOf
  ExpressionIf IfExpression {typeOf} -> typeOf
  ExpressionMatch MatchExpression {typeOf} -> typeOf
  ExpressionFor ForExpression {typeOf} -> typeOf
  ExpressionBlock BlockExpression {typeOf} -> typeOf
  ExpressionHandle HandleExpression {typeOf} -> typeOf
  ExpressionParTuple ParTupleExpression {typeOf} -> typeOf
  ExpressionParArray ParArrayExpression {typeOf} -> typeOf
  ExpressionFieldAccess FieldAccessExpression {typeOf} -> typeOf
  ExpressionIndexAccess IndexAccessExpression {typeOf} -> typeOf
  ExpressionTemplate TemplateExpression {typeOf} -> typeOf
  ExpressionQualifiedReference QualifiedReferenceExpression {typeOf} -> typeOf

-- | Walk a block, returning the rebuilt @Constrained@ block and the
-- 'SemanticType' of the block as a whole.
--
-- The type is the tail-expression type (or 'SemanticTypeNull' if the block
-- has no tail expression). No fresh request variables are allocated — the
-- body walks under the enclosing request context directly.
walkBlock :: Block Identified -> CG (Block Constrained, SemanticType Unresolved)
walkBlock Block {statements, returnExpression, sourceSpan} = do
  (statements', returnExpression') <- walkBlockBody statements returnExpression
  let bodyTy = blockTailType statements returnExpression'
  pure
    ( Block
        { statements = statements',
          returnExpression = returnExpression',
          sourceSpan = sourceSpan
        },
      bodyTy
    )

-- | A block's overall type. If any statement is a global-exit
-- (@return@ / @next@ / @break@ / @for_break@ / @for_next@), control never
-- reaches the tail expression, so the block's type is 'SemanticTypeNever'.
-- Otherwise, the type is the tail expression's type, or 'SemanticTypeNull'
-- when there is no tail expression.
--
-- Note: @statements@ is the /pre-walk/ @Identified@ list. This is intentional
-- — 'isExitStatement' only inspects the constructor tag and is phase-agnostic,
-- so the walked @Constrained@ list would give the same result. Passing the
-- original avoids threading @statements'@ through every caller.
blockTailType ::
  [Statement Identified] ->
  Maybe (Expression Constrained) ->
  SemanticType Unresolved
blockTailType statements returnExpression
  | any isExitStatement statements = SemanticTypeNever
  | otherwise = maybe SemanticTypeNull constrainedExpressionType returnExpression

-- | True for statements that transfer control out of the enclosing block,
-- so anything sequenced after them is unreachable.
isExitStatement :: Statement phase -> Bool
isExitStatement = \case
  StatementReturn _ -> True
  StatementNext _ -> True
  StatementBreak _ -> True
  StatementForNext _ -> True
  StatementForBreak _ -> True
  _ -> False

walkBlockBody ::
  [Statement Identified] ->
  Maybe (Expression Identified) ->
  CG ([Statement Constrained], Maybe (Expression Constrained))
walkBlockBody statements returnExpression = do
  statements' <- mapM walkStatement statements
  returnExpression' <- traverse walkExpression returnExpression
  pure (statements', returnExpression')

walkStateVariable :: StateVariableBinding Identified -> CG (StateVariableBinding Constrained)
walkStateVariable StateVariableBinding {name, typeAnnotation, initial, sourceSpan} = do
  initial' <- emitInitializerConstraints (ConstraintReason ReasonKindStateVarAnnotation sourceSpan) name typeAnnotation initial
  pure
    StateVariableBinding
      { name = retagNameRef name,
        typeAnnotation = fmap retagSyntacticType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

-- | Shared logic for variable bindings that have an optional type annotation
-- and a required initializer expression: equate the variable's type with
-- the annotation (if present), and constrain the initializer's type to be
-- a subtype of the variable's type. Used by both 'walkStateVariable' and
-- 'walkForVarBinding' — they pick a context-specific 'ConstraintReason'.
emitInitializerConstraints ::
  ConstraintReason ->
  NameRef Identified VariableRef ->
  Maybe (SyntacticType Identified) ->
  Expression Identified ->
  CG (Expression Constrained)
emitInitializerConstraints r name typeAnnotation initial = do
  tVar <- variableTypeFromName name
  case typeAnnotation of
    Just t -> do
      annotated <- elaborateType t
      addEqTypeConstraint tVar annotated r
    Nothing -> pure ()
  initial' <- walkExpression initial
  addTypeConstraint (constrainedExpressionType initial') tVar r
  pure initial'

walkRequestHandler ::
  RequestVariableId ->
  TypeVariableId ->
  RequestHandler Identified ->
  CG (RequestHandler Constrained)
walkRequestHandler handlerBodyRequestVariable wholeBlockId RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  tHandled <- requestTypeFromName name
  (parameters', paramSig) <- walkParameterListForSignature parameters
  retSemantic <- elaborateOrFresh returnType
  retTvId <- freshReturnTypeVar retSemantic
  -- Handler's signature carries the handled request as its sole request, so
  -- the underlying req's signature is a supertype.
  let handlerReqId = name.resolution
  -- Handler body walks under e4 (the dedicated handler-request var) and the
  -- handle scope. 'next e' resumes the original request call, so 'e' is
  -- constrained against retTvId (= the next-tv); 'break e' targets
  -- wholeBlockTypeVariable (handle-scope result). 'return' inside a handler body
  -- targets the enclosing scope (typically the outer agent's return), not
  -- the handler — we do not override 'withReturn' here.
  --
  -- A request handler body must end with @break@ or @next@: its inferred
  -- type is constrained to be 'SemanticTypeNever'. Falling through to a
  -- value is a type error (used to be an implicit-break). Explicit @next@
  -- statements are still constrained by the declared @return@ type via
  -- 'withHandleScope'.
  (body', bodyTy) <-
    withEnclosingRequests handlerBodyRequestVariable . withHandleScope wholeBlockId retTvId $ walkBlock body
  addTypeConstraint bodyTy SemanticTypeNever (ConstraintReason ReasonKindRequestHandlerNever sourceSpan)
  addReturnAnnotationEq retTvId retSemantic sourceSpan
  let handlerSignature =
        SemanticTypeFunction
          paramSig
          retSemantic
          (maybe emptyRequest singletonRequest handlerReqId)
  -- subtype only (handler is a re-assignment of the underlying req)
  addTypeConstraint handlerSignature tHandled (ConstraintReason ReasonKindRequestHandlerSignature sourceSpan)
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
  let valueType = constrainedExpressionType value'
  (pattern', patternType) <- walkPattern Nothing pattern
  addTypeConstraint valueType patternType (ConstraintReason ReasonKindLetPattern sourceSpan)
  pure LetStatement {pattern = pattern', value = value', sourceSpan = sourceSpan}

walkAgentStatement :: AgentStatement Identified -> CG (AgentStatement Constrained)
walkAgentStatement AgentStatement {annotation, name, parameters, returnType, withRequests, body, sourceSpan} = do
  (parameters', body') <- processAgentLike sourceSpan name parameters returnType withRequests body
  pure
    AgentStatement
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        withRequests = fmap (fmap retagSyntacticRequest) withRequests,
        body = body',
        sourceSpan = sourceSpan
      }

walkReturn :: ReturnStatement Identified -> CG (ReturnStatement Constrained)
walkReturn ReturnStatement {value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = constrainedExpressionType value'
  retContext <- asks (.contextEnclosingReturn)
  case retContext of
    Just rt -> addTypeConstraint valueType (SemanticTypeVariable rt) (ConstraintReason ReasonKindReturnStatement sourceSpan)
    Nothing -> pure () -- not inside an agent; parser/identifier already errored
  pure ReturnStatement {value = value', sourceSpan = sourceSpan}

walkNext :: NextStatement Identified -> CG (NextStatement Constrained)
walkNext NextStatement {value, modifiers, sourceSpan} = do
  value' <- walkExpression value
  let valueType = constrainedExpressionType value'
  modifiers' <- mapM walkModifier modifiers
  -- Tie the resume value to the innermost enclosing handler's next-tv.
  nextContext <- asks (.contextEnclosingHandleNext)
  case nextContext of
    Just tv -> addTypeConstraint valueType (SemanticTypeVariable tv) (ConstraintReason ReasonKindHandleNext sourceSpan)
    Nothing -> pure () -- not inside a handler; identifier/parser already errored
  pure NextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}

walkBreak :: BreakStatement Identified -> CG (BreakStatement Constrained)
walkBreak BreakStatement {value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = constrainedExpressionType value'
  resultContext <- asks (.contextEnclosingHandleBreak)
  case resultContext of
    Just rt -> addTypeConstraint valueType (SemanticTypeVariable rt) (ConstraintReason ReasonKindHandleBreak sourceSpan)
    Nothing -> pure () -- not inside a where block; parser/identifier already errored
  pure BreakStatement {value = value', sourceSpan = sourceSpan}

walkForNext :: ForNextStatement Identified -> CG (ForNextStatement Constrained)
walkForNext ForNextStatement {modifiers, sourceSpan} = do
  modifiers' <- mapM walkModifier modifiers
  -- 'next' (no value) just continues the loop; modifiers are the only
  -- semantic carriers. For-body iteration values aren't observable.
  pure ForNextStatement {modifiers = modifiers', sourceSpan = sourceSpan}

walkForBreak :: ForBreakStatement Identified -> CG (ForBreakStatement Constrained)
walkForBreak ForBreakStatement {value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = constrainedExpressionType value'
  breakContext <- asks (.contextEnclosingForBreak)
  case breakContext of
    Just bv -> addTypeConstraint valueType (SemanticTypeVariable bv) (ConstraintReason ReasonKindForBreak sourceSpan)
    Nothing -> pure () -- not inside a for loop; parser/identifier already errored
  pure ForBreakStatement {value = value', sourceSpan = sourceSpan}

walkModifier :: Modifier Identified -> CG (Modifier Constrained)
walkModifier Modifier {name, value, sourceSpan} = do
  value' <- walkExpression value
  let valueType = constrainedExpressionType value'
  tVar <- variableTypeFromName name
  addTypeConstraint valueType tVar (ConstraintReason ReasonKindModifierUpdate sourceSpan)
  pure Modifier {name = retagNameRef name, value = value', sourceSpan = sourceSpan}

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
  ExpressionHandle expr -> walkHandleExpr expr
  ExpressionParTuple expr -> walkParTupleExpr expr
  ExpressionParArray expr -> walkParArrayExpr expr
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
            typeOf = semantic
          }
    )

walkVariableExpr :: VariableExpression Identified -> CG (Expression Constrained)
walkVariableExpr VariableExpression {name, sourceSpan} = do
  semantic <- variableTypeFromName name
  pure
    ( ExpressionVariable
        VariableExpression
          { name = retagNameRef name,
            sourceSpan = sourceSpan,
            typeOf = semantic
          }
    )

walkTupleExpr :: TupleExpression Identified -> CG (Expression Constrained)
walkTupleExpr TupleExpression {elements, sourceSpan} = do
  elements' <- mapM walkExpression elements
  let semantic = SemanticTypeTuple (map constrainedExpressionType elements')
  pure
    ( ExpressionTuple
        TupleExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            typeOf = semantic
          }
    )

walkArrayExpr :: ArrayExpression Identified -> CG (Expression Constrained)
walkArrayExpr ArrayExpression {elements, sourceSpan} = do
  elements' <- mapM walkExpression elements
  tElem <- freshTypeVar
  mapM_
    ( \e ->
        addTypeConstraint
          (constrainedExpressionType e)
          tElem
          (ConstraintReason ReasonKindArrayElement sourceSpan)
    )
    elements'
  pure
    ( ExpressionArray
        ArrayExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            typeOf = SemanticTypeArray tElem
          }
    )

walkCallExpr :: CallExpression Identified -> CG (Expression Constrained)
walkCallExpr CallExpression {callee, arguments, sourceSpan} = do
  callee' <- walkExpression callee
  arguments' <- mapM walkCallArgument arguments
  -- Identifier desugars operators into calls whose callee is a prim
  -- VariableExpression. Detect that here and route through the
  -- prim-specific constraint rule instead of the generic call path,
  -- so subtype-flavoured operator typing (e.g. @1 + 2 : Integer@) is
  -- preserved.
  primRule <- case callee' of
    ExpressionVariable VariableExpression {name = NameRef {resolution = Just vid}} ->
      asks (Map.lookup vid . (.contextPrimRules))
    _ -> pure Nothing
  resultType <- case primRule of
    Just rule | rule /= PrimRuleSimple -> applyPrimRule rule arguments' sourceSpan
    _ -> applyNormalCall callee' arguments' sourceSpan
  pure
    ( ExpressionCall
        CallExpression
          { callee = callee',
            arguments = arguments',
            sourceSpan = sourceSpan,
            typeOf = resultType
          }
    )

-- | Generic call constraint emission. Used when the callee is not a
-- prim, or when the prim uses 'PrimRuleSimple' (in which case the prim's
-- signature is pinned by 'bindPrimitiveTypes' and the standard call
-- subtype constraint is sufficient).
applyNormalCall ::
  Expression Constrained ->
  [CallArgument Constrained] ->
  SourceSpan ->
  CG (SemanticType Unresolved)
applyNormalCall callee' arguments' sourceSpan = do
  let calleeType = constrainedExpressionType callee'
      argSig =
        Map.fromList
          [ (label.text, constrainedExpressionType value')
            | CallArgument {label, value = value'} <- arguments'
          ]
  tResult <- freshTypeVar
  enclosing <- asks (.contextEnclosingRequests)
  let calleeEff = maybe emptyRequest singletonRequestVariable enclosing
      expected = SemanticTypeFunction argSig tResult calleeEff
  addTypeConstraint calleeType expected (ConstraintReason ReasonKindCallArgument sourceSpan)
  pure tResult

-- | Emit operand-aware constraints at a prim call site for the two
-- arithmetic rules that can't be expressed as a plain function
-- signature. All other prims (incl. @eq@ / @lt@ / @get_metadata@ / etc.)
-- take the standard 'applyNormalCall' path keyed on the declared
-- 'PrimAgentDeclaration' signature.
applyPrimRule ::
  PrimRule ->
  [CallArgument Constrained] ->
  SourceSpan ->
  CG (SemanticType Unresolved)
applyPrimRule rule arguments sourceSpan =
  let bag =
        Map.fromList
          [ (label.text, constrainedExpressionType value')
            | CallArgument {label, value = value'} <- arguments
          ]
      lhs = Map.findWithDefault SemanticTypeUnknown "lhs" bag
      rhs = Map.findWithDefault SemanticTypeUnknown "rhs" bag
      value_ = Map.findWithDefault SemanticTypeUnknown "value" bag
      reasonBin = ConstraintReason ReasonKindBinaryOperator sourceSpan
      reasonUn = ConstraintReason ReasonKindUnaryOperator sourceSpan
   in case rule of
        PrimRuleNumericJoinBinary -> do
          -- result >: lhs ∪ rhs ∪ integer. integer + integer → integer,
          -- otherwise number. Used by add / sub / mul / mod.
          resultType <- freshTypeVar
          addTypeConstraint lhs SemanticTypeNumber reasonBin
          addTypeConstraint rhs SemanticTypeNumber reasonBin
          addTypeConstraint lhs resultType reasonBin
          addTypeConstraint rhs resultType reasonBin
          addTypeConstraint SemanticTypeInteger resultType reasonBin
          pure resultType
        PrimRuleNumericJoinUnary -> do
          -- result >: value ∪ integer. Unary analogue used by abs.
          resultType <- freshTypeVar
          addTypeConstraint value_ SemanticTypeNumber reasonUn
          addTypeConstraint value_ resultType reasonUn
          addTypeConstraint SemanticTypeInteger resultType reasonUn
          pure resultType
        PrimRuleFstringJoin -> do
          -- Every argument must be string or secret; result is the
          -- supremum (sup) of the argument types. Concretely:
          --   format("hi")            : string
          --   format(some_secret)     : secret
          --   concat("a", "b")        : string
          --   concat("a", secret_v)   : secret
          -- Used by @format@ / @concat@ for taint-aware f-string and
          -- @++@ behaviour.
          let reason = ConstraintReason ReasonKindCallArgument sourceSpan
              stringOrSecret =
                SemanticTypeUnion [SemanticTypeString, SemanticTypeSecret]
          resultType <- freshTypeVar
          mapM_
            ( \CallArgument {value = value'} -> do
                let argType = constrainedExpressionType value'
                addTypeConstraint argType stringOrSecret reason
                addTypeConstraint argType resultType reason
            )
            arguments
          pure resultType
        PrimRuleSimple ->
          -- Caller filters PrimRuleSimple before invoking applyPrimRule.
          pure SemanticTypeUnknown

walkCallArgument :: CallArgument Identified -> CG (CallArgument Constrained)
walkCallArgument CallArgument {label, value, sourceSpan} = do
  value' <- walkExpression value
  pure
    CallArgument
      { label = retagNameRef label,
        value = value',
        sourceSpan = sourceSpan
      }

-- | The Identifier pass desugars 'ExpressionBinaryOperator' /
-- 'ExpressionUnaryOperator' into 'ExpressionCall' against the matching
-- prim. Reaching this walker means an upstream invariant was violated
-- (likely a phase-retag bug); surface as K9999.
walkBinaryExpr :: BinaryOperatorExpression Identified -> CG (Expression Constrained)
walkBinaryExpr BinaryOperatorExpression {sourceSpan} = do
  emitInternalError sourceSpan "ConstraintGenerator: BinaryOperator survived past Identifier desugar"
  pure
    ( ExpressionLiteral
        LiteralExpression
          { value = LiteralValueNull,
            sourceSpan = sourceSpan,
            typeOf = SemanticTypeNull
          }
    )

walkUnaryExpr :: UnaryOperatorExpression Identified -> CG (Expression Constrained)
walkUnaryExpr UnaryOperatorExpression {sourceSpan} = do
  emitInternalError sourceSpan "ConstraintGenerator: UnaryOperator survived past Identifier desugar"
  pure
    ( ExpressionLiteral
        LiteralExpression
          { value = LiteralValueNull,
            sourceSpan = sourceSpan,
            typeOf = SemanticTypeNull
          }
    )

-- | Surface a compiler-bug Diagnostic as a structural ConstraintError.
-- The constraint generator's existing error type is narrow ('cyclic
-- type synonym' only); for invariant violations we emit a K9999-flavoured
-- 'TypeSynonymCycle' over a sentinel TypeId so the diagnostic at least
-- propagates. Plumbing a richer error variant through is left for a
-- follow-up; the operator-survival case only fires on a real bug.
emitInternalError :: SourceSpan -> Text -> CG ()
emitInternalError sourceSpan _msg =
  emitError (ConstraintErrorTypeSynonymCycle sourceSpan (TypeId (-1)))

walkIfExpr :: IfExpression Identified -> CG (Expression Constrained)
walkIfExpr IfExpression {condition, thenBlock, elseBlock, sourceSpan} = do
  condition' <- walkExpression condition
  let condType = constrainedExpressionType condition'
  addTypeConstraint condType SemanticTypeBoolean (ConstraintReason ReasonKindIfCondition sourceSpan)
  (thenBlock', thenType) <- walkBlock thenBlock
  (elseBlock', elseType) <- case elseBlock of
    Just b -> do
      (b', ty) <- walkBlock b
      pure (Just b', ty)
    Nothing -> pure (Nothing, SemanticTypeNull)
  tResult <- freshTypeVar
  addTypeConstraint thenType tResult (ConstraintReason ReasonKindIfBranch sourceSpan)
  addTypeConstraint elseType tResult (ConstraintReason ReasonKindIfBranch sourceSpan)
  pure
    ( ExpressionIf
        IfExpression
          { condition = condition',
            thenBlock = thenBlock',
            elseBlock = elseBlock',
            sourceSpan = sourceSpan,
            typeOf = tResult
          }
    )

walkMatchExpr :: MatchExpression Identified -> CG (Expression Constrained)
walkMatchExpr MatchExpression {subject, cases, sourceSpan} = do
  subject' <- walkExpression subject
  let subjectType = constrainedExpressionType subject'
  tMatch <- freshTypeVar
  cases' <- mapM (walkCaseArm subjectType tMatch) cases
  pure
    ( ExpressionMatch
        MatchExpression
          { subject = subject',
            cases = cases',
            sourceSpan = sourceSpan,
            typeOf = tMatch
          }
    )

walkCaseArm ::
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  CaseArm Identified ->
  CG (CaseArm Constrained)
walkCaseArm subjectType tMatch CaseArm {pattern, body, sourceSpan} = do
  (pattern', _patternType) <- walkPattern (Just subjectType) pattern
  (body', bodyTy) <- walkBlock body
  addTypeConstraint bodyTy tMatch (ConstraintReason ReasonKindMatchArm sourceSpan)
  pure
    CaseArm
      { pattern = pattern',
        body = body',
        sourceSpan = sourceSpan
      }

walkForExpr :: ForExpression Identified -> CG (Expression Constrained)
walkForExpr ForExpression {parallel, inBindings, varBindings, body, thenBlock, sourceSpan} = do
  -- in-bindings: the source is walked in the outer scope
  inBindings' <- mapM walkForInBinding inBindings
  varBindings' <- mapM walkForVarBinding varBindings
  tForBreakId <- freshTypeVariableId
  -- The body's tail value isn't observable: 'next' just continues the loop
  -- and the for expression's type is decided by break / finally only.
  (body', _bodyTy) <- withForLoop tForBreakId $ walkBlock body
  (thenBlock', thenType) <- case thenBlock of
    Just b -> do
      (b', ty) <- walkBlock b
      pure (Just b', ty)
    Nothing -> pure (Nothing, SemanticTypeNull)
  let resultType =
        unionSemantic [thenType, SemanticTypeVariable tForBreakId]
  pure
    ( ExpressionFor
        ForExpression
          { parallel = parallel,
            inBindings = inBindings',
            varBindings = varBindings',
            body = body',
            thenBlock = thenBlock',
            sourceSpan = sourceSpan,
            typeOf = resultType
          }
    )

walkForInBinding :: ForInBinding Identified -> CG (ForInBinding Constrained)
walkForInBinding ForInBinding {pattern, source, sourceSpan} = do
  source' <- walkExpression source
  let sourceType = constrainedExpressionType source'
  tElem <- freshTypeVar
  addTypeConstraint sourceType (SemanticTypeArray tElem) (ConstraintReason ReasonKindForIn sourceSpan)
  (pattern', patternType) <- walkPattern Nothing pattern
  addTypeConstraint tElem patternType (ConstraintReason ReasonKindForIn sourceSpan)
  pure ForInBinding {pattern = pattern', source = source', sourceSpan = sourceSpan}

walkForVarBinding :: ForVarBinding Identified -> CG (ForVarBinding Constrained)
walkForVarBinding ForVarBinding {name, typeAnnotation, initial, sourceSpan} = do
  initial' <- emitInitializerConstraints (ConstraintReason ReasonKindForVarAnnotation sourceSpan) name typeAnnotation initial
  pure
    ForVarBinding
      { name = retagNameRef name,
        typeAnnotation = fmap retagSyntacticType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkBlockExpr :: BlockExpression Identified -> CG (Expression Constrained)
walkBlockExpr BlockExpression {block, sourceSpan} = do
  (block', semantic) <- walkBlock block
  pure
    ( ExpressionBlock
        BlockExpression
          { block = block',
            sourceSpan = sourceSpan,
            typeOf = semantic
          }
    )

walkHandleExpr :: HandleExpression Identified -> CG (Expression Constrained)
walkHandleExpr HandleExpression {parallel, stateVariables, handlers, thenClause, body, sourceSpan} = do
  enclosingRequestVariable <- asks (.contextEnclosingRequests)
  targetBodyRequestVariable <- freshRequestVariableId
  handlerBodyRequestVariable <- freshRequestVariableId
  wholeBlockId <- freshTypeVariableId
  let wholeBlockTypeVariable = SemanticTypeVariable wholeBlockId

  -- State variables
  stateVariables' <- mapM walkStateVariable stateVariables

  -- Then clause. Its body type flows into the whole expression's type,
  -- joining `break` values (see "Body normal completion" below). Note:
  -- break / return / next from inside the body bypass the @then@ entirely
  -- — they target their outer boundaries directly — so we do NOT route
  -- those exit targets through the @then@ pattern.
  (thenClause', maybePatternType) <- case thenClause of
    Nothing -> pure (Nothing, Nothing)
    Just (maybePattern, thenBody) -> do
      (pattern', patternType) <- case maybePattern of
        Just p -> do
          (p', t) <- walkPattern Nothing p
          pure (Just p', t)
        Nothing -> do
          t <- freshTypeVar
          pure (Nothing, t)
      (thenBody', thenBodyType) <-
        withEnclosingRequests handlerBodyRequestVariable (walkBlock thenBody)
      addTypeConstraint thenBodyType wholeBlockTypeVariable (ConstraintReason ReasonKindThenBodyToWhole sourceSpan)
      pure (Just (pattern', thenBody'), Just patternType)

  -- Body walk (the continuation).
  (body', bodyTy) <- withEnclosingRequests targetBodyRequestVariable (walkBlock body)

  -- Body normal completion
  case maybePatternType of
    Just patTy -> addTypeConstraint bodyTy patTy (ConstraintReason ReasonKindThenPattern sourceSpan)
    Nothing -> addTypeConstraint bodyTy wholeBlockTypeVariable (ConstraintReason ReasonKindHandleResultBody sourceSpan)

  -- Handlers
  handlers' <- mapM (walkRequestHandler handlerBodyRequestVariable wholeBlockId) handlers

  -- Request constraints
  let handledRequestIds =
        Set.fromList
          [ SemanticRequestElementConcrete requestId
            | RequestHandler {name = NameRef {resolution = Just requestId}} <- handlers
          ]
  let enclosingRequest = maybe emptyRequest singletonRequestVariable enclosingRequestVariable
      handledRequest = SemanticRequest handledRequestIds
  addRequestConstraint
    (singletonRequestVariable targetBodyRequestVariable)
    (unionRequests enclosingRequest handledRequest)
    (ConstraintReason ReasonKindHandleRequestDischarge sourceSpan)
  addRequestConstraint
    (singletonRequestVariable handlerBodyRequestVariable)
    enclosingRequest
    (ConstraintReason ReasonKindHandlerRequestBound sourceSpan)

  pure
    ( ExpressionHandle
        HandleExpression
          { parallel = parallel,
            stateVariables = stateVariables',
            handlers = handlers',
            thenClause = thenClause',
            body = body',
            sourceSpan = sourceSpan,
            typeOf = wholeBlockTypeVariable
          }
    )

walkParTupleExpr :: ParTupleExpression Identified -> CG (Expression Constrained)
walkParTupleExpr ParTupleExpression {elements, sourceSpan} = do
  elements' <- mapM walkExpression elements
  let semantic = SemanticTypeTuple (map constrainedExpressionType elements')
  pure
    ( ExpressionParTuple
        ParTupleExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            typeOf = semantic
          }
    )

walkParArrayExpr :: ParArrayExpression Identified -> CG (Expression Constrained)
walkParArrayExpr ParArrayExpression {elements, sourceSpan} = do
  elements' <- mapM walkExpression elements
  tElem <- freshTypeVar
  mapM_
    ( \e ->
        addTypeConstraint
          (constrainedExpressionType e)
          tElem
          (ConstraintReason ReasonKindArrayElement sourceSpan)
    )
    elements'
  pure
    ( ExpressionParArray
        ParArrayExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            typeOf = SemanticTypeArray tElem
          }
    )

walkFieldAccessExpr :: FieldAccessExpression Identified -> CG (Expression Constrained)
walkFieldAccessExpr FieldAccessExpression {object, fieldName, sourceSpan} = do
  object' <- walkExpression object
  let objectType = constrainedExpressionType object'
  tField <- freshTypeVar
  addTypeConstraint
    objectType
    (SemanticTypeObject (Map.singleton fieldName.text tField))
    (ConstraintReason ReasonKindFieldAccess sourceSpan)
  pure
    ( ExpressionFieldAccess
        FieldAccessExpression
          { object = object',
            fieldName = retagNameRef fieldName,
            sourceSpan = sourceSpan,
            typeOf = tField
          }
    )

walkIndexAccessExpr :: IndexAccessExpression Identified -> CG (Expression Constrained)
walkIndexAccessExpr IndexAccessExpression {array, index, sourceSpan} = do
  array' <- walkExpression array
  let arrayType = constrainedExpressionType array'
  index' <- walkExpression index
  let indexType = constrainedExpressionType index'
  tElem <- freshTypeVar
  addTypeConstraint arrayType (SemanticTypeArray tElem) (ConstraintReason ReasonKindIndexAccessArray sourceSpan)
  addTypeConstraint indexType SemanticTypeInteger (ConstraintReason ReasonKindIndexAccessIndex sourceSpan)
  pure
    ( ExpressionIndexAccess
        IndexAccessExpression
          { array = array',
            index = index',
            sourceSpan = sourceSpan,
            typeOf = tElem
          }
    )

walkTemplateExpr :: TemplateExpression Identified -> CG (Expression Constrained)
walkTemplateExpr TemplateExpression {elements, sourceSpan} = do
  elements' <- mapM walkTemplateElement elements
  -- The f-string's overall type is the supremum of its parts.
  -- Plain string segments contribute `string`; embedded expressions
  -- contribute their own type (which must be `string` or `secret`).
  -- If any embedded expression has type `secret`, the result is
  -- `secret` and taint propagates outward; otherwise it stays `string`.
  let reason = ConstraintReason ReasonKindCallArgument sourceSpan
      stringOrSecret =
        SemanticTypeUnion [SemanticTypeString, SemanticTypeSecret]
  resultType <- freshTypeVar
  -- Every f-string contains at least an empty string contribution, so
  -- the result is always at least `string`.
  addTypeConstraint SemanticTypeString resultType reason
  mapM_
    ( \case
        TemplateElementString _ -> pure ()
        TemplateElementExpression TemplateExpressionElement {value = value'} -> do
          let argType = constrainedExpressionType value'
          addTypeConstraint argType stringOrSecret reason
          addTypeConstraint argType resultType reason
    )
    elements'
  pure
    ( ExpressionTemplate
        TemplateExpression
          { elements = elements',
            sourceSpan = sourceSpan,
            typeOf = resultType
          }
    )

walkTemplateElement :: TemplateElement Identified -> CG (TemplateElement Constrained)
walkTemplateElement = \case
  TemplateElementString TemplateStringElement {value, sourceSpan} ->
    pure (TemplateElementString TemplateStringElement {value = value, sourceSpan = sourceSpan})
  TemplateElementExpression TemplateExpressionElement {value, sourceSpan} -> do
    value' <- walkExpression value
    -- Per-element typing constraints are emitted by 'walkTemplateExpr'
    -- (the parent), which has access to the overall result-type
    -- variable. Here we just walk the subexpression.
    pure (TemplateElementExpression TemplateExpressionElement {value = value', sourceSpan = sourceSpan})

walkQualifiedReferenceExpr ::
  QualifiedReferenceExpression Identified ->
  CG (Expression Constrained)
walkQualifiedReferenceExpr QualifiedReferenceExpression {moduleQualifier, target, sourceSpan} = do
  semantic <- variableTypeFromName target
  pure
    ( ExpressionQualifiedReference
        QualifiedReferenceExpression
          { moduleQualifier = retagNameRef moduleQualifier,
            target = retagNameRef target,
            sourceSpan = sourceSpan,
            typeOf = semantic
          }
    )

-- ===========================================================================
-- Small accessors and conveniences
-- ===========================================================================

-- | Look up a variable's type via the @Identified@ name reference.
-- Unresolved references get a fresh type variable (Identifier already
-- reported the original error).
variableTypeFromName :: NameRef Identified VariableRef -> CG (SemanticType Unresolved)
variableTypeFromName nameRef = maybe freshTypeVar lookupVariable nameRef.resolution

variableIdOfName :: NameRef Identified VariableRef -> Maybe VariableId
variableIdOfName nameRef = nameRef.resolution

-- | Type of a 'req' declaration's call-side, looked up via the request id.
-- Each 'RequestId' has a known corresponding 'VariableId'
-- ('requestVariableId'); we read the type out of 'stateTypeEnvironment'
-- through that. Unresolved request references fall back to a fresh type
-- variable (Identifier already reported the failure).
requestTypeFromName :: NameRef Identified RequestRef -> CG (SemanticType Unresolved)
requestTypeFromName nameRef = case nameRef.resolution of
  Nothing -> freshTypeVar
  Just rid -> do
    requestData <- asks (Map.lookup rid . (.contextIdentifiedRequests))
    case requestData of
      Just rd -> lookupVariable rd.requestVariableId
      Nothing -> freshTypeVar

-- | Type of a 'data' declaration's constructor-function side, looked up
-- via the constructor id. Same plumbing as 'requestTypeFromName'.
constructorTypeFromName ::
  NameRef Identified ConstructorRef ->
  CG (SemanticType Unresolved)
constructorTypeFromName nameRef = case nameRef.resolution of
  Nothing -> freshTypeVar
  Just cid -> do
    ctorData <- asks (Map.lookup cid . (.contextIdentifiedConstructors))
    case ctorData of
      Just cd -> lookupVariable cd.constructorVariableId
      Nothing -> freshTypeVar

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
freshReturnTypeVar :: SemanticType Unresolved -> CG TypeVariableId
freshReturnTypeVar = \case
  SemanticTypeVariable tv -> pure tv
  _ -> freshTypeVariableId

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- | Run constraint generation over an 'IdentifierResult' (which may contain
-- multiple modules). All variables across all modules are allocated a type
-- variable in Phase A, then declarations are walked in Phase B to emit
-- constraints and produce the @Constrained@-phase ASTs.
generateConstraints :: IdentifierResult -> (ConstraintGenResult, [ConstraintError])
generateConstraints result = case runState (runReaderT action context) initialState of
  (modulesPair, finalState) ->
    ( ConstraintGenResult
        { constrainedModules = Map.fromList modulesPair,
          typeEnvironment = finalState.stateTypeEnvironment,
          constraints = finalState.stateConstraints,
          variableSupply =
            VariableSupply
              { typeVarSupply = finalState.stateNextTypeVariableId,
                requestVarSupply = finalState.stateNextRequestVariableId
              }
        },
      finalState.stateErrors
    )
  where
    context =
      initialContext
        result.identifiedTypes
        result.identifiedRequests
        result.identifiedConstructors
        primRules
    -- Reconstruct the prim-rule lookup from every 'VariableData' that
    -- the Identifier pass marked with a 'variablePrimRule'.
    primRules =
      Map.fromList
        [ (vid, rule)
          | (vid, vd) <- Map.toList result.identifiedVariables,
            Just rule <- [vd.variablePrimRule]
        ]
    action = do
      allocateAllVariables result
      mapM walkOne (Map.toList result.moduleASTs)
    walkOne (mid, mod') = do
      mod'' <- walkModule mod'
      pure (mid, mod'')
