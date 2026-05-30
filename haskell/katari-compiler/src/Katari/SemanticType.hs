-- | Semantic type representation for the Katari typechecker.
--
-- 'SemanticType' is parameterised by a phase tag (@Unresolved@ / @Resolved@)
-- so that the @SemanticTypeVariable@ constructor only exists at the
-- @Unresolved@ phase. A @SemanticType Resolved@ value is therefore guaranteed
-- by the type system to be free of unification variables.
--
-- This is a separate data type from 'Katari.AST.SyntacticType': the AST
-- captures user-written syntax (e.g. type names, qualified references, type
-- synonyms) while @SemanticType@ captures the actual type meaning after
-- elaboration. Type synonyms are expanded transparently — they do not
-- appear in @SemanticType@.
--
-- This module has no dependency on 'Katari.AST'. The 'ExpressionType' / 'PatternType'
-- closed type families in 'Katari.AST' reference 'SemanticType' directly.
--
-- 'NormalizedType' (see 'Katari.Typechecker.NormalizedType') is yet another
-- representation that further normalises union / tuple shapes for use by the
-- constraint solver.
module Katari.SemanticType where

import Data.Functor.Const (Const (..))
import Data.Functor.Identity (Identity (..))
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Common (QualifiedName (..))

-- ---------------------------------------------------------------------------
-- Phase markers
-- ---------------------------------------------------------------------------

-- | Phase tag for @SemanticType@ values that may still contain unification
-- variables (constraint generation phase).
type data Unresolved

-- | Phase tag for @SemanticType@ values that are guaranteed to contain no
-- unification variables (after the constraint solver has run).
type data Resolved

-- ---------------------------------------------------------------------------
-- Type / request variables
-- ---------------------------------------------------------------------------

-- | Unification variable id. Allocated by the constraint generator and
-- substituted away by the solver.
newtype TypeVariableId = TypeVariableId Int
  deriving (Eq, Ord, Show)

-- | Request variable id. Used to bound an request set whose membership is not
-- yet known at constraint generation time.
newtype RequestVariableId = RequestVariableId Int
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Semantic types
-- ---------------------------------------------------------------------------

-- | Semantic type. The phase parameter selects whether unification variables
-- may appear: only @SemanticType Unresolved@ admits 'SemanticTypeVariable',
-- because that constructor's GADT signature constrains the phase to
-- @Unresolved@. Pattern-matching on a @SemanticType Resolved@ therefore does
-- not need to (and cannot) handle the variable case.
data SemanticType phase where
  -- | Unification variable. Only constructible at @Unresolved@ phase.
  SemanticTypeVariable :: TypeVariableId -> SemanticType Unresolved
  -- | Lattice bottom: no values inhabit this type.
  SemanticTypeNever :: SemanticType phase
  -- | Lattice top: any value satisfies this type.
  SemanticTypeUnknown :: SemanticType phase
  -- Primitive (concrete) types.
  SemanticTypeNull :: SemanticType phase
  SemanticTypeInteger :: SemanticType phase
  SemanticTypeNumber :: SemanticType phase
  SemanticTypeString :: SemanticType phase
  -- | Opaque credential string. Disjoint from 'SemanticTypeString'
  -- (no subtype relation). Values flow into runtime only via env-bound
  -- ext agents (e.g. @get_secret_env@); they propagate transparently
  -- through f-string interpolation (the @fstring_join@ prim rule taints
  -- the result type with @secret@), but cannot be printed, compared,
  -- pattern-matched, or downcast to @string@. The runtime stores the
  -- value as a string but treats the wrapper as a separate Value
  -- variant for boundary-crossing concerns (redaction in logs,
  -- AES encryption in DB persistence).
  SemanticTypeSecret :: SemanticType phase
  -- | Opaque byte sequence (@file@). Disjoint from 'SemanticTypeString'
  -- (no subtype relation). Identity-typed: @file == file@ compares
  -- reference identity, not content. Has no literals (cannot be pattern-
  -- matched against a value). The runtime represents it as a value
  -- reference (always a blob ref); the value model never inlines it.
  SemanticTypeFile :: SemanticType phase
  SemanticTypeBoolean :: SemanticType phase
  -- Literal types: a singleton type containing exactly one value.
  SemanticTypeLiteralInteger :: Integer -> SemanticType phase
  SemanticTypeLiteralString :: Text -> SemanticType phase
  SemanticTypeLiteralBoolean :: Bool -> SemanticType phase
  -- Composite types. Function parameters are keyed by label; their order is
  -- not significant (named-parameter calling convention). Two functions with
  -- the same label set and pointwise-equal types are equal regardless of
  -- the order in which the user wrote them.
  SemanticTypeFunction ::
    Map Text (SemanticType phase) ->
    SemanticType phase ->
    SemanticRequest phase ->
    SemanticType phase
  -- | Top of the function-type lattice: any callable
  -- ('SemanticTypeFunction' with any params/return/effects) is a subtype.
  -- Callers can pass values typed as concrete functions to APIs expecting
  -- @function@ (e.g. @get_metadata(value: function)@) but cannot @call@
  -- a value typed at 'SemanticTypeFunctionAny' because the parameter
  -- shape is unknown. Used by reflection-style prims.
  SemanticTypeFunctionAny :: SemanticType phase
  SemanticTypeArray :: SemanticType phase -> SemanticType phase
  SemanticTypeTuple :: [SemanticType phase] -> SemanticType phase
  -- | Union of types. Convention: 0 or 2+ branches.
  SemanticTypeUnion :: [SemanticType phase] -> SemanticType phase
  -- | Reference to a @data@ declaration. Generics are not supported, so no
  -- parameter list.
  SemanticTypeData :: QualifiedName -> SemanticType phase
  -- | Structural object type with named fields. Not surfaced in the
  -- syntactic AST: synthesised by the constraint generator for "has field"
  -- constraints (e.g. field access on data values is encoded as
  -- @T \<: SemanticTypeObject {label: t_field}@). Convertible to / from
  -- JSON schema style records.
  SemanticTypeObject :: Map Text (SemanticType phase) -> SemanticType phase
  -- | @record[V]@ — homogeneous map from string keys to values of
  -- type @V@. Keys are implicitly @string@ because the wire form is
  -- plain JSON object syntax and JSON object keys are always
  -- strings. Distinct from 'SemanticTypeObject' (= statically-known
  -- field labels) — a @record@ has a runtime-dynamic key set.
  SemanticTypeRecord :: SemanticType phase -> SemanticType phase

deriving instance Show (SemanticType phase)

deriving instance Eq (SemanticType phase)

deriving instance Ord (SemanticType phase)

-- | Smart constructor for 'SemanticTypeUnion'. The convention is that a
-- union always has 0 or 2+ branches; a singleton list is flattened to its
-- contained type, and an empty list collapses to 'SemanticTypeNever' (the
-- bottom of the lattice). Always prefer this helper over the raw
-- 'SemanticTypeUnion' constructor when the branch count is computed
-- dynamically (e.g. after @nub@ or filtering).
unionSemantic :: [SemanticType phase] -> SemanticType phase
unionSemantic = \case
  [] -> SemanticTypeNever
  [single] -> single
  branches -> SemanticTypeUnion branches

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | An request set is the disjoint sum of "request type variables that have
-- not yet been resolved" and "concrete @req@ VariableIds that have already
-- been pinned down". Subtyping on requests is just set inclusion on both
-- components.
--
-- The @phase@ parameter is phantom: at @Resolved@ phase the
-- 'requestVars' field is required to be empty (the solver enforces this when
-- zonking), but the type system does not enforce it. Keeping the same
-- representation across phases lets the same operations (union, equality)
-- work without case splits.
data SemanticRequest phase where
  SemanticRequest :: Set (SemanticRequestElement phase) -> SemanticRequest phase

deriving instance Show (SemanticRequest phase)

deriving instance Eq (SemanticRequest phase)

deriving instance Ord (SemanticRequest phase)

-- | One member of a 'SemanticRequest' set. A concrete element points at
-- a specific @req@ declaration by 'RequestId' and is valid in any
-- phase. A variable element stands for an unsolved request-row
-- placeholder introduced by the constraint generator and only exists
-- at @Unresolved@ phase; the solver discharges it before zonking, so
-- after zonk a @SemanticRequest Resolved@ contains concrete elements
-- only.
data SemanticRequestElement phase where
  SemanticRequestElementVariable :: RequestVariableId -> SemanticRequestElement Unresolved
  SemanticRequestElementConcrete :: QualifiedName -> SemanticRequestElement phase

deriving instance Show (SemanticRequestElement phase)

deriving instance Eq (SemanticRequestElement phase)

deriving instance Ord (SemanticRequestElement phase)

-- | The empty request set. Represents \"this expression performs no
-- request\". Identity for 'unionRequests'.
emptyRequest :: SemanticRequest phase
emptyRequest = SemanticRequest Set.empty

-- | A request set containing exactly one concrete request. Used when
-- the constraint generator records that a particular call site triggers
-- a specific declared @req@.
singletonRequest :: QualifiedName -> SemanticRequest phase
singletonRequest requestId = SemanticRequest (Set.singleton (SemanticRequestElementConcrete requestId))

-- | A request set containing exactly one row-variable placeholder.
-- The constraint generator emits this when it does not yet know which
-- concrete request(s) an expression will perform; the solver later
-- substitutes a concrete 'SemanticRequest' for the variable. Only
-- valid at @Unresolved@ phase.
singletonRequestVariable :: RequestVariableId -> SemanticRequest Unresolved
singletonRequestVariable varId = SemanticRequest (Set.singleton (SemanticRequestElementVariable varId))

-- | Set union over request elements. Used to combine the request sets
-- of subexpressions (@e1 + e2@'s requests = @e1@'s ∪ @e2@'s).
unionRequests :: SemanticRequest phase -> SemanticRequest phase -> SemanticRequest phase
unionRequests (SemanticRequest elements1) (SemanticRequest elements2) =
  SemanticRequest (Set.union elements1 elements2)

-- | Applicative traversal that rewrites every type variable and every
-- request variable inside a 'SemanticType', threading the user's
-- effects (substitution lookup, error accumulation, ...) through the
-- structure. The two callbacks decide what each leaf becomes, and the
-- traversal handles all the structural cases (function / array / tuple
-- / union / object / ...) uniformly. Building blocks 'foldVariable' is
-- the @Const@-specialised pure-fold variant of this.
substituteVariable ::
  (Applicative f) =>
  (TypeVariableId -> f (SemanticType phase)) ->
  (RequestVariableId -> f (SemanticRequest phase)) ->
  SemanticType phase' ->
  f (SemanticType phase)
substituteVariable onVariable onRequest = \case
  SemanticTypeVariable varId -> onVariable varId
  SemanticTypeFunction parameters returnType requests ->
    SemanticTypeFunction
      <$> traverse (substituteVariable onVariable onRequest) parameters
      <*> substituteVariable onVariable onRequest returnType
      <*> substituteRequestVariable requests
  SemanticTypeArray element -> SemanticTypeArray <$> substituteVariable onVariable onRequest element
  SemanticTypeTuple elements -> SemanticTypeTuple <$> traverse (substituteVariable onVariable onRequest) elements
  SemanticTypeUnion branches -> SemanticTypeUnion <$> traverse (substituteVariable onVariable onRequest) branches
  SemanticTypeObject fields -> SemanticTypeObject <$> traverse (substituteVariable onVariable onRequest) fields
  SemanticTypeRecord valueType ->
    SemanticTypeRecord <$> substituteVariable onVariable onRequest valueType
  SemanticTypeNever -> pure SemanticTypeNever
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  SemanticTypeFunctionAny -> pure SemanticTypeFunctionAny
  SemanticTypeNull -> pure SemanticTypeNull
  SemanticTypeInteger -> pure SemanticTypeInteger
  SemanticTypeNumber -> pure SemanticTypeNumber
  SemanticTypeString -> pure SemanticTypeString
  SemanticTypeSecret -> pure SemanticTypeSecret
  SemanticTypeFile -> pure SemanticTypeFile
  SemanticTypeBoolean -> pure SemanticTypeBoolean
  SemanticTypeLiteralInteger value -> pure (SemanticTypeLiteralInteger value)
  SemanticTypeLiteralString value -> pure (SemanticTypeLiteralString value)
  SemanticTypeLiteralBoolean value -> pure (SemanticTypeLiteralBoolean value)
  SemanticTypeData typeId -> pure (SemanticTypeData typeId)
  where
    substituteRequestVariable (SemanticRequest elements) =
      foldr unionRequests emptyRequest
        <$> traverse substituteElement (Set.toList elements)
      where
        substituteElement = \case
          SemanticRequestElementVariable variableId -> onRequest variableId
          SemanticRequestElementConcrete requestId -> pure (singletonRequest requestId)

-- | Read-only traversal: collect a monoidal summary of every type
-- variable and every request variable that occurs anywhere inside a
-- 'SemanticType'. Used for free-variable computation, occurs checks,
-- and pretty printing. The 'Monoid' choice (e.g. @Set TypeVariableId@,
-- @Any@, @Sum Int@) picks the analysis.
foldVariable ::
  (Monoid m) =>
  (TypeVariableId -> m) ->
  (RequestVariableId -> m) ->
  SemanticType phase ->
  m
foldVariable onVariable onRequest = getConst . substituteVariable (Const . onVariable) (Const . onRequest)

-- | Re-tag a 'Resolved' semantic type as 'Unresolved'. Sound because the
-- 'SemanticTypeVariable' constructor only exists at @Unresolved@ phase, so a
-- @SemanticType Resolved@ value structurally cannot contain anything that is
-- not also a valid 'Unresolved' shape. The @onVariable@ closure is statically
-- unreachable; supplying a sentinel so we don't have to call 'error' there.
liftResolvedToUnresolved :: SemanticType Resolved -> SemanticType Unresolved
liftResolvedToUnresolved =
  runIdentity
    . substituteVariable
      (\_ -> Identity SemanticTypeNever)
      (\_ -> Identity emptyRequest)

-- | Re-tag a 'Resolved' request set as 'Unresolved'. See
-- 'liftResolvedToUnresolved' for the soundness argument.
liftRequestResolvedToUnresolved :: SemanticRequest Resolved -> SemanticRequest Unresolved
liftRequestResolvedToUnresolved (SemanticRequest elements) =
  SemanticRequest (Set.fromList (map liftElement (Set.toList elements)))
  where
    liftElement :: SemanticRequestElement Resolved -> SemanticRequestElement Unresolved
    liftElement (SemanticRequestElementConcrete reqId) = SemanticRequestElementConcrete reqId
