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
-- 'checkSCC' is the per-SCC entry point that 'Katari.Typechecker' drives in
-- place of the constraint generator + solver + zonker. It also runs effect
-- inference (a per-SCC request fixpoint — 'inferEffects') and checks each
-- agent's body against its declared @with@ clause.
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
    checkSCC,
  )
where

import Control.Monad (forM, forM_, when, zipWithM)
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.List (partition, transpose)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.AST
import Katari.Common (LiteralValue (..), QualifiedName (..), TypePatternTag (..))
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Id (EffectResolution (..), GenericsId, TypeResolution (..), VariableResolution (..))
import Katari.Prim (PrimRule (..))
import Katari.SemanticType
import Katari.SemanticType.Render (renderSemanticType)
import Katari.TypeScheme (TypeScheme (..), monoScheme)
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Typechecker.Identifier (TypeData (..))
import Katari.Typechecker.AgentGraph (declarationDependencies)
import Katari.Typechecker.NormalizedType
  ( BoundEnv,
    DataFieldEnv,
    NormalizedEffect (..),
    buildDataFieldEnv,
    dataParamIdsOf,
    Variance (..),
    variancesOf,
    denormalise,
    denormaliseEffect,
    differenceNormalizedEffect,
    expandGenerics,
    normaliseEffect,
    normaliseSemantic,
    requestArgsInEffect,
    dataArgsInType,
    nullNormalizedEffect,
    subtractConcrete,
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
  | -- | An agent's body raises effects (named here) outside its declared
    -- @with@ clause.
    CheckErrorUndeclaredEffect SourceSpan [Text]
  | -- | A request handler body falls through to a value instead of exiting
    -- with @break@ / @next@.
    CheckErrorHandlerMustExit SourceSpan
  | -- | A @for@ body falls through to a value instead of exiting with
    -- @next@ / @break@ (every iteration must contribute a mapped value via
    -- @next@ or short-circuit via @break@).
    CheckErrorForBodyMustExit SourceSpan
  | -- | A @par for@ uses @var@ loop state, which parallel iterations can't
    -- order deterministically.
    CheckErrorParallelForState SourceSpan
  | -- | A @par for@ uses @break@, which has no well-defined ordering across
    -- concurrent iterations.
    CheckErrorParallelForBreak SourceSpan
  | -- | A call omits a required (non-defaulted) argument.
    CheckErrorMissingArgument SourceSpan Text
  | -- | Field access on a value whose type lacks the named field.
    CheckErrorNoSuchField SourceSpan Text
  | -- | A recursive agent (named here) is missing its mandatory return type.
    CheckErrorRecursiveReturn SourceSpan Text
  | -- | A recursive agent (named here) is missing its mandatory @with@ clause
    -- (use @with pure@ for a recursive agent that raises no requests).
    CheckErrorRecursiveEffect SourceSpan Text
  | -- | A generic callable (named here) was referenced without instantiating
    -- its type parameters (@foo@ instead of @foo[...]@). First-class generics
    -- only: every use site must apply all type arguments.
    CheckErrorMustInstantiate SourceSpan Text
  | -- | A generic application supplied the wrong number of type arguments
    -- (expected, actual).
    CheckErrorTypeArgArity SourceSpan Int Int
  | -- | An effect expression appears where a type is required (e.g. a request
    -- name in a @let@ / parameter annotation, or at a type-parameter position).
    CheckErrorEffectInTypePosition SourceSpan
  | -- | A type expression appears where an effect is required (e.g. at an
    -- effect-parameter position of a generic application).
    CheckErrorTypeInEffectPosition SourceSpan
  | -- | A union mixes type and effect operands.
    CheckErrorMixedTypeEffectUnion SourceSpan
  | -- | A spread parameter (@...obj: T@) is not the sole parameter of its
    -- callable (mixing spread with named params, or multiple spreads, is not
    -- allowed).
    CheckErrorSpreadParameterMustBeSole SourceSpan
  | -- | A spread call argument (@foo(...e)@) is mixed with named arguments.
    CheckErrorSpreadArgumentMustBeSole SourceSpan
  | -- | A @data@ parameter's declared variance (@in@ / @out@) is not satisfied
    -- by its inferred variance (the parameter name and the declared marker).
    CheckErrorVarianceMismatch SourceSpan Text Text
  | -- | A compiler-invariant violation (e.g. a node the Identifier pass should
    -- have eliminated). Should never fire on a well-formed AST.
    CheckErrorInternal SourceSpan Text
  deriving (Show)

-- | Convert a 'CheckError' to a unified 'Diagnostic'. Type-checker codes live
-- in the K0200-K0299 range (alongside 'Katari.Typechecker.Exhaustive's
-- K0290-K0292); internal invariants use K9999.
toDiagnostic :: CheckError -> Diagnostic
toDiagnostic = \case
  CheckErrorTypeSynonymCycle sourceSpan name ->
    diagnosticError "K0200" ("cyclic type synonym '" <> name <> "'") sourceSpan
  CheckErrorTypeMismatch sourceSpan actual expected ->
    diagnosticError
      "K0210"
      ("type mismatch: '" <> renderSemanticType actual <> "' is not a subtype of '" <> renderSemanticType expected <> "'")
      sourceSpan
  CheckErrorUnresolvedVariable sourceSpan name ->
    diagnosticError "K0211" ("unresolved variable '" <> name <> "'") sourceSpan
  CheckErrorUndeclaredEffect sourceSpan effectNames ->
    diagnosticError
      "K0212"
      ("this agent raises effects outside its 'with' clause: " <> Text.intercalate ", " effectNames)
      sourceSpan
  CheckErrorHandlerMustExit sourceSpan ->
    diagnosticError
      "K0213"
      "a request handler must exit with 'break' or 'next' — it cannot fall through to a value"
      sourceSpan
  CheckErrorForBodyMustExit sourceSpan ->
    diagnosticError
      "K0225"
      "a 'for' body must exit with 'next' or 'break' — it cannot fall through to a value"
      sourceSpan
  CheckErrorParallelForState sourceSpan ->
    diagnosticError
      "K0226"
      "a 'par for' cannot use 'var' loop state ('next ... with') — parallel iterations have no deterministic order"
      sourceSpan
  CheckErrorParallelForBreak sourceSpan ->
    diagnosticError
      "K0227"
      "a 'par for' cannot use 'break' — early exit has no well-defined meaning across concurrent iterations"
      sourceSpan
  CheckErrorMissingArgument sourceSpan label ->
    diagnosticError "K0214" ("missing required argument '" <> label <> "'") sourceSpan
  CheckErrorNoSuchField sourceSpan label ->
    diagnosticError "K0215" ("no field '" <> label <> "' on this value") sourceSpan
  CheckErrorRecursiveReturn sourceSpan name ->
    diagnosticError
      "K0216"
      ("recursive agent '" <> name <> "' needs an explicit return type — it can't be inferred through the recursion")
      sourceSpan
  CheckErrorRecursiveEffect sourceSpan name ->
    diagnosticError
      "K0219"
      ("recursive agent '" <> name <> "' needs an explicit 'with' clause — it can't be inferred through the recursion (use 'with pure' if it raises no requests)")
      sourceSpan
  CheckErrorMustInstantiate sourceSpan name ->
    diagnosticError
      "K0217"
      ("generic callable '" <> name <> "' must be instantiated with type arguments (write '" <> name <> "[...]')")
      sourceSpan
  CheckErrorTypeArgArity sourceSpan expected actual ->
    diagnosticError
      "K0218"
      ("wrong number of type arguments: expected " <> Text.pack (show expected) <> ", got " <> Text.pack (show actual))
      sourceSpan
  CheckErrorEffectInTypePosition sourceSpan ->
    diagnosticError "K0220" "an effect can't be used as a type here" sourceSpan
  CheckErrorTypeInEffectPosition sourceSpan ->
    diagnosticError "K0221" "a type can't be used as an effect here" sourceSpan
  CheckErrorMixedTypeEffectUnion sourceSpan ->
    diagnosticError "K0222" "a union can't mix types and effects" sourceSpan
  CheckErrorSpreadParameterMustBeSole sourceSpan ->
    diagnosticError "K0223" "a spread parameter ('...obj: T') must be the only parameter" sourceSpan
  CheckErrorSpreadArgumentMustBeSole sourceSpan ->
    diagnosticError "K0224" "a spread argument ('...e') can't be mixed with named arguments" sourceSpan
  CheckErrorVarianceMismatch sourceSpan name declared ->
    diagnosticError
      "K0228"
      ("type parameter '" <> name <> "' is declared '" <> declared <> "' but is not used that way (its inferred variance is incompatible)")
      sourceSpan
  CheckErrorInternal sourceSpan what ->
    diagnosticError "K9999" ("internal typechecker invariant violated: " <> what) sourceSpan

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
    -- | Local variable /schemes/ — parameters, @let@ bindings, pattern
    -- bindings, state vars (all 'monoScheme'), and the module's own + imported
    -- top-level callable schemes (a generic callable carries its quantifiers
    -- here). Keyed by 'VariableResolution'. A scheme with non-empty quantifiers
    -- marks a generic callable: a bare reference is a \"must instantiate\"
    -- error, and @foo[args]@ substitutes the type arguments into its body.
    checkLocals :: Map VariableResolution TypeScheme,
    -- | Prim rules (operator / array prims whose result type isn't a plain
    -- signature). Keyed by the prim's qualified name.
    checkPrimRules :: Map QualifiedName PrimRule,
    -- | Upper bounds of the generic parameters currently in scope (the
    -- enclosing generic declaration's @extends@ clauses, normalized). Empty
    -- outside a generic body. Consulted by 'subtypeAssert' for bound expansion.
    checkBoundEnv :: BoundEnv,
    -- | The enclosing agent body's declared / expected return type, if any.
    checkExpectedReturn :: Maybe (SemanticType Resolved),
    -- | Inside a request handler body: the type a @next e@ answer must satisfy
    -- (@e : U@ requires @U \<: T@) — the handled request's return type with the
    -- body's instantiation args substituted. 'Nothing' outside a handler.
    checkExpectedNext :: Maybe (SemanticType Resolved)
  }

-- | Where a non-local control transfer goes — used to collect the value types
-- a @for@ / handle expression can produce via @break@ / @next@.
--
-- 'ForNextTag' carries the values a @for@ body emits via @next v@; the
-- surrounding @for@ unions them into the loop's mapped element type
-- (and hence its @array[...]@ output type).
data ExitTag = ForBreakTag | ForNextTag | HandleBreakTag | HandleNextTag
  deriving (Eq, Show)

data ExitRecord = ExitRecord ExitTag (SemanticType Resolved)

data CheckState = CheckState
  { stateErrors :: [CheckError],
    -- | Pending @break@ / @next@ value types, consumed by the nearest
    -- enclosing @for@ / handle scope (see 'collectExits').
    stateExits :: [ExitRecord],
    -- | Every local binding's resolved type, accumulated across all scopes
    -- (not Reader-scoped) so the Query / hover layer can look up any variable.
    stateLocalTypes :: Map VariableResolution (SemanticType Resolved)
  }

type Check = ReaderT CheckEnv (State CheckState)

-- | Run a checker action, returning the result, the diagnostics (in source
-- order), and every local binding's type (for the Query layer).
runCheck :: CheckEnv -> Check a -> (a, [CheckError], Map VariableResolution (SemanticType Resolved))
runCheck env action =
  let (result, finalState) = runState (runReaderT action env) (CheckState [] [] Map.empty)
   in (result, reverse finalState.stateErrors, finalState.stateLocalTypes)

emitError :: CheckError -> Check ()
emitError err = modify' $ \s -> s {stateErrors = err : s.stateErrors}

-- | The scheme a resolution is bound to (generic callables carry quantifiers).
lookupLocal :: VariableResolution -> Check (Maybe TypeScheme)
lookupLocal resolution = asks (Map.lookup resolution . (.checkLocals))

-- | The body type a resolution is bound to (its scheme's body, quantifiers
-- dropped). For the common case where the caller wants the plain type.
lookupLocalType :: VariableResolution -> Check (Maybe (SemanticType Resolved))
lookupLocalType resolution = fmap (.schemeBody) <$> lookupLocal resolution

-- | Extend the local environment with monomorphic bindings (parameters, @let@,
-- pattern, state vars) for the duration of an action, recording them in
-- 'stateLocalTypes' (un-scoped) for the Query layer.
withLocals :: [(VariableResolution, SemanticType Resolved)] -> Check a -> Check a
withLocals bindings = withSchemes [(resolution, monoScheme semanticType) | (resolution, semanticType) <- bindings]

-- | Extend the local environment with full schemes (top-level callable
-- signatures and local generic agents, whose schemes may carry quantifiers).
withSchemes :: [(VariableResolution, TypeScheme)] -> Check a -> Check a
withSchemes bindings action = do
  modify' $ \s -> s {stateLocalTypes = Map.union (Map.fromList [(resolution, scheme.schemeBody) | (resolution, scheme) <- bindings]) s.stateLocalTypes}
  local (\e -> e {checkLocals = Map.union (Map.fromList bindings) e.checkLocals}) action

-- | Set the enclosing agent's expected return type.
withExpectedReturn :: SemanticType Resolved -> Check a -> Check a
withExpectedReturn expected = local (\e -> e {checkExpectedReturn = Just expected})

-- | Extend the generic-bound environment for the duration of an action (used
-- while checking a generic declaration's body, where its parameters are
-- abstract but bounded above by their @extends@ clauses).
withBoundEnv :: BoundEnv -> Check a -> Check a
withBoundEnv boundEnv = local (\e -> e {checkBoundEnv = Map.union boundEnv e.checkBoundEnv})

-- | Build the bound environment for a generic declaration's parameters: each
-- parameter's 'GenericsId' mapped to its normalized @extends@ bound (default
-- @unknown@). A bound may itself mention earlier generics; those normalise to
-- the generics layer and are expanded transitively during subtyping.
buildBoundEnv :: [GenericParameter Identified] -> Check BoundEnv
buildBoundEnv parameters = Map.fromList . catMaybes <$> mapM one parameters
  where
    one GenericParameter {name, upperBound} = case name.resolution of
      Just (ResolvedGenericParam genericsId) -> do
        boundType <- maybe (pure SemanticTypeUnknown) elaborateType upperBound
        dataFieldEnv <- asks (.checkDataFieldEnv)
        pure (Just (genericsId, normaliseSemantic dataFieldEnv boundType))
      _ -> pure Nothing

-- | Gather every generic callable in the module: its 'VariableResolution'
-- mapped to its parameters in declaration order (each parameter's 'GenericsId'
-- + its elaborated @extends@ bound). A non-empty list marks the callable as
-- generic (must be instantiated at use sites). Built once per SCC over the
-- whole module so cross-SCC callers can instantiate.
buildModuleGenericParams ::
  [Declaration Identified] ->
  Check (Map VariableResolution [(GenericsId, GenericKind, SemanticType Resolved)])
buildModuleGenericParams declarations =
  Map.fromList . catMaybes <$> mapM one declarations
  where
    one = \case
      DeclarationAgent decl -> fromParams decl.name decl.typeParameters
      DeclarationData decl -> fromParams decl.name decl.typeParameters
      DeclarationPrimAgent decl -> fromParams decl.name decl.typeParameters
      DeclarationExternalAgent decl -> fromParams decl.name decl.typeParameters
      DeclarationRequest decl -> fromParams decl.name decl.typeParameters
      _ -> pure Nothing
    fromParams _ [] = pure Nothing
    fromParams nameRef typeParameters = case nameRef.resolution of
      Just resolution -> do
        infos <- genericParamInfos typeParameters
        pure (Just (resolution, infos))
      Nothing -> pure Nothing

-- | A generic declaration's parameters in order: each parameter's 'GenericsId',
-- its kind (type / effect), and its elaborated @extends@ bound (default
-- @unknown@). Shared by the module-level pass and local generic agents.
genericParamInfos :: [GenericParameter Identified] -> Check [(GenericsId, GenericKind, SemanticType Resolved)]
genericParamInfos = fmap catMaybes . mapM paramInfo
  where
    paramInfo GenericParameter {name, kind, upperBound} = case name.resolution of
      Just (ResolvedGenericParam genericsId) -> do
        boundType <- maybe (pure SemanticTypeUnknown) elaborateType upperBound
        pure (Just (genericsId, kind, boundType))
      _ -> pure Nothing

-- | The variable a callee resolves to, if it is a plain name / qualified
-- reference (the only shapes that can name a generic callable).
calleeResolution :: Expression Identified -> Maybe VariableResolution
calleeResolution = \case
  ExpressionVariable variable -> variable.name.resolution
  ExpressionQualifiedReference reference -> reference.target.resolution
  _ -> Nothing

-- | The generic parameters of the callable a reference resolves to (empty for
-- a monomorphic callable / a non-callable).
genericParamsOf :: Maybe VariableResolution -> Check [(GenericsId, GenericKind, SemanticType Resolved)]
genericParamsOf = \case
  Just resolution -> maybe [] (.schemeQuantifiers) <$> lookupLocal resolution
  Nothing -> pure []

-- | Rebuild a generic application's callee as a zonked node carrying the
-- instantiated (concrete) type, bypassing the bare-reference \"must
-- instantiate\" check (this IS the instantiation).
retagGenericCallee :: Expression Identified -> SemanticType Resolved -> Check (Expression Zonked)
retagGenericCallee callee concreteType = case callee of
  ExpressionVariable VariableExpression {name, sourceSpan} ->
    pure (ExpressionVariable VariableExpression {name = retagNameRef name, sourceSpan = sourceSpan, typeOf = concreteType})
  ExpressionQualifiedReference QualifiedReferenceExpression {moduleQualifier, target, sourceSpan} ->
    pure
      ( ExpressionQualifiedReference
          QualifiedReferenceExpression {moduleQualifier = retagNameRef moduleQualifier, target = retagNameRef target, sourceSpan = sourceSpan, typeOf = concreteType}
      )
  _ -> fst <$> synthExpr callee

-- | Record a pending exit value (a @break@ / @next@ payload) for the nearest
-- enclosing scope to collect.
recordExit :: ExitTag -> SemanticType Resolved -> Check ()
recordExit tag semantic = modify' $ \s -> s {stateExits = ExitRecord tag semantic : s.stateExits}

-- | Run an action, then peel off the matched exit /records/ (tags kept) that it
-- recorded, so a scope consuming several tags can treat them differently — e.g.
-- a @for@ scope consumes both its @break@ and @next@ exits (so neither leaks to
-- an outer scope) but they feed its result type differently. Non-matching exits
-- are left in place so they propagate to an outer scope (a @break@ inside a
-- nested @for@ targets an enclosing handle, etc.).
collectExitsTagged :: [ExitTag] -> Check a -> Check (a, [ExitRecord])
collectExitsTagged tags action = do
  before <- gets (.stateExits)
  result <- action
  after <- gets (.stateExits)
  let added = take (length after - length before) after
      (matching, rest) = foldr partition ([], []) added
      partition record (yes, no) =
        let ExitRecord tag _ = record
         in if tag `elem` tags then (record : yes, no) else (yes, record : no)
  modify' $ \s -> s {stateExits = rest ++ before}
  pure (result, matching)

-- ===========================================================================
-- Type elaboration (SyntacticType Identified -> SemanticType Resolved)
-- ===========================================================================

-- | Elaborate a syntactic type into a resolved semantic type, expanding type
-- synonyms transparently (cycles surface as a diagnostic).
-- | The meaning of an elaborated syntactic-type expression: it denotes either
-- a /type/ or an /effect/. Most syntactic positions want one specific kind
-- (a @let@ annotation wants a type, a generic application's effect-parameter
-- position wants an effect); a request name elaborates to an effect, so it is
-- rejected wherever a type is required. The bracket arguments of a generic
-- application are the one position that accepts either, dispatched by the
-- callee's declared parameter kinds.
data TypeOrEffect
  = AsType (SemanticType Resolved)
  | AsEffect (SemanticEffect Resolved)

-- | Assert an elaboration denotes a type (the common case); an effect here is a
-- kind error, recovered as @unknown@.
expectType :: SourceSpan -> TypeOrEffect -> Check (SemanticType Resolved)
expectType _ (AsType semanticType) = pure semanticType
expectType sourceSpan (AsEffect _) = do
  emitError (CheckErrorEffectInTypePosition sourceSpan)
  pure SemanticTypeUnknown

-- | Assert an elaboration denotes an effect; a type here is a kind error,
-- recovered as the pure effect.
expectEffect :: SourceSpan -> TypeOrEffect -> Check (SemanticEffect Resolved)
expectEffect _ (AsEffect effect) = pure effect
expectEffect sourceSpan (AsType _) = do
  emitError (CheckErrorTypeInEffectPosition sourceSpan)
  pure emptyEffect

-- | Elaborate a syntactic type, asserting it denotes a type. The wrapper used
-- by almost every caller (parameter / return / @let@ annotations, bounds,
-- nested type positions) — an effect in any of these is a kind error.
elaborateType :: SyntacticType Identified -> Check (SemanticType Resolved)
elaborateType syntacticType =
  elaborateTypeOrEffect syntacticType >>= expectType (sourceSpanOf syntacticType)

-- | Elaborate one type-application argument: a type becomes a type argument; a
-- name resolving to an effect (a @req@) becomes an effect argument. The kind is
-- decided by the argument's own resolution (no need to consult the parameter).
elaborateGenericArgument :: SyntacticType Identified -> Check (SemanticGenericArgument Resolved)
elaborateGenericArgument argument =
  elaborateTypeOrEffect argument >>= \case
    AsType semanticType -> pure (SemanticGenericArgumentType semanticType)
    AsEffect semanticEffect -> pure (SemanticGenericArgumentEffect semanticEffect)

-- | Elaborate a syntactic type into a type /or/ an effect. A bare request name
-- (only reachable via the Identifier's effect-namespace fallback) denotes an
-- effect; a union is all-type or all-effect (mixing them is an error); every
-- other shape (array, tuple, function, record, object) is a type whose nested
-- positions are themselves required to be types.
elaborateTypeOrEffect :: SyntacticType Identified -> Check TypeOrEffect
elaborateTypeOrEffect = \case
  TypePrimitive PrimitiveTypeNode {kind} -> pure (AsType (primitiveToSemantic kind))
  TypeName TypeNameNode {name} -> resolveTypeRef name
  TypeQualified QualifiedTypeNode {target} -> resolveTypeRef target
  TypeFunction FunctionTypeNode {parameterTypes, spreadParameter, returnType, withRequests} -> do
    returnSemantic <- elaborateType returnType
    requests <- elaborateRequestList withRequests
    -- @agent(...T) -> R@: the parameter type is @T@ directly; otherwise it is
    -- the object built from the labelled parameter types.
    parameterSemantic <- case spreadParameter of
      Just spreadType -> elaborateType spreadType
      Nothing -> do
        parameterEntries <- mapM (\(label, pt) -> (,) label <$> elaborateType pt) parameterTypes
        pure (SemanticTypeObject (requiredParameter <$> Map.fromList parameterEntries))
    pure (AsType (SemanticTypeFunction parameterSemantic returnSemantic requests))
  TypeArray ArrayTypeNode {sourceSpan} -> do
    -- A bare @array@ (never applied) is incomplete: it must be @array[T]@.
    emitError (CheckErrorMustInstantiate sourceSpan "array")
    pure (AsType SemanticTypeUnknown)
  TypeApplication TypeApplicationTypeNode {applicationHead, applicationArguments, sourceSpan} ->
    case applicationHead of
      -- @array[T]@ — a built-in type constructor.
      TypeArray _ -> case applicationArguments of
        [elementType] -> AsType . SemanticTypeArray <$> elaborateType elementType
        _ -> do
          emitError (CheckErrorTypeArgArity sourceSpan 1 (length applicationArguments))
          pure (AsType SemanticTypeUnknown)
      -- @record[V]@ — the homogeneous map applied to its value type.
      TypeRecord _ -> case applicationArguments of
        [valueType] -> AsType . SemanticTypeRecord <$> elaborateType valueType
        _ -> do
          emitError (CheckErrorTypeArgArity sourceSpan 1 (length applicationArguments))
          pure (AsType SemanticTypeUnknown)
      -- @data foo[args]@ — a generic data applied to type / effect arguments.
      _ ->
        elaborateType applicationHead >>= \case
          SemanticTypeData qualifiedName [] -> do
            dataFieldEnv <- asks (.checkDataFieldEnv)
            arguments <- mapM elaborateGenericArgument applicationArguments
            let parameterCount = length (dataParamIdsOf dataFieldEnv qualifiedName)
            when (parameterCount /= length arguments) $
              emitError (CheckErrorTypeArgArity sourceSpan parameterCount (length arguments))
            pure (AsType (SemanticTypeData qualifiedName arguments))
          _ -> do
            emitError (CheckErrorInternal sourceSpan "type application of a non-generic type")
            pure (AsType SemanticTypeUnknown)
  TypeTuple TupleTypeNode {elementTypes} ->
    AsType . SemanticTypeTuple <$> mapM elaborateType elementTypes
  TypeUnion TypeUnionNode {branches, sourceSpan} -> do
    elaborated <- mapM elaborateTypeOrEffect branches
    let types = [t | AsType t <- elaborated]
        effects = [e | AsEffect e <- elaborated]
    case (types, effects) of
      (_, []) -> pure (AsType (unionSemantic types))
      ([], _) -> pure (AsEffect (unionEffects effects))
      _ -> do
        emitError (CheckErrorMixedTypeEffectUnion sourceSpan)
        pure (AsType (unionSemantic types))
  TypeLiteral TypeLiteralNode {value} -> pure (AsType (literalValueToSemantic value))
  TypeNever _ -> pure (AsType SemanticTypeNever)
  TypeUnknown _ -> pure (AsType SemanticTypeUnknown)
  TypeFunctionAny _ -> pure (AsType SemanticTypeFunctionAny)
  TypeRecord _ -> pure (AsType (SemanticTypeRecord SemanticTypeUnknown))
  TypeObject ObjectTypeNode {fields} ->
    -- An optional field @l?: T@ widens to @null | T@ (an absent / null value is
    -- admissible), mirroring the @x ?: T@ parameter desugaring.
    AsType . SemanticTypeObject . Map.fromList
      <$> mapM
        ( \(label, fieldSyntactic, isOptional) -> do
            elaborated <- elaborateType fieldSyntactic
            let fieldType = if isOptional then unionSemantic [SemanticTypeNull, elaborated] else elaborated
            pure (label, Parameter fieldType isOptional)
        )
        fields

resolveTypeRef :: NameRef Identified TypeRef -> Check TypeOrEffect
resolveTypeRef nameRef = case nameRef.resolution of
  Just (ResolvedNamedType qualifiedName) -> do
    types <- asks (.checkTypeData)
    case Map.lookup qualifiedName types of
      Just TypeData {typeSynonymRhs = Just rhs} -> do
        visited <- asks (.checkSynonymVisited)
        if Set.member qualifiedName visited
          then do
            emitError (CheckErrorTypeSynonymCycle nameRef.sourceSpan qualifiedName.name)
            pure (AsType SemanticTypeUnknown)
          else local (\e -> e {checkSynonymVisited = Set.insert qualifiedName e.checkSynonymVisited}) (elaborateTypeOrEffect rhs)
      Just TypeData {typeSynonymRhs = Nothing} ->
        -- A bare data name (no @[...]@). Generic data applied to explicit args
        -- comes through 'TypeApplication' (Phase 1); here the arg list is empty.
        pure (AsType (SemanticTypeData qualifiedName []))
      Nothing ->
        pure (AsType SemanticTypeUnknown)
  Just (ResolvedGenericParam genericsId) -> pure (AsType (SemanticTypeGeneric genericsId))
  -- A request / effect-generic name reaches a type position only via the
  -- Identifier's effect-namespace fallback (an effect argument of a generic
  -- application). Both denote effects; 'expectType' rejects them in an ordinary
  -- type position.
  Just (ResolvedRequestName qualifiedName) -> pure (AsEffect (SemanticEffectRequest qualifiedName []))
  Just (ResolvedEffectGenericName genericsId) -> pure (AsEffect (SemanticEffectGeneric genericsId))
  Just ResolvedPureEffect -> pure (AsEffect SemanticEffectPure)
  Just ResolvedAllEffectName -> pure (AsEffect SemanticEffectAll)
  Nothing -> pure (AsType SemanticTypeUnknown)

-- | Elaborate a @with@ clause into a concrete request set (only names that are
-- known requests contribute).
elaborateRequestList :: [SyntacticRequest Identified] -> Check (SemanticEffect Resolved)
elaborateRequestList syntacticRequests = case partition (.spread) syntacticRequests of
  -- No spread: an ordinary union of the request leaves.
  ([], _) -> unionEffects . catMaybes <$> mapM elaborateOne syntacticRequests
  -- Override row @{...base, req, …}@: the spreads form the base, the rest are the
  -- concrete overrides that shadow their names in the base.
  (spreads, overrides) -> do
    base <- unionEffects . catMaybes <$> mapM elaborateOne spreads
    overrideEffects <- catMaybes <$> mapM elaborateOne overrides
    pure (SemanticEffectOverride base overrideEffects)
  where
    elaborateOne SyntacticRequest {name, arguments} = case name.resolution of
      Just (ResolvedConcreteRequest qualifiedName) -> do
        arguments' <- mapM elaborateGenericArgument arguments
        pure (Just (SemanticEffectRequest qualifiedName arguments'))
      Just (ResolvedEffectGeneric genericsId) -> pure (Just (SemanticEffectGeneric genericsId))
      Just ResolvedAllEffect -> pure (Just SemanticEffectAll)
      Nothing -> pure Nothing

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
subtypeAssert sourceSpan actual expected
  -- 'unknown' as the EXPECTED type is the top: @actual <: unknown@ always holds,
  -- so skip (also suppresses cascades when a prior error left @expected@
  -- unknown). 'unknown' as the ACTUAL type is NOT skipped: @unknown <: T@ for a
  -- narrower @T@ must fail (unknown is a real top, not an `any` escape hatch) —
  -- a value of unknown type must be narrowed (e.g. via @match@) before use.
  | isUnknown expected = pure ()
  | otherwise = do
      dataFieldEnv <- asks (.checkDataFieldEnv)
      boundEnv <- asks (.checkBoundEnv)
      let holds = subtypeNormalizedType dataFieldEnv boundEnv (normaliseSemantic dataFieldEnv actual) (normaliseSemantic dataFieldEnv expected)
      if holds then pure () else emitError (CheckErrorTypeMismatch sourceSpan actual expected)
  where
    isUnknown = \case SemanticTypeUnknown -> True; _ -> False

-- ===========================================================================
-- Expression checking
-- ===========================================================================

-- | Check an expression against an expected type: synthesise it, then assert
-- the synthesised type is a subtype of the expectation.
checkExpr :: Expression Identified -> SemanticType Resolved -> Check (Expression Zonked)
checkExpr expression expected = case (expression, expected) of
  -- A `{ k = v }` literal denotes an object by default, but an object and a
  -- `record[V]` are incomparable; when the expected type IS a `record[V]`, the
  -- literal elaborates AS that record (each value checked against V). So the
  -- same syntax builds an object or a record, decided by the expected type.
  (ExpressionRecord RecordExpression {entries, sourceSpan}, SemanticTypeRecord valueType) -> do
    walked <- mapM (\(label, valueExpression) -> (,) label <$> checkExpr valueExpression valueType) entries
    pure (ExpressionRecord RecordExpression {entries = walked, sourceSpan = sourceSpan, typeOf = SemanticTypeRecord valueType})
  _ -> do
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
    semantic <- referenceType sourceSpan name.text name.resolution
    pure (ExpressionVariable VariableExpression {name = retagNameRef name, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionQualifiedReference QualifiedReferenceExpression {moduleQualifier, target, sourceSpan} -> do
    semantic <- referenceType sourceSpan target.text target.resolution
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
    let semantic = SemanticTypeObject (Map.fromList [(label, requiredParameter (snd we)) | (label, we) <- walked])
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
  ExpressionTypeApplication typeApp -> synthGenericApplication typeApp
  ExpressionTemplate TemplateExpression {elements, sourceSpan} -> do
    walked <- mapM walkTemplateElement elements
    let interpolated = mapMaybe snd walked
    let semantic = unionSemantic (SemanticTypeString : interpolated)
    pure (ExpressionTemplate TemplateExpression {elements = map fst walked, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionBinaryOperator BinaryOperatorExpression {sourceSpan} -> internalNull sourceSpan "BinaryOperator survived past the Identifier desugar"
  ExpressionUnaryOperator UnaryOperatorExpression {sourceSpan} -> internalNull sourceSpan "UnaryOperator survived past the Identifier desugar"

-- | Look up a variable / top-level callable reference's type. An unresolved
-- reference (Identifier already reported it as an undefined name) yields
-- @unknown@ silently — re-reporting it here would duplicate the diagnostic.
-- Downstream uses of that @unknown@ recovery value may now cascade a subtype
-- error (since @unknown@ is a sound top, not an @any@), which is acceptable:
-- the root cause (the undefined name) is already reported.
lookupVariableType :: SourceSpan -> Text -> Maybe VariableResolution -> Check (SemanticType Resolved)
lookupVariableType _ _ = \case
  Just resolution -> maybe SemanticTypeUnknown id <$> lookupLocalType resolution
  Nothing -> pure SemanticTypeUnknown

-- | The type of a value reference, rejecting a bare reference to a generic
-- callable (which must be instantiated as @foo[...]@ — the application case
-- handles that separately and never reaches here).
referenceType :: SourceSpan -> Text -> Maybe VariableResolution -> Check (SemanticType Resolved)
referenceType sourceSpan text resolution = do
  params <- genericParamsOf resolution
  if null params
    then lookupVariableType sourceSpan text resolution
    else do
      emitError (CheckErrorMustInstantiate sourceSpan text)
      pure SemanticTypeUnknown

-- | A form that the Identifier pass should have eliminated — record an
-- internal-invariant diagnostic and yield a @null@ placeholder.
internalNull :: SourceSpan -> Text -> Check (Expression Zonked, SemanticType Resolved)
internalNull sourceSpan reason = do
  emitError (CheckErrorInternal sourceSpan reason)
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
synthCall CallExpression {callee, arguments, spreadArgument, sourceSpan} = do
  (callee', calleeType) <- synthExpr callee
  case spreadArgument of
    -- Spread call @foo(...e)@: the single argument value is @e@; require its
    -- type to be a subtype of the callee's parameter type. (Prim result rules
    -- don't apply — prims are called with named args.)
    Just spreadExpr -> do
      (spreadExpr', spreadType) <- synthExpr spreadExpr
      result <- applySpreadCall sourceSpan calleeType spreadType
      pure
        ( ExpressionCall CallExpression {callee = callee', arguments = [], spreadArgument = Just spreadExpr', sourceSpan = sourceSpan, typeOf = result},
          result
        )
    Nothing -> do
      walkedArgs <- mapM (\callArgument -> walkCallArgument (calleeParamType calleeType callArgument.label.text) callArgument) arguments
      let arguments' = map fst walkedArgs
          argTypes = Map.fromList [(label, argType) | (_, (label, argType)) <- walkedArgs]
      primRule <- calleePrimRule callee
      result <- case primRule of
        Just rule | rule /= PrimRuleSimple -> applyPrimRule rule argTypes sourceSpan
        _ -> applyNormalCall sourceSpan calleeType argTypes
      pure (ExpressionCall CallExpression {callee = callee', arguments = arguments', spreadArgument = Nothing, sourceSpan = sourceSpan, typeOf = result}, result)

-- | Spread call: the whole argument value (@spreadType@) must be a subtype of
-- the callee's parameter type; the result is the callee's return type.
applySpreadCall :: SourceSpan -> SemanticType Resolved -> SemanticType Resolved -> Check (SemanticType Resolved)
applySpreadCall sourceSpan calleeType spreadType = case calleeType of
  SemanticTypeFunction parameterType returnType _ -> do
    subtypeAssert sourceSpan spreadType parameterType
    pure returnType
  SemanticTypeFunctionAny -> pure SemanticTypeUnknown
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  _ -> do
    emitError (CheckErrorTypeMismatch sourceSpan calleeType SemanticTypeFunctionAny)
    pure SemanticTypeUnknown

-- | Synthesise a generic application @callee[T1, ...]@: look up the callee's
-- generic parameters, elaborate the type arguments, check each against its
-- bound, and substitute them into the callee's signature to get a concrete
-- type. A non-generic callee with type arguments is an arity error.
synthGenericApplication :: TypeApplicationExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthGenericApplication TypeApplicationExpression {callee, typeArguments, sourceSpan} = do
  let resolution = calleeResolution callee
  params <- genericParamsOf resolution
  if null params
    then do
      (callee', calleeType) <- synthExpr callee
      if null typeArguments
        then pure ()
        else emitError (CheckErrorTypeArgArity sourceSpan 0 (length typeArguments))
      pure (rebuilt callee' calleeType ([], []), calleeType)
    else do
      if length typeArguments == length params
        then pure ()
        else emitError (CheckErrorTypeArgArity sourceSpan (length params) (length typeArguments))
      -- Process each (parameter, argument) pair by the parameter's kind: a type
      -- parameter elaborates its argument as a type (checked against its bound),
      -- an effect parameter elaborates it as an effect.
      substitutions <- zipWithM (applyTypeArgument sourceSpan) params typeArguments
      let typeSubstitution = Map.fromList [(genericsId, argType) | Left (genericsId, argType) <- substitutions]
          effectSubstitution = Map.fromList [(genericsId, argEffect) | Right (genericsId, argEffect) <- substitutions]
      calleeSig <- maybe (pure SemanticTypeUnknown) (fmap (maybe SemanticTypeUnknown id) . lookupLocalType) resolution
      let concreteType = substituteGenerics typeSubstitution effectSubstitution calleeSig
      calleeZonked <- retagGenericCallee callee concreteType
      pure (rebuilt calleeZonked concreteType (Map.toList typeSubstitution, Map.toList effectSubstitution), concreteType)
  where
    rebuilt calleeZonked resultType instantiation =
      ExpressionTypeApplication
        TypeApplicationExpression
          { callee = calleeZonked,
            typeArguments = map retagSyntacticType typeArguments,
            instantiation = instantiation,
            sourceSpan = sourceSpan,
            typeOf = resultType
          }

-- | Elaborate one generic argument according to its parameter's kind: a type
-- parameter ('Left') checks the argument against its bound; an effect parameter
-- ('Right') reinterprets the argument (a request-name expression) as an effect.
applyTypeArgument ::
  SourceSpan ->
  (GenericsId, GenericKind, SemanticType Resolved) ->
  SyntacticType Identified ->
  Check (Either (GenericsId, SemanticType Resolved) (GenericsId, SemanticEffect Resolved))
applyTypeArgument sourceSpan (genericsId, kind, bound) argument = case kind of
  GenericKindType -> do
    argType <- elaborateType argument
    subtypeAssert sourceSpan argType bound
    pure (Left (genericsId, argType))
  GenericKindEffect -> do
    argEffect <- elaborateTypeOrEffect argument >>= expectEffect (sourceSpanOf argument)
    pure (Right (genericsId, argEffect))

-- | The callee's declared type for parameter @label@ (used to flow an expected
-- type into the argument, e.g. so a @{ k = v }@ literal checks as a @record[V]@).
calleeParamType :: SemanticType Resolved -> Text -> Maybe (SemanticType Resolved)
calleeParamType calleeType label = case calleeType of
  SemanticTypeFunction (SemanticTypeObject fields) _ _ -> (.parameterType) <$> Map.lookup label fields
  _ -> Nothing

walkCallArgument :: Maybe (SemanticType Resolved) -> CallArgument Identified -> Check (CallArgument Zonked, (Text, SemanticType Resolved))
walkCallArgument expectedParam CallArgument {label, value, sourceSpan} = do
  -- A record literal flows its expected @record[V]@ in (bidirectional), so it
  -- elaborates AS a record; everything else is synthesised bottom-up.
  (value', valueType) <- case (value, expectedParam) of
    (ExpressionRecord _, Just expected@(SemanticTypeRecord _)) -> do
      zonked <- checkExpr value expected
      pure (zonked, expected)
    _ -> synthExpr value
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
  SemanticTypeFunction parameterType returnType _ -> do
    -- A call @foo(l1 = e1, l2 = e2)@ builds the argument object
    -- @{l1: τ1, l2: τ2}@ and requires it to be a subtype of the callee's
    -- parameter type. For the common case where the parameter type is an
    -- object (named parameters) we walk it field-by-field to give precise
    -- missing-argument / per-argument-mismatch diagnostics; any extra named
    -- argument is silently allowed (width subtyping). For a non-object
    -- parameter type (only via a spread signature) we fall back to a single
    -- structural subtype assertion of the whole argument object.
    case parameterType of
      SemanticTypeObject params ->
        forM_ (Map.toList params) $ \(label, parameter) ->
          case Map.lookup label argTypes of
            Just argType -> subtypeAssert sourceSpan argType parameter.parameterType
            Nothing
              | parameter.optional -> pure ()
              | otherwise -> emitError (CheckErrorMissingArgument sourceSpan label)
      _ ->
        subtypeAssert sourceSpan (SemanticTypeObject (requiredParameter <$> argTypes)) parameterType
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
        PrimRuleRecordGet -> pure (recordValueType (arg "record"))
        PrimRuleRecordSet ->
          let existing = recordValueType (arg "record")
              added = maybe [] pure (Map.lookup "value" argTypes)
           in pure (SemanticTypeRecord (unionSemantic (existing : added)))
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

-- | A @for@ collects each iteration's @next v@ into an ordered array (its
-- mapped output). The element type is the union of the body's @next@ values;
-- the output type is @array[that]@, post-processed by the optional @then@
-- clause (which binds the mapped array) and unioned with any @break@ values.
-- The body must transfer control on every path (like a request handler).
synthFor :: ForExpression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthFor ForExpression {parallel, inBindings, varBindings, body, thenBlock, sourceSpan} = do
  (inBindings', inLocals) <- unzipBindings <$> mapM walkForInBinding inBindings
  (varBindings', varLocals) <- unzipBindings <$> mapM walkForVarBinding varBindings
  let loopLocals = inLocals ++ varLocals
  -- Walk the body, peeling off its @break@ values (ForBreakTag) and its mapped
  -- @next@ values (ForNextTag). Both tags are consumed here so neither leaks to
  -- an enclosing scope.
  ((body', bodyType), bodyExits) <-
    collectExitsTagged [ForBreakTag, ForNextTag] $
      withLocals loopLocals (walkBlock body)
  assertMustExit (sourceSpanOf body) bodyType CheckErrorForBodyMustExit
  let breakTypes = [semantic | ExitRecord ForBreakTag semantic <- bodyExits]
      nextTypes = [semantic | ExitRecord ForNextTag semantic <- bodyExits]
      mappedArray = SemanticTypeArray (unionSemantic nextTypes)
  -- @par for@ restrictions: parallel iterations cannot carry ordered loop state
  -- or short-circuit via break.
  when (parallel && not (null varBindings)) $
    emitError (CheckErrorParallelForState sourceSpan)
  when (parallel && not (null breakTypes)) $
    emitError (CheckErrorParallelForBreak sourceSpan)
  -- The @then@ clause shares the loop's frame (sees state vars) and binds the
  -- mapped array via its optional pattern.
  (thenBlock', thenType) <- withLocals loopLocals $ case thenBlock of
    Nothing -> pure (Nothing, Nothing)
    Just (maybePattern, thenBody) -> do
      (pattern', bindings) <- case maybePattern of
        Just p -> do (p', bs) <- walkPattern mappedArray p; pure (Just p', bs)
        Nothing -> pure (Nothing, [])
      (thenBody', thenBodyType) <- withLocals bindings (walkBlock thenBody)
      pure (Just (pattern', thenBody'), Just thenBodyType)
  let semantic = unionSemantic (breakTypes ++ [maybe mappedArray id thenType])
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
  -- Consume both the handle scope's @break@ and @next@ exits (so neither leaks
  -- to an outer scope), but only @break@ values feed the scope's result type:
  -- @next v@ resumes the asker with @v@, it does not make the scope evaluate to
  -- @v@ (mirrors how a @for@ scope's value is its breaks ∪ then, not its nexts).
  ((body', bodyType, handlers', thenClause', thenType), exitRecords) <-
    collectExitsTagged [HandleBreakTag, HandleNextTag] $
      withLocals stateLocals $ do
        (body', bodyType) <- walkBlock body
        -- Re-derive the body's fired effect (from the zonked body's stamped
        -- types) so each handler can be checked against the request's return
        -- type at the instantiation the body actually raises.
        dataFieldEnv <- asks (.checkDataFieldEnv)
        -- Local types (incl. this SCC's seeded recursive siblings) take
        -- precedence over the reader env (imports + earlier SCCs), so a request
        -- raised via a same-SCC sibling is still seen here (its effect is
        -- declared — recursive agents must annotate `with`).
        seededTypes <- gets (.stateLocalTypes)
        readerBodies <- asks (Map.map (.schemeBody) . (.checkLocals))
        let localBodies = Map.union seededTypes readerBodies
            lookupEff qualifiedName = effectOfSignature dataFieldEnv (Map.findWithDefault SemanticTypeUnknown (ResolvedTopLevel qualifiedName) localBodies)
            bodyEffect = blockEffect dataFieldEnv lookupEff body'
        handlers' <-
          mapM
            ( \handler -> do
                expected <- handlerExpectedNext bodyEffect handler
                requestParamTypes <- handlerParamTypes bodyEffect handler
                local (\e -> e {checkExpectedNext = expected}) (walkRequestHandler requestParamTypes handler)
            )
            handlers
        (thenClause', thenType) <- case thenClause of
          Nothing -> pure (Nothing, Nothing)
          Just (maybePattern, thenBody) -> do
            (pattern', bindings) <- case maybePattern of
              Just p -> do (p', bs) <- walkPattern bodyType p; pure (Just p', bs)
              Nothing -> pure (Nothing, [])
            (thenBody', thenBodyType) <- withLocals bindings (walkBlock thenBody)
            pure (Just (pattern', thenBody'), Just thenBodyType)
        pure (body', bodyType, handlers', thenClause', thenType)
  let breakTypes = [semantic | ExitRecord HandleBreakTag semantic <- exitRecords]
      semantic = unionSemantic (maybe bodyType id thenType : breakTypes)
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

-- | A body that must transfer control (a request handler body or a @for@
-- body) cannot fall through to a value: assert its type is 'never', else emit
-- @mkError@ at @sourceSpan@. 'SemanticTypeUnknown' is treated as
-- already-errored (a prior diagnostic fired during recovery).
assertMustExit :: SourceSpan -> SemanticType Resolved -> (SourceSpan -> CheckError) -> Check ()
assertMustExit sourceSpan bodyType mkError = do
  dataFieldEnv <- asks (.checkDataFieldEnv)
  boundEnv <- asks (.checkBoundEnv)
  let isNever = subtypeNormalizedType dataFieldEnv boundEnv (normaliseSemantic dataFieldEnv bodyType) (normaliseSemantic dataFieldEnv SemanticTypeNever)
  case bodyType of
    SemanticTypeUnknown -> pure ()
    _ | isNever -> pure ()
    _ -> emitError (mkError sourceSpan)

-- | Check a request handler. Each parameter binds from the handled request's
-- (instantiated) parameter type @requestParamTypes@: unannotated takes it
-- directly, annotated checks that request-derived type against the annotation
-- (like @let x: T = …@) and binds the annotation.
walkRequestHandler :: Map Text (SemanticType Resolved) -> RequestHandler Identified -> Check (RequestHandler Zonked)
walkRequestHandler requestParamTypes RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  walked <- mapM bindHandlerParam parameters
  let parameters' = map fst walked
      paramLocals = concatMap snd walked
  (body', bodyType) <- withLocals paramLocals (walkBlock body)
  -- A request handler body must transfer control with @break@ / @next@; falling
  -- through to a value (its type is not 'never') is a dedicated error.
  assertMustExit (sourceSpanOf body) bodyType CheckErrorHandlerMustExit
  pure
    RequestHandler
      { moduleQualifier = fmap retagNameRef moduleQualifier,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        body = body',
        sourceSpan = sourceSpan
      }
  where
    bindHandlerParam ParameterBinding {annotation, name = paramName, typeAnnotation, defaultValue, spread, sourceSpan = paramSpan} = do
      let requestType = Map.findWithDefault SemanticTypeUnknown paramName.text requestParamTypes
      bindingType <- case typeAnnotation of
        Just annotationType -> do
          annotated <- elaborateType annotationType
          subtypeAssert paramSpan requestType annotated
          pure annotated
        Nothing -> pure requestType
      let rebuilt =
            ParameterBinding
              { annotation = annotation,
                name = retagNameRef paramName,
                typeAnnotation = fmap retagSyntacticType typeAnnotation,
                defaultValue = defaultValue,
                spread = spread,
                sourceSpan = paramSpan
              }
          binding = maybe [] (\resolution -> [(resolution, bindingType)]) paramName.resolution
      pure (rebuilt, binding)

-- | The handled request's (instantiated) parameter types, by label — the
-- counterpart of 'handlerExpectedNext' for the parameter (covariant) side: the
-- top / an effect generic widens each generic parameter to its top (type →
-- unknown, effect → all); a concrete instantiation substitutes the args.
handlerParamTypes :: NormalizedEffect -> RequestHandler Identified -> Check (Map Text (SemanticType Resolved))
handlerParamTypes bodyEffect RequestHandler {name} = case name.resolution of
  Just (ResolvedConcreteRequest requestQName) -> do
    dataFieldEnv <- asks (.checkDataFieldEnv)
    scheme <- lookupLocal (ResolvedTopLevel requestQName)
    case scheme >>= (paramFieldsOf . (.schemeBody)) of
      Nothing -> pure Map.empty
      Just paramFields -> do
        let paramIds = dataParamIdsOf dataFieldEnv requestQName
            widened =
              Map.map
                (substituteGenerics (Map.fromList [(p, SemanticTypeUnknown) | p <- paramIds]) (Map.fromList [(p, SemanticEffectAll) | p <- paramIds]))
                paramFields
            withArgs arguments =
              Map.map
                ( substituteGenerics
                    (Map.fromList [(p, argumentType) | (p, SemanticGenericArgumentType argumentType) <- zip paramIds arguments])
                    (Map.fromList [(p, argumentEffect) | (p, SemanticGenericArgumentEffect argumentEffect) <- zip paramIds arguments])
                )
                paramFields
        pure $ case bodyEffect of
          NormalizedEffectAny -> widened
          NormalizedEffectRows concrete generics _shadowed
            | not (Set.null generics) -> widened
            | Map.member requestQName concrete -> withArgs (requestArgsInEffect bodyEffect requestQName)
            | otherwise -> widened
  _ -> pure Map.empty
  where
    paramFieldsOf = \case
      SemanticTypeFunction parameterObject _ _ -> Just (Map.map (.parameterType) (functionParameters parameterObject))
      _ -> Nothing

-- | The type a handler's @next@ answer must satisfy: the handled request's
-- declared return type, with the body's instantiation args (read from the body
-- effect) substituted for the request's generic parameters. 'Nothing' when the
-- handler does not resolve to a concrete request (then @next@ is unconstrained).
handlerExpectedNext :: NormalizedEffect -> RequestHandler Identified -> Check (Maybe (SemanticType Resolved))
handlerExpectedNext bodyEffect RequestHandler {name} = case name.resolution of
  Just (ResolvedConcreteRequest requestQName) -> do
    dataFieldEnv <- asks (.checkDataFieldEnv)
    scheme <- lookupLocal (ResolvedTopLevel requestQName)
    case scheme >>= (returnOfSignature . (.schemeBody)) of
      Nothing -> pure Nothing
      Just returnType -> case bodyEffect of
        -- The effect top: the request could be raised at any args, so a single
        -- answer must be valid for all of them ⇒ 'never' (it can't be answered).
        NormalizedEffectAny -> pure (Just SemanticTypeNever)
        NormalizedEffectRows concrete generics _shadowed
          -- An in-scope effect generic is unbounded — it could itself be this
          -- request at any args — so again the answer must satisfy 'never'.
          | not (Set.null generics) -> pure (Just SemanticTypeNever)
          -- Request not raised by the body: the handler is dead; leave 'next'
          -- unconstrained rather than force 'never'.
          | not (Map.member requestQName concrete) -> pure Nothing
          | otherwise -> do
              let arguments = requestArgsInEffect bodyEffect requestQName
                  paramIds = dataParamIdsOf dataFieldEnv requestQName
                  typeSubstitution = Map.fromList [(paramId, argumentType) | (paramId, SemanticGenericArgumentType argumentType) <- zip paramIds arguments]
                  effectSubstitution = Map.fromList [(paramId, argumentEffect) | (paramId, SemanticGenericArgumentEffect argumentEffect) <- zip paramIds arguments]
              pure (Just (substituteGenerics typeSubstitution effectSubstitution returnType))
  _ -> pure Nothing
  where
    returnOfSignature = \case
      SemanticTypeFunction _ returnType _ -> Just returnType
      _ -> Nothing

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
  (statement', bindings, genericBindings) <- walkStatement statement
  -- Fold each binding's type with any quantifiers the same statement introduced
  -- (a local generic agent) into one scheme, so subsequent statements + the
  -- tail see the binding with its generics.
  let genericMap = Map.fromList genericBindings
      schemeBindings = [(resolution, TypeScheme (Map.findWithDefault [] resolution genericMap) semanticType) | (resolution, semanticType) <- bindings]
  (rest', tail') <- withSchemes schemeBindings (walkStatements rest returnExpression)
  pure (statement' : rest', tail')

-- | Walk a statement, returning its zonked form, the local-variable bindings it
-- introduces, and any generic-parameter registrations (a local generic agent).
walkStatement ::
  Statement Identified ->
  Check (Statement Zonked, [(VariableResolution, SemanticType Resolved)], [(VariableResolution, [(GenericsId, GenericKind, SemanticType Resolved)])])
walkStatement = \case
  StatementLet LetStatement {pattern, value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    (pattern', bindings) <- walkPattern valueType pattern
    pure (StatementLet LetStatement {pattern = pattern', value = value', sourceSpan = sourceSpan}, bindings, [])
  StatementReturn ReturnStatement {value, sourceSpan} -> do
    expected <- asks (.checkExpectedReturn)
    value' <- case expected of
      Just t -> checkExpr value t
      Nothing -> fst <$> synthExpr value
    pure (StatementReturn ReturnStatement {value = value', sourceSpan = sourceSpan}, [], [])
  StatementExpression expr -> do
    (expr', _) <- synthExpr expr
    pure (StatementExpression expr', [], [])
  StatementBreak BreakStatement {value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    recordExit HandleBreakTag valueType
    pure (StatementBreak BreakStatement {value = value', sourceSpan = sourceSpan}, [], [])
  StatementNext NextStatement {value, modifiers, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    modifiers' <- mapM walkModifier modifiers
    -- A @next e@ answer resumes the asker, so it must satisfy the handled
    -- request's (instantiated) return type (set per handler in 'synthHandle').
    expectedNext <- asks (.checkExpectedNext)
    forM_ expectedNext $ \expected -> subtypeAssert (sourceSpanOf value) valueType expected
    recordExit HandleNextTag valueType
    pure (StatementNext NextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}, [], [])
  StatementForBreak ForBreakStatement {value, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    recordExit ForBreakTag valueType
    pure (StatementForBreak ForBreakStatement {value = value', sourceSpan = sourceSpan}, [], [])
  StatementForNext ForNextStatement {value, modifiers, sourceSpan} -> do
    (value', valueType) <- synthExpr value
    modifiers' <- mapM walkModifier modifiers
    recordExit ForNextTag valueType
    pure (StatementForNext ForNextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}, [], [])
  StatementAgent agentStatement -> walkLocalAgent agentStatement
  StatementError span_ -> pure (StatementError span_, [], [])

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
  -- No widening: an unannotated initializer infers its exact (singleton)
  -- type, like every other binding. A mutable @var@ that is reassigned with a
  -- wider value must annotate its type (e.g. @var counter: integer = 1@) —
  -- consistent with the "annotate the boundaries" rule.
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
walkLocalAgent ::
  AgentStatement Identified ->
  Check (Statement Zonked, [(VariableResolution, SemanticType Resolved)], [(VariableResolution, [(GenericsId, GenericKind, SemanticType Resolved)])])
walkLocalAgent AgentStatement {annotation, name, typeParameters, parameters, returnType, withRequests, body, sourceSpan} = do
  -- A local generic agent registers its own parameters (so @inner[T]@ resolves,
  -- both for recursive calls inside its body and for use sites after its
  -- declaration), and elaborates its signature / body under its @extends@ bound
  -- environment.
  boundEnv <- buildBoundEnv typeParameters
  genericParams <- genericParamInfos typeParameters
  let genericBinding = maybe [] (\resolution -> [(resolution, genericParams)]) name.resolution
  (zonked, bindings) <- withBoundEnv boundEnv $ do
    (parameters', paramSig, paramLocals) <- elaborateParameters parameters
    declaredReturn <- traverse elaborateType returnType
    -- Recursive local agents need their return annotation; bind the signature
    -- scheme (carrying this agent's own quantifiers) up front when one is
    -- present, so recursive @inner[T]@ calls inside the body resolve.
    let selfScheme ret = maybe [] (\resolution -> [(resolution, TypeScheme genericParams (SemanticTypeFunction paramSig ret emptyEffect))]) name.resolution
    (body', bodyType) <-
      withSchemes (maybe [] selfScheme declaredReturn) $
        withLocals paramLocals $
          case declaredReturn of
            Just ret -> withExpectedReturn ret (walkBlock body)
            Nothing -> walkBlock body
    let returnSemantic = maybe bodyType id declaredReturn
        agentType = SemanticTypeFunction paramSig returnSemantic emptyEffect
        localBindings = maybe [] (\resolution -> [(resolution, agentType)]) name.resolution
    pure
      ( StatementAgent
          AgentStatement
            { annotation = annotation,
              name = retagNameRef name,
              typeParameters = map retagGenericParameter typeParameters,
              parameters = parameters',
              returnType = fmap retagSyntacticType returnType,
              withRequests = fmap (fmap retagSyntacticRequest) withRequests,
              body = body',
              sourceSpan = sourceSpan
            },
        localBindings
      )
  pure (zonked, bindings, genericBinding)

-- | Elaborate a parameter list into zonked params, the function-signature
-- parameter map, and the env bindings for the parameters.
elaborateParameters ::
  [ParameterBinding Identified] ->
  Check ([ParameterBinding Zonked], SemanticType Resolved, [(VariableResolution, SemanticType Resolved)])
elaborateParameters parameters = do
  walked <- mapM walkOne parameters
  let rebuilts = [p | (p, _, _, _) <- walked]
      bindings = mapMaybe (\(_, _, binding, _) -> binding) walked
      namedEntries = [entry | (_, entry, _, isSpread) <- walked, not isSpread]
      spreads = [(entry, span) | (ParameterBinding {sourceSpan = span}, entry, _, True) <- walked]
  paramSig <- case spreads of
    -- A sole spread parameter @...obj: T@: the parameter signature /is/ @T@
    -- (whatever it elaborates to — usually an object, but possibly a tuple),
    -- not the object built from labelled params.
    [((_, parameter), _)] | length walked == 1 -> pure parameter.parameterType
    -- A spread mixed with other params (or multiple spreads): reject, and fall
    -- back to the named-only object so checking continues.
    ((_, span) : _) -> do
      emitError (CheckErrorSpreadParameterMustBeSole span)
      pure (SemanticTypeObject (Map.fromList namedEntries))
    -- No spread: the parameter signature is the object of labelled params.
    [] -> pure (SemanticTypeObject (Map.fromList namedEntries))
  pure (rebuilts, paramSig, bindings)
  where
    walkOne ParameterBinding {annotation, name, typeAnnotation, defaultValue, spread, sourceSpan} = do
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
                spread = spread,
                sourceSpan = sourceSpan
              }
          binding = fmap (\resolution -> (resolution, paramType)) name.resolution
      pure (rebuilt, (name.text, parameter), binding, spread)

-- ---------------------------------------------------------------------------
-- Patterns (projection over a known subject type)
-- ---------------------------------------------------------------------------

-- | Walk a pattern against a known subject type, returning the zonked pattern
-- and the variable bindings it introduces. The subject type is concrete (it
-- was synthesised), so projection is a direct structural read.
-- | Expand a match scrutinee's outermost generics to their bounds (via the
-- normalized form), so a structured pattern can project through a generic type
-- (e.g. @T extends [int, string]@ becomes the tuple shape). Generics nested
-- inside layers survive and are expanded when they become the next scrutinee.
expandScrutinee :: SemanticType Resolved -> Check (SemanticType Resolved)
expandScrutinee subject = do
  boundEnv <- asks (.checkBoundEnv)
  dataFieldEnv <- asks (.checkDataFieldEnv)
  pure (denormalise (expandGenerics dataFieldEnv boundEnv (normaliseSemantic dataFieldEnv subject)))

walkPattern :: SemanticType Resolved -> Pattern Identified -> Check (Pattern Zonked, [(VariableResolution, SemanticType Resolved)])
walkPattern subject = \case
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan} -> do
    bindingType <- case typeAnnotation of
      -- An annotated binder (@let s: T = e@, @case s: T@) re-annotates the
      -- matched value: the subject must be a subtype of the annotation (like the
      -- @var@ initializer check). Narrowing to a /sub/type is a type guard
      -- ('PatternType'), not a variable annotation.
      Just t -> do
        annotated <- elaborateType t
        subtypeAssert sourceSpan subject annotated
        pure annotated
      Nothing -> pure subject
    let bindings = maybe [] (\resolution -> [(resolution, bindingType)]) name.resolution
    pure (PatternVariable VariablePattern {name = retagNameRef name, typeAnnotation = fmap retagSyntacticType typeAnnotation, sourceSpan = sourceSpan, typeOf = bindingType}, bindings)
  PatternWildcard WildcardPattern {typeAnnotation, sourceSpan} -> do
    patternType <- maybe (pure subject) elaborateType typeAnnotation
    pure (PatternWildcard WildcardPattern {typeAnnotation = fmap retagSyntacticType typeAnnotation, sourceSpan = sourceSpan, typeOf = patternType}, [])
  PatternLiteral LiteralPattern {value, sourceSpan} ->
    pure (PatternLiteral LiteralPattern {value = value, sourceSpan = sourceSpan, typeOf = literalValueToSemantic value}, [])
  PatternTuple TuplePattern {elements, sourceSpan} -> do
    -- Structured pattern: expand the scrutinee's outermost generics to their
    -- bounds first, so a generic @T extends [..]@ projects through the tuple
    -- layer. Components keep any nested generics, expanded at the next level.
    expanded <- expandScrutinee subject
    let componentTypes = projectTupleComponents (length elements) expanded
    walked <- mapM (\(componentType, element) -> walkPattern componentType element) (zip componentTypes elements)
    let patternType = SemanticTypeTuple (map (patternTypeOf . fst) walked)
    pure (PatternTuple TuplePattern {elements = map fst walked, sourceSpan = sourceSpan, typeOf = patternType}, concatMap snd walked)
  PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier, constructorName, parameters, sourceSpan} -> do
    declaredFields <- constructorFieldTypes constructorName.resolution
    dataFieldEnv <- asks (.checkDataFieldEnv)
    boundEnv <- asks (.checkBoundEnv)
    -- Read the constructor's variance-joined args from the NORMALISED + generic-
    -- expanded subject, so @box[a] | box[b]@ (and @box[a] | U@) bind soundly. A
    -- top subject (an unbounded generic was unioned in, so the value could be
    -- @box@ at any args) can't pin the args, so the field reads fall back to
    -- @unknown@ — always a sound supertype for a read.
    let normalizedSubject = expandGenerics dataFieldEnv boundEnv (normaliseSemantic dataFieldEnv subject)
        matchedArgs = constructorName.resolution >>= dataArgsInType normalizedSubject
        fieldSubjects = case (constructorName.resolution, matchedArgs) of
          (Just qualifiedName, Just arguments) ->
            let paramIds = dataParamIdsOf dataFieldEnv qualifiedName
                typeSubstitution = Map.fromList [(paramId, argumentType) | (paramId, SemanticGenericArgumentType argumentType) <- zip paramIds arguments]
                effectSubstitution = Map.fromList [(paramId, argumentEffect) | (paramId, SemanticGenericArgumentEffect argumentEffect) <- zip paramIds arguments]
             in Map.map (substituteGenerics typeSubstitution effectSubstitution) declaredFields
          (Just qualifiedName, Nothing) ->
            -- Top / unpinnable (an unbounded generic was unioned in): the data
            -- may be at any args. Substitute its generic parameters by their
            -- per-kind top (type → unknown, effect → all) so generic-dependent
            -- field reads widen, while a concrete field (e.g. `value: string` on
            -- a non-generic constructor) stays precise.
            let paramIds = dataParamIdsOf dataFieldEnv qualifiedName
                typeSubstitution = Map.fromList [(paramId, SemanticTypeUnknown) | paramId <- paramIds]
                effectSubstitution = Map.fromList [(paramId, SemanticEffectAll) | paramId <- paramIds]
             in Map.map (substituteGenerics typeSubstitution effectSubstitution) declaredFields
          (Nothing, _) -> declaredFields
    walked <-
      forM parameters $ \(label, sub) -> do
        let fieldSubject = Map.findWithDefault SemanticTypeUnknown label.text fieldSubjects
        (sub', bindings) <- walkPattern fieldSubject sub
        pure ((retagNameRef label, sub'), bindings)
    let patternType = maybe SemanticTypeUnknown (\qualifiedName -> SemanticTypeData qualifiedName (fromMaybe [] matchedArgs)) constructorName.resolution
    pure
      ( PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier = fmap retagNameRef moduleQualifier, constructorName = retagNameRef constructorName, parameters = map fst walked, sourceSpan = sourceSpan, typeOf = patternType},
        concatMap snd walked
      )
  PatternType TypePattern {typeTag, inner, sourceSpan} -> do
    let narrowedType = typePatternTagToSemantic typeTag
    (inner', bindings) <- walkPattern narrowedType inner
    pure (PatternType TypePattern {typeTag = typeTag, inner = inner', sourceSpan = sourceSpan, typeOf = narrowedType}, bindings)
  PatternRecord RecordPattern {entries, sourceSpan} -> do
    -- Structured pattern: expand the scrutinee's generics so a generic
    -- @T extends { .. }@ projects through the map layer for field lookup.
    expanded <- expandScrutinee subject
    walked <-
      forM entries $ \(entryLabel, entryPattern) -> do
        valueSubject <- fieldType sourceSpan expanded entryLabel
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
    lookupLocalType (ResolvedTopLevel qualifiedName) >>= \case
      Just (SemanticTypeFunction parameterObject _ _) -> pure (Map.map (.parameterType) (functionParameters parameterObject))
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

-- | The value type @V@ of a @record[V]@ argument (the @record.get@ / @record.set@
-- element). An object coerces to @record[unknown]@, so a non-record argument
-- reads as @unknown@.
recordValueType :: SemanticType Resolved -> SemanticType Resolved
recordValueType = \case
  SemanticTypeRecord valueType -> valueType
  SemanticTypeUnion branches -> unionSemantic (map recordValueType branches)
  _ -> SemanticTypeUnknown

-- | The type of field @label@ read from a map-layer (object / data / record)
-- subject. A missing field on an object / data is a hard error.
fieldType :: SourceSpan -> SemanticType Resolved -> Text -> Check (SemanticType Resolved)
fieldType sourceSpan subject label = case subject of
  SemanticTypeObject fields -> case Map.lookup label fields of
    -- The field type already carries 'null' for an optional field (it widened
    -- at elaboration), so the read type is just the field type.
    Just field -> pure field.parameterType
    Nothing -> missing
  -- A read off @record[V]@ yields its value type @V@ (any key).
  SemanticTypeRecord valueType -> pure valueType
  SemanticTypeData qualifiedName arguments ->
    constructorFieldTypes (Just qualifiedName) >>= \fields ->
      case Map.lookup label fields of
        -- Specialise the declared field type by the application args (so
        -- @box[integer].x@ reads @integer@, not the abstract parameter).
        Just t -> do
          dataFieldEnv <- asks (.checkDataFieldEnv)
          let paramIds = dataParamIdsOf dataFieldEnv qualifiedName
              typeSubstitution = Map.fromList [(paramId, argumentType) | (paramId, SemanticGenericArgumentType argumentType) <- zip paramIds arguments]
              effectSubstitution = Map.fromList [(paramId, argumentEffect) | (paramId, SemanticGenericArgumentEffect argumentEffect) <- zip paramIds arguments]
          pure (substituteGenerics typeSubstitution effectSubstitution t)
        Nothing -> missing
  SemanticTypeUnion branches -> unionSemantic <$> mapM (\b -> fieldType sourceSpan b label) branches
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  _ -> missing
  where
    missing = emitError (CheckErrorNoSuchField sourceSpan label) >> pure SemanticTypeUnknown


-- ===========================================================================
-- Per-SCC entry point
-- ===========================================================================

-- | Type-check one SCC of a module (mirrors the constraint pipeline's
-- @runOneSCC@). Given the resolved signatures of everything checked so far
-- (imports + earlier SCCs), it produces the zonked declarations the SCC owns,
-- their signatures (to extend the resolved environment), and any diagnostics.
-- The caller assembles the full @Module Zonked@ from these per-SCC maps.
checkSCC ::
  -- | Module name (for self-recursion detection).
  Text ->
  -- | Resolved callable /schemes/ seen so far (imports + earlier SCCs); a
  -- generic callable's scheme carries its quantifiers, so it can be
  -- instantiated here regardless of which module (or the ambient stdlib)
  -- defined it.
  Map QualifiedName TypeScheme ->
  Module Identified ->
  -- | The qualified names this SCC owns.
  Set QualifiedName ->
  Map QualifiedName TypeData ->
  Map QualifiedName PrimRule ->
  ( Map QualifiedName (Declaration Zonked),
    -- | Top-level schemes the SCC owns (extends the resolved environment).
    Map QualifiedName TypeScheme,
    -- | Every binding's type, top-level + local (for the Query / hover layer).
    Map VariableResolution (SemanticType Resolved),
    -- | Each module generic parameter's elaborated @extends@ bound (keyed by
    -- 'GenericsId'). Module-wide (same for every SCC). Used by the
    -- exhaustiveness checker to expand a generic scrutinee to its bound.
    Map GenericsId (SemanticType Resolved),
    [Diagnostic]
  )
checkSCC moduleName resolvedCallables moduleAST sccQualifiedNames typeData primRules =
  let env =
        CheckEnv
          { checkTypeData = typeData,
            checkDataFieldEnv = buildDataFieldEnv (Map.map (.schemeBody) resolvedCallables),
            checkSynonymVisited = Set.empty,
            checkLocals = Map.mapKeys ResolvedTopLevel resolvedCallables,
            checkPrimRules = primRules,
            checkBoundEnv = Map.empty,
            checkExpectedReturn = Nothing,
            checkExpectedNext = Nothing
          }
      sccDeclarations = filter (declarationInSCC sccQualifiedNames) moduleAST.declarations
      -- The whole module's per-callable quantifiers (gathered once), used to
      -- wrap each own callable's inferred type back into a 'TypeScheme' for
      -- re-export, and to derive the generic bounds for the exhaustiveness
      -- checker. (Imported callables' quantifiers already ride in their schemes
      -- via 'checkLocals'.)
      checkAction = do
        ownGenericParams <- buildModuleGenericParams moduleAST.declarations
        results <- checkSCCDeclarations moduleName sccQualifiedNames sccDeclarations
        pure (results, ownGenericParams)
      ((results, ownGenericParams), errors, localTypes) = runCheck env checkAction
      quantifiersFor qualifiedName = Map.findWithDefault [] (ResolvedTopLevel qualifiedName) ownGenericParams
      zonked = Map.fromList [(qualifiedName, declaration) | (qualifiedName, declaration, _) <- results]
      signatures = Map.fromList [(qualifiedName, TypeScheme (quantifiersFor qualifiedName) sig) | (qualifiedName, _, sig) <- results]
      typeEnv = Map.union (Map.mapKeys ResolvedTopLevel (Map.fromList [(qualifiedName, sig) | (qualifiedName, _, sig) <- results])) localTypes
      genericBounds = Map.fromList [(genericsId, bound) | params <- Map.elems ownGenericParams, (genericsId, _kind, bound) <- params]
   in (zonked, signatures, typeEnv, genericBounds, map toDiagnostic errors)

declarationInSCC :: Set QualifiedName -> Declaration Identified -> Bool
declarationInSCC sccQualifiedNames declaration = case declarationVarName declaration of
  Just nameRef -> maybe False (`Set.member` sccQualifiedNames) (topLevelQName nameRef)
  Nothing -> False

declarationVarName :: Declaration Identified -> Maybe (NameRef Identified VariableRef)
declarationVarName = \case
  DeclarationAgent decl -> Just decl.name
  DeclarationRequest decl -> Just decl.name
  DeclarationExternalAgent decl -> Just decl.name
  DeclarationPrimAgent decl -> Just decl.name
  DeclarationData decl -> Just decl.name
  _ -> Nothing

type SCCResult = (QualifiedName, Declaration Zonked, SemanticType Resolved)

checkSCCDeclarations :: Text -> Set QualifiedName -> [Declaration Identified] -> Check [SCCResult]
checkSCCDeclarations moduleName sccQualifiedNames declarations = do
  let agents = [decl | DeclarationAgent decl <- declarations]
      nonAgents = [decl | decl <- declarations, not (isAgentDeclaration decl)]
      -- A multi-member SCC, or a self-recursive singleton, is recursive: its
      -- agents must seed their return signature (and pin their effect) up front
      -- to break the cycle. Computed once and shared by the return-seeding and
      -- effect passes.
      recursive = Set.size sccQualifiedNames > 1 || any (isSelfRecursive moduleName) agents
  nonAgentResults <- catMaybes <$> mapM checkNonAgentDeclaration nonAgents
  -- All @data@ live in one (the non-agent) SCC, so their constructor sigs are
  -- now all known: build the complete data env and verify each declared
  -- @in@ / @out@ variance against the inferred one.
  checkDeclaredVariances (buildDataFieldEnv (Map.fromList [(qualifiedName, sig) | (qualifiedName, _, sig) <- nonAgentResults])) nonAgents
  agentResults <- checkAgentBatch recursive agents
  inferEffects recursive sccQualifiedNames (nonAgentResults ++ agentResults)

-- | Verify each @data@ parameter's declared @in@ / @out@ marker against its
-- inferred variance (the inferred variance must be bivariant or match the
-- declared direction; the opposite direction or invariant is an error).
checkDeclaredVariances :: DataFieldEnv -> [Declaration Identified] -> Check ()
checkDeclaredVariances dataEnv declarations =
  forM_ [dataDecl | DeclarationData dataDecl <- declarations] $ \dataDecl ->
    case dataDecl.typeName.resolution of
      Just (ResolvedNamedType dataQName) ->
        forM_ (zip dataDecl.typeParameters (variancesOf dataEnv dataQName ++ repeat Bivariant)) $ \(parameter, inferred) ->
          case parameter.declaredVariance of
            Just DeclaredCovariant
              | inferred /= Covariant && inferred /= Bivariant ->
                  emitError (CheckErrorVarianceMismatch parameter.sourceSpan parameter.name.text "out")
            Just DeclaredContravariant
              | inferred /= Contravariant && inferred /= Bivariant ->
                  emitError (CheckErrorVarianceMismatch parameter.sourceSpan parameter.name.text "in")
            _ -> pure ()
      _ -> pure ()

-- | Compute each SCC agent's published effect and check it against any declared
-- @with@ clause, then patch the agent signatures. No fixpoint is needed:
--
--   * In a recursive SCC every agent is /pinned/ to its declared effect (or
--     @∅@ when it has no @with@ clause). An effectful recursive agent without a
--     @with@ clause therefore fails the coverage check below (K0212), which
--     forces it to annotate — closing the soundness gap where an
--     unannotated recursive agent would be seen as pure while a sibling passes
--     it as a function argument.
--   * A non-recursive singleton SCC has one agent that never references itself,
--     so a single body walk (@blockEffect@) yields its inferred effect.
--
-- Non-agent results pass through unchanged.
inferEffects :: Bool -> Set QualifiedName -> [SCCResult] -> Check [SCCResult]
inferEffects recursive sccQualifiedNames results = do
  locals <- asks (Map.map (.schemeBody) . (.checkLocals))
  dataFieldEnv <- asks (.checkDataFieldEnv)
  -- The declared @with@ clause effect of each annotated agent, elaborated
  -- (request args included, e.g. @with foo[integer]@) and normalised. 'Nothing'
  -- for an unannotated agent (its effect is inferred below).
  declaredEffectMap <-
    fmap Map.fromList . sequence $
      [ (qualifiedName,) <$> traverse (fmap (normaliseEffect dataFieldEnv) . elaborateRequestList . map retagSyntacticRequest) agentDecl.withRequests
        | (qualifiedName, DeclarationAgent agentDecl, _) <- results
      ]
  let externalLookup qualifiedName =
        effectOfSignature dataFieldEnv (Map.findWithDefault SemanticTypeUnknown (ResolvedTopLevel qualifiedName) locals)
      agentInfos =
        [ (qualifiedName, agentDecl, Map.findWithDefault Nothing qualifiedName declaredEffectMap)
        | (qualifiedName, DeclarationAgent agentDecl, _) <- results
        ]
      agentSpans =
        Map.fromList [(qualifiedName, agentDecl.sourceSpan) | (qualifiedName, agentDecl, _) <- agentInfos]
      bodies = Map.fromList [(qualifiedName, agentDecl.body) | (qualifiedName, agentDecl, _) <- agentInfos]
      lookupWith effects requested
        | Set.member requested sccQualifiedNames = Map.findWithDefault mempty requested effects
        | otherwise = externalLookup requested
      published =
        Map.fromList
          [ ( qualifiedName,
              case declaredEffect of
                Just declared -> declared
                Nothing
                  | recursive -> mempty
                  | otherwise -> blockEffect dataFieldEnv (lookupWith Map.empty) agentDecl.body
            )
          | (qualifiedName, agentDecl, declaredEffect) <- agentInfos
          ]
      -- Only an /annotated/ agent can violate its @with@ clause: an unannotated
      -- non-recursive agent's published effect IS its inferred effect (so it
      -- never exceeds it), and a recursive agent with no @with@ already has the
      -- dedicated K0219 diagnostic.
      violations =
        [ (qualifiedName, effectNames agentDecl undeclared)
        | (qualifiedName, agentDecl, Just declared) <- agentInfos,
          let bodyEffect = blockEffect dataFieldEnv (lookupWith published) (bodies Map.! qualifiedName),
          let undeclared = differenceNormalizedEffect bodyEffect declared,
          not (nullNormalizedEffect undeclared)
        ]
  forM_ violations $ \(qualifiedName, names) ->
    emitError (CheckErrorUndeclaredEffect (Map.findWithDefault dummySpan qualifiedName agentSpans) names)
  pure (map (patchResultEffect published) results)
  where
    dummySpan = case results of
      ((_, declaration, _) : _) -> sourceSpanOf declaration
      [] -> error "inferEffects: no results"
    -- Render an effect's undeclared elements: concrete requests by qualified
    -- name, effect generics by their declared parameter name (from the agent's
    -- generic list).
    effectNames agentDecl = \case
      NormalizedEffectAny -> ["all"]
      NormalizedEffectRows concrete generics _shadowed ->
        map renderQName (Map.keys concrete)
          ++ map (genericEffectName agentDecl) (Set.toList generics)
    genericEffectName agentDecl genericsId =
      case [param.name.text | param <- agentDecl.typeParameters, param.name.resolution == Just (ResolvedGenericParam genericsId)] of
        (name : _) -> name
        [] -> "<effect-generic>"

patchResultEffect :: Map QualifiedName NormalizedEffect -> SCCResult -> SCCResult
patchResultEffect published (qualifiedName, declaration, sig) =
  case Map.lookup qualifiedName published of
    Just effect -> (qualifiedName, declaration, setEffect effect sig)
    Nothing -> (qualifiedName, declaration, sig)

setEffect :: NormalizedEffect -> SemanticType Resolved -> SemanticType Resolved
setEffect effect = \case
  SemanticTypeFunction params ret _ ->
    SemanticTypeFunction params ret (denormaliseEffect effect)
  other -> other

isAgentDeclaration :: Declaration phase -> Bool
isAgentDeclaration = \case DeclarationAgent _ -> True; _ -> False

-- | A non-agent callable's signature + zonked declaration (no body to check).
checkNonAgentDeclaration :: Declaration Identified -> Check (Maybe SCCResult)
checkNonAgentDeclaration = \case
  DeclarationData DataDeclaration {annotation, name, constructorName, typeName, typeParameters, parameters, sourceSpan} -> do
    fields <-
      mapM
        ( \DataParameter {name = fieldName, parameterType, defaultValue, sourceSpan = fieldSpan} -> do
            elaborated <- elaborateType parameterType
            -- A default literal must be a subtype of the field type (mirrors the
            -- parameter-default check); a field with a default is optional.
            case defaultValue of
              Just paramDefault -> subtypeAssert fieldSpan (literalValueToSemantic paramDefault.value) elaborated
              Nothing -> pure ()
            pure (fieldName, Parameter {parameterType = elaborated, optional = isJust defaultValue})
        )
        parameters
    let -- The constructor returns the data applied to its own generic
        -- parameters (@data foo[T] -> foo[T]@). These self-applied args are how
        -- 'buildDataFieldEnv' recovers the parameter ids (and an instantiation
        -- @foo[int]@ substitutes them).
        selfArgs =
          [ case parameter.kind of
              GenericKindType -> SemanticGenericArgumentType (SemanticTypeGeneric genericsId)
              GenericKindEffect -> SemanticGenericArgumentEffect (SemanticEffectGeneric genericsId)
            | parameter <- typeParameters,
              Just (ResolvedGenericParam genericsId) <- [parameter.name.resolution]
          ]
        returnType = case typeName.resolution of
          Just (ResolvedNamedType qualifiedName) -> SemanticTypeData qualifiedName selfArgs
          _ -> SemanticTypeUnknown
        sig = functionType (Map.fromList fields) returnType emptyEffect
        zonked =
          DeclarationData
            DataDeclaration
              { annotation = annotation,
                name = retagNameRef name,
                constructorName = retagNameRef constructorName,
                typeName = retagNameRef typeName,
                typeParameters = map retagGenericParameter typeParameters,
                parameters = map retagDataParameter parameters,
                sourceSpan = sourceSpan
              }
    pure (withQName name zonked sig)
  DeclarationRequest RequestDeclaration {annotation, name, requestName, typeParameters, parameters, returnType, sourceSpan} -> do
    (parameters', paramSig, _) <- elaborateParameters parameters
    ret <- elaborateType returnType
    let -- The request's own effect is itself applied to its generic parameters
        -- (@request foo[A] … → with foo[A]@); an instantiation @foo[int]@
        -- substitutes them, exactly like a generic data's return type.
        selfArgs =
          [ case parameter.kind of
              GenericKindType -> SemanticGenericArgumentType (SemanticTypeGeneric genericsId)
              GenericKindEffect -> SemanticGenericArgumentEffect (SemanticEffectGeneric genericsId)
            | parameter <- typeParameters,
              Just (ResolvedGenericParam genericsId) <- [parameter.name.resolution]
          ]
        effect = case requestName.resolution of
          Just (ResolvedConcreteRequest qualifiedName) | not (isThrowRequest qualifiedName) -> SemanticEffectRequest qualifiedName selfArgs
          _ -> emptyEffect
        sig = SemanticTypeFunction paramSig ret effect
        zonked =
          DeclarationRequest
            RequestDeclaration
              { annotation = annotation,
                name = retagNameRef name,
                requestName = retagNameRef requestName,
                typeParameters = map retagGenericParameter typeParameters,
                parameters = parameters',
                returnType = retagSyntacticType returnType,
                sourceSpan = sourceSpan
              }
    pure (withQName name zonked sig)
  DeclarationExternalAgent ExternalAgentDeclaration {annotation, name, typeParameters, parameters, returnType, withRequests, endpoint, dispatchName, sourceSpan} -> do
    (parameters', paramSig, _) <- elaborateParameters parameters
    ret <- elaborateType returnType
    effect <- elaborateRequestList withRequests
    let sig = SemanticTypeFunction paramSig ret effect
        zonked =
          DeclarationExternalAgent
            ExternalAgentDeclaration
              { annotation = annotation,
                name = retagNameRef name,
                typeParameters = map retagGenericParameter typeParameters,
                parameters = parameters',
                returnType = retagSyntacticType returnType,
                withRequests = map retagSyntacticRequest withRequests,
                endpoint = endpoint,
                dispatchName = dispatchName,
                sourceSpan = sourceSpan
              }
    pure (withQName name zonked sig)
  DeclarationPrimAgent PrimAgentDeclaration {annotation, name, typeParameters, parameters, returnType, withRequests, using, sourceSpan} -> do
    (parameters', paramSig, _) <- elaborateParameters parameters
    ret <- elaborateType returnType
    effect <- elaborateRequestList withRequests
    let sig = SemanticTypeFunction paramSig ret effect
        zonked =
          DeclarationPrimAgent
            PrimAgentDeclaration
              { annotation = annotation,
                name = retagNameRef name,
                typeParameters = map retagGenericParameter typeParameters,
                parameters = parameters',
                returnType = retagSyntacticType returnType,
                withRequests = map retagSyntacticRequest withRequests,
                using = using,
                sourceSpan = sourceSpan
              }
    pure (withQName name zonked sig)
  _ -> pure Nothing

-- | Check a batch of mutually-recursive agents forming one SCC. A multi-member
-- SCC (or a self-recursive singleton) is recursive: every member must annotate
-- its return type, seeded up front to break the recursion. A non-recursive
-- singleton infers its return from the body.
checkAgentBatch :: Bool -> [AgentDeclaration Identified] -> Check [SCCResult]
checkAgentBatch recursive agents =
  if recursive
    then do
      seeds <- concat <$> mapM seedAgentSignature agents
      let bindings = [(ResolvedTopLevel qualifiedName, sig) | (qualifiedName, sig) <- seeds]
      withLocals bindings (mapM checkAgentResult agents)
    else mapM checkAgentResult agents

isSelfRecursive :: Text -> AgentDeclaration Identified -> Bool
isSelfRecursive moduleName decl = case topLevelQName decl.name of
  Just qualifiedName -> Set.member qualifiedName (declarationDependencies moduleName (DeclarationAgent decl))
  Nothing -> False

-- | A recursive agent's seeded signature, from its mandatory return annotation
-- (and its declared @with@ effect). Missing return = the recursive diagnostic.
seedAgentSignature :: AgentDeclaration Identified -> Check [(QualifiedName, SemanticType Resolved)]
seedAgentSignature AgentDeclaration {name, parameters, returnType, withRequests, sourceSpan} = do
  paramSig <- parameterSignatureOnly parameters
  ret <- case returnType of
    Just t -> elaborateType t
    Nothing -> do
      emitError (CheckErrorRecursiveReturn sourceSpan name.text)
      pure SemanticTypeUnknown
  -- A recursive agent must declare its effect too (its return is already
  -- mandatory): the effect cannot be inferred through the recursion. @with
  -- pure@ declares no requests.
  effect <- case withRequests of
    Just requests -> elaborateRequestList requests
    Nothing -> do
      emitError (CheckErrorRecursiveEffect sourceSpan name.text)
      pure emptyEffect
  pure (maybe [] (\qualifiedName -> [(qualifiedName, SemanticTypeFunction paramSig ret effect)]) (topLevelQName name))

checkAgentResult :: AgentDeclaration Identified -> Check SCCResult
checkAgentResult decl = do
  (zonked, sig) <- checkAgentDeclaration decl
  let qualifiedName = maybe (QualifiedName "" "") id (topLevelQName decl.name)
  pure (qualifiedName, zonked, sig)

-- | Check an agent's body and build its zonked declaration + signature. When
-- the return type is annotated the body is checked against it; otherwise the
-- return is inferred from the body. (For a recursive agent the env already
-- carries the seeded signature, and the annotation is mandatory.)
checkAgentDeclaration :: AgentDeclaration Identified -> Check (Declaration Zonked, SemanticType Resolved)
checkAgentDeclaration AgentDeclaration {annotation, name, typeParameters, parameters, returnType, withRequests, body, sourceSpan} = do
  boundEnv <- buildBoundEnv typeParameters
  (parameters', paramSig, paramLocals) <- withBoundEnv boundEnv (elaborateParameters parameters)
  declaredReturn <- traverse elaborateType returnType
  effect <- maybe (pure emptyEffect) elaborateRequestList withRequests
  (body', returnSemantic) <-
    withBoundEnv boundEnv $ withLocals paramLocals $ case declaredReturn of
      Just ret -> withExpectedReturn ret $ do
        (body', bodyType) <- walkBlock body
        subtypeAssert (sourceSpanOf body) bodyType ret
        pure (body', ret)
      Nothing -> walkBlock body
  let zonked =
        DeclarationAgent
          AgentDeclaration
            { annotation = annotation,
              name = retagNameRef name,
              typeParameters = map retagGenericParameter typeParameters,
              parameters = parameters',
              returnType = fmap retagSyntacticType returnType,
              withRequests = fmap (fmap retagSyntacticRequest) withRequests,
              body = body',
              sourceSpan = sourceSpan
            }
  pure (zonked, SemanticTypeFunction paramSig returnSemantic effect)

-- | Elaborate just the parameter types into a signature map (no zonked output,
-- no default-value subtype check — used for the recursive pre-seed so its
-- diagnostics don't double with the real check).
parameterSignatureOnly :: [ParameterBinding Identified] -> Check (SemanticType Resolved)
parameterSignatureOnly parameters = case parameters of
  -- A sole spread parameter @...obj: T@: the signature is @T@ directly.
  [ParameterBinding {typeAnnotation = Just spreadType, spread = True}] -> elaborateType spreadType
  _ ->
    SemanticTypeObject . Map.fromList
      <$> mapM
        ( \ParameterBinding {name, typeAnnotation, defaultValue} -> do
            paramType <- maybe (pure SemanticTypeUnknown) elaborateType typeAnnotation
            pure (name.text, Parameter {parameterType = paramType, optional = case defaultValue of Just _ -> True; Nothing -> False})
        )
        parameters

retagDataParameter :: DataParameter Identified -> DataParameter Zonked
retagDataParameter DataParameter {annotation, name, parameterType, defaultValue, sourceSpan} =
  DataParameter {annotation = annotation, name = name, parameterType = retagSyntacticType parameterType, defaultValue = defaultValue, sourceSpan = sourceSpan}

withQName :: NameRef Identified VariableRef -> Declaration Zonked -> SemanticType Resolved -> Maybe SCCResult
withQName name zonked sig = (\qualifiedName -> (qualifiedName, zonked, sig)) <$> topLevelQName name

isThrowRequest :: QualifiedName -> Bool
isThrowRequest qualifiedName = qualifiedName.module_ == "primitive" && qualifiedName.name == "throw"

topLevelQName :: (NameRefResolution phase VariableRef ~ Maybe VariableResolution) => NameRef phase VariableRef -> Maybe QualifiedName
topLevelQName nameRef = case nameRef.resolution of
  Just (ResolvedTopLevel qualifiedName) -> Just qualifiedName
  _ -> Nothing

renderQName :: QualifiedName -> Text
renderQName qualifiedName = qualifiedName.module_ <> "." <> qualifiedName.name

-- ===========================================================================
-- Effect collection (single-pass; see 'inferEffects' for the SCC strategy)
-- ===========================================================================

-- | Each callable's effect (concrete requests + effect generics), used while
-- walking bodies.
type EffectLookup = QualifiedName -> NormalizedEffect

-- | The effect a callable's function signature raises. Needs the data env to
-- bake request variances (via 'normaliseEffect').
effectOfSignature :: DataFieldEnv -> SemanticType Resolved -> NormalizedEffect
effectOfSignature env = \case
  SemanticTypeFunction _ _ effect -> normaliseEffect env effect
  _ -> mempty

blockEffect :: DataFieldEnv -> EffectLookup -> Block Zonked -> NormalizedEffect
blockEffect env lookupEffect Block {statements, returnExpression} =
  foldMap (statementEffect env lookupEffect) statements
    <> maybe mempty (exprEffect env lookupEffect) returnExpression

statementEffect :: DataFieldEnv -> EffectLookup -> Statement Zonked -> NormalizedEffect
statementEffect env lookupEffect = \case
  StatementLet s -> exprEffect env lookupEffect s.value
  StatementReturn s -> exprEffect env lookupEffect s.value
  StatementExpression e -> exprEffect env lookupEffect e
  StatementBreak s -> exprEffect env lookupEffect s.value
  StatementNext s -> exprEffect env lookupEffect s.value <> foldMap (exprEffect env lookupEffect . (.value)) s.modifiers
  StatementForNext s -> exprEffect env lookupEffect s.value <> foldMap (exprEffect env lookupEffect . (.value)) s.modifiers
  StatementForBreak s -> exprEffect env lookupEffect s.value
  -- A nested @agent@ is its own callable; calling it contributes via its
  -- signature at the call site, so its body does not raise here.
  StatementAgent _ -> mempty
  StatementError _ -> mempty

exprEffect :: DataFieldEnv -> EffectLookup -> Expression Zonked -> NormalizedEffect
exprEffect env lookupEffect = go
  where
    go = \case
      ExpressionLiteral _ -> mempty
      ExpressionVariable _ -> mempty
      ExpressionQualifiedReference _ -> mempty
      ExpressionTuple e -> foldMap go e.elements
      ExpressionParTuple e -> foldMap go e.elements
      ExpressionRecord e -> foldMap (go . snd) e.entries
      ExpressionCall e -> calleeEffect e.callee <> foldMap (go . (.value)) e.arguments
      ExpressionIf e -> go e.condition <> blockEffect env lookupEffect e.thenBlock <> maybe mempty (blockEffect env lookupEffect) e.elseBlock
      ExpressionMatch e -> go e.subject <> foldMap (blockEffect env lookupEffect . (.body)) e.cases
      ExpressionFor e ->
        foldMap (go . (.source)) e.inBindings
          <> foldMap (go . (.initial)) e.varBindings
          <> blockEffect env lookupEffect e.body
          <> maybe mempty (blockEffect env lookupEffect . snd) e.thenBlock
      ExpressionBlock e -> blockEffect env lookupEffect e.block
      ExpressionHandle e -> handleEffect e
      ExpressionFieldAccess e -> go e.object
      ExpressionTypeApplication e -> go e.callee
      ExpressionTemplate e -> foldMap templateEffect e.elements
      ExpressionBinaryOperator _ -> mempty
      ExpressionUnaryOperator _ -> mempty
    -- Calling a callable raises that callable's effect. For an SCC-internal
    -- callee the lookup uses the current estimate; otherwise its signature
    -- effect (carried on the reference's type).
    calleeEffect = \case
      ExpressionVariable v -> maybe (effectOfSignature env v.typeOf) lookupEffect (topLevelQName v.name)
      ExpressionQualifiedReference q -> maybe (effectOfSignature env q.typeOf) lookupEffect (topLevelQName q.target)
      complex -> effectOfSignature env (exprTypeOf complex)
    -- A handle discharges the concrete requests it names: the body's effect
    -- with those requests subtracted (an abstract effect generic is NOT
    -- discharged by a concrete handler, so it passes through), plus the
    -- handlers' own bodies and the then-clause.
    handleEffect e =
      let handled = Set.fromList [qualifiedName | handler <- e.handlers, Just (ResolvedConcreteRequest qualifiedName) <- [handler.name.resolution]]
          bodyEff = blockEffect env lookupEffect e.body
          handlerEff = foldMap (blockEffect env lookupEffect . (.body)) e.handlers
          thenEff = maybe mempty (blockEffect env lookupEffect . snd) e.thenClause
       in subtractConcrete handled bodyEff <> handlerEff <> thenEff
    templateEffect = \case
      TemplateElementString _ -> mempty
      TemplateElementExpression el -> go el.value

-- | The resolved type stamped on a Zonked expression.
exprTypeOf :: Expression Zonked -> SemanticType Resolved
exprTypeOf = \case
  ExpressionLiteral e -> e.typeOf
  ExpressionVariable e -> e.typeOf
  ExpressionTuple e -> e.typeOf
  ExpressionParTuple e -> e.typeOf
  ExpressionRecord e -> e.typeOf
  ExpressionCall e -> e.typeOf
  ExpressionIf e -> e.typeOf
  ExpressionMatch e -> e.typeOf
  ExpressionFor e -> e.typeOf
  ExpressionBlock e -> e.typeOf
  ExpressionHandle e -> e.typeOf
  ExpressionFieldAccess e -> e.typeOf
  ExpressionTypeApplication e -> e.typeOf
  ExpressionTemplate e -> e.typeOf
  ExpressionQualifiedReference e -> e.typeOf
  ExpressionBinaryOperator _ -> SemanticTypeUnknown
  ExpressionUnaryOperator _ -> SemanticTypeUnknown
