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
-- 'NormalizedType' (see 'Katari.Typechecker.NormalizedType') is yet another
-- representation that further normalises union / tuple shapes for use by the
-- constraint solver.
module Katari.Typechecker.SemanticType
  ( -- * Phase markers
    Unresolved,
    Resolved,

    -- * Type variables
    TypeVarId (..),
    EffectVarId (..),

    -- * Semantic types
    SemanticType (..),

    -- * Smart constructors
    unionSemantic,

    -- * Effects
    SemanticEffect (..),
    emptyEffect,
    singletonEffect,
    effectFromVar,
    unionEffects,

    -- * Traversal
    traverseSemantic,
    foldSemantic,
    traverseSemanticChildren,
  )
where

import Data.Functor.Const (Const (..))
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST (ExprType, PatType, Phase (..))
import Katari.AST.Identifiers (TypeId, VariableId)

-- ---------------------------------------------------------------------------
-- Phase markers
-- ---------------------------------------------------------------------------

-- | Phase tag for @SemanticType@ values that may still contain unification
-- variables (constraint generation phase).
data Unresolved

-- | Phase tag for @SemanticType@ values that are guaranteed to contain no
-- unification variables (after the constraint solver has run).
data Resolved

-- ---------------------------------------------------------------------------
-- Type / effect variables
-- ---------------------------------------------------------------------------

-- | Unification variable id. Allocated by the constraint generator and
-- substituted away by the solver.
newtype TypeVarId = TypeVarId Int
  deriving (Eq, Ord, Show)

-- | Effect variable id. Used to bound an effect set whose membership is not
-- yet known at constraint generation time.
newtype EffectVarId = EffectVarId Int
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
  SemanticTypeVariable :: TypeVarId -> SemanticType Unresolved
  -- | Lattice bottom: no values inhabit this type.
  SemanticTypeNever :: SemanticType phase
  -- | Lattice top: any value satisfies this type.
  SemanticTypeUnknown :: SemanticType phase
  -- Primitive (concrete) types.
  SemanticTypeNull :: SemanticType phase
  SemanticTypeInteger :: SemanticType phase
  SemanticTypeNumber :: SemanticType phase
  SemanticTypeString :: SemanticType phase
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
    SemanticEffect phase ->
    SemanticType phase
  SemanticTypeArray :: SemanticType phase -> SemanticType phase
  SemanticTypeTuple :: [SemanticType phase] -> SemanticType phase
  -- | Union of types. Convention: 0 or 2+ branches.
  SemanticTypeUnion :: [SemanticType phase] -> SemanticType phase
  -- | Reference to a @data@ declaration. Generics are not supported, so no
  -- parameter list.
  SemanticTypeData :: TypeId -> SemanticType phase
  -- | Structural object type with named fields. Not surfaced in the
  -- syntactic AST: synthesised by the constraint generator for "has field"
  -- constraints (e.g. field access on data values is encoded as
  -- @T \<: SemanticTypeObject {label: t_field}@). Convertible to / from
  -- JSON schema style records.
  SemanticTypeObject :: Map Text (SemanticType phase) -> SemanticType phase

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
-- Effects
-- ---------------------------------------------------------------------------

-- | An effect set is the disjoint sum of "effect type variables that have
-- not yet been resolved" and "concrete @req@ VariableIds that have already
-- been pinned down". Subtyping on effects is just set inclusion on both
-- components.
--
-- The @phase@ parameter is phantom: at @Resolved@ phase the
-- 'effectVars' field is required to be empty (the solver enforces this when
-- zonking), but the type system does not enforce it. Keeping the same
-- representation across phases lets the same operations (union, equality)
-- work without case splits.
data SemanticEffect phase = SemanticEffect
  { effectVars :: !(Set EffectVarId),
    effectReqs :: !(Set VariableId)
  }
  deriving (Eq, Ord, Show)

-- | The empty effect set (i.e. "pure"; no effects raised).
emptyEffect :: SemanticEffect phase
emptyEffect = SemanticEffect Set.empty Set.empty

-- | Effect set containing exactly one concrete @req@.
singletonEffect :: VariableId -> SemanticEffect phase
singletonEffect requestId = SemanticEffect Set.empty (Set.singleton requestId)

-- | Effect set containing exactly one fresh effect variable.
effectFromVar :: EffectVarId -> SemanticEffect Unresolved
effectFromVar effectVarId = SemanticEffect (Set.singleton effectVarId) Set.empty

-- | Pointwise union of two effect sets.
unionEffects :: SemanticEffect phase -> SemanticEffect phase -> SemanticEffect phase
unionEffects (SemanticEffect leftVars leftReqs) (SemanticEffect rightVars rightReqs) =
  SemanticEffect (Set.union leftVars rightVars) (Set.union leftReqs rightReqs)

-- ---------------------------------------------------------------------------
-- ExprType / PatType instances for the typed phases (Trees-that-Grow)
--
-- These complete the open type families declared in 'Katari.AST'. The
-- 'Parsed' / 'Identified' phases (no type info yet) supply '()' there; the
-- 'Constrained' / 'Zonked' phases plug in the actual semantic type carrier
-- here.
-- ---------------------------------------------------------------------------

type instance ExprType Constrained = SemanticType Unresolved

type instance ExprType Zonked = SemanticType Resolved

type instance PatType Constrained = SemanticType Unresolved

type instance PatType Zonked = SemanticType Resolved

-- ---------------------------------------------------------------------------
-- Generic traversal (uniplate-style)
--
-- A single recursion skeleton for 'SemanticType' — the same shape that used
-- to be re-implemented by hand in:
--
--   * Solver.Internal.typeVarsIn / effectVarsIn / semanticToConcrete
--   * Solver.Substitution.applySubstType / applyEffectSubstToType /
--     resolvedToUnresolved
--   * Zonker.zonkType (the bulk of its body)
--
-- Each of those used to do its own 14-case @\\case@ over every composite /
-- leaf constructor. Funnelling the recursion through 'traverseSemantic' lets
-- callers focus on the cases that are actually special for their own logic
-- (typically just 'SemanticTypeVariable') and delegate the rest. The
-- pattern-match fan-out shrinks from ~14 lines per walker to ~3.
--
-- Phase-preserving by design: every leaf constructor that exists at multiple
-- phases is reconstructed unchanged so that 'p' on input matches 'p' on
-- output. The 'SemanticTypeVariable' constructor is GADT-restricted to
-- @SemanticType Unresolved@; we 'pure' it through verbatim, which type-checks
-- because pattern-matching on 'SemanticTypeVariable' refines @p ~ Unresolved@.
--
-- Callers that *change* phase (e.g. 'semanticToConcrete' going Unresolved →
-- Resolved by rejecting variables) handle the 'SemanticTypeVariable' case
-- themselves before delegating composites to 'traverseSemantic'. Those uses
-- happen to be in the same phase on both sides; cross-phase callers should
-- intercept the variable case first.
-- ---------------------------------------------------------------------------

-- | Generic traversal over the children of a 'SemanticType' node. Composite
-- constructors recurse via 'onType' / 'onEffect'; leaf constructors are
-- reconstructed verbatim.
traverseSemantic ::
  (Applicative f) =>
  (SemanticType p -> f (SemanticType p)) ->
  (SemanticEffect p -> f (SemanticEffect p)) ->
  SemanticType p ->
  f (SemanticType p)
traverseSemantic onType onEffect = \case
  -- Composites: recurse on children.
  SemanticTypeFunction parameters returnType effects ->
    SemanticTypeFunction
      <$> traverse onType parameters
      <*> onType returnType
      <*> onEffect effects
  SemanticTypeArray element -> SemanticTypeArray <$> onType element
  SemanticTypeTuple elements -> SemanticTypeTuple <$> traverse onType elements
  SemanticTypeUnion branches -> SemanticTypeUnion <$> traverse onType branches
  SemanticTypeObject fields -> SemanticTypeObject <$> traverse onType fields
  -- Leaves: pass through. Pattern-matching the GADT 'SemanticTypeVariable'
  -- refines @p ~ Unresolved@ in this branch, so 'pure' returns the right
  -- output type.
  SemanticTypeVariable typeVarId -> pure (SemanticTypeVariable typeVarId)
  SemanticTypeNever -> pure SemanticTypeNever
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  SemanticTypeNull -> pure SemanticTypeNull
  SemanticTypeInteger -> pure SemanticTypeInteger
  SemanticTypeNumber -> pure SemanticTypeNumber
  SemanticTypeString -> pure SemanticTypeString
  SemanticTypeBoolean -> pure SemanticTypeBoolean
  SemanticTypeLiteralInteger value -> pure (SemanticTypeLiteralInteger value)
  SemanticTypeLiteralString value -> pure (SemanticTypeLiteralString value)
  SemanticTypeLiteralBoolean value -> pure (SemanticTypeLiteralBoolean value)
  SemanticTypeData typeId -> pure (SemanticTypeData typeId)

-- | Monoidal fold over the immediate children. Convenience wrapper around
-- @'traverseSemantic'@ specialised to @'Const' m@. Use this for "collect all
-- 'TypeVarId's" / "collect all 'EffectVarId's" style queries — the
-- 'SemanticTypeVariable' case is *not* special-cased here; it contributes
-- 'mempty', so callers that want to extract the variable should pre-empt
-- the variable branch themselves.
foldSemantic ::
  (Monoid m) =>
  (SemanticType p -> m) ->
  (SemanticEffect p -> m) ->
  SemanticType p ->
  m
foldSemantic onType onEffect t =
  getConst (traverseSemantic (Const . onType) (Const . onEffect) t)

-- | Phase-changing variant of 'traverseSemantic'. The leaf constructors are
-- phase-polymorphic (every leaf except 'SemanticTypeVariable') so they can
-- be reconstructed at the target phase without information loss; the
-- 'SemanticTypeVariable' case must be intercepted by the caller before
-- dispatching to this helper.
--
-- Used by 'semanticToConcrete' (Unresolved → Resolved, Variable → Nothing),
-- 'resolvedToUnresolved' (Resolved → Unresolved, no Variable case to worry
-- about), and 'zonkType' (Unresolved → Resolved, Variable resolved via
-- substitution map).
--
-- Calling this on a value whose head is 'SemanticTypeVariable' is a
-- programmer error and aborts with a clear message.
traverseSemanticChildren ::
  (Applicative f) =>
  (SemanticType p -> f (SemanticType q)) ->
  (SemanticEffect p -> f (SemanticEffect q)) ->
  SemanticType p ->
  f (SemanticType q)
traverseSemanticChildren onType onEffect = \case
  -- Variable: caller's responsibility.
  SemanticTypeVariable _ ->
    error "traverseSemanticChildren: SemanticTypeVariable must be handled by caller before recursing"
  -- Composites: recurse on children.
  SemanticTypeFunction parameters returnType effects ->
    SemanticTypeFunction
      <$> traverse onType parameters
      <*> onType returnType
      <*> onEffect effects
  SemanticTypeArray element -> SemanticTypeArray <$> onType element
  SemanticTypeTuple elements -> SemanticTypeTuple <$> traverse onType elements
  SemanticTypeUnion branches -> SemanticTypeUnion <$> traverse onType branches
  SemanticTypeObject fields -> SemanticTypeObject <$> traverse onType fields
  -- Leaves: rebuild at the target phase. All of these constructors are
  -- phase-polymorphic so this is well-typed for any 'q'.
  SemanticTypeNever -> pure SemanticTypeNever
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  SemanticTypeNull -> pure SemanticTypeNull
  SemanticTypeInteger -> pure SemanticTypeInteger
  SemanticTypeNumber -> pure SemanticTypeNumber
  SemanticTypeString -> pure SemanticTypeString
  SemanticTypeBoolean -> pure SemanticTypeBoolean
  SemanticTypeLiteralInteger value -> pure (SemanticTypeLiteralInteger value)
  SemanticTypeLiteralString value -> pure (SemanticTypeLiteralString value)
  SemanticTypeLiteralBoolean value -> pure (SemanticTypeLiteralBoolean value)
  SemanticTypeData typeId -> pure (SemanticTypeData typeId)
