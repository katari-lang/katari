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

    -- * Effects
    SemanticEffect (..),
    emptyEffect,
    singletonEffect,
    effectFromVar,
    unionEffects,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Map.Strict (Map)
import Data.Text (Text)
import Katari.Typechecker.Identifier (TypeId, VariableId)

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
  -- Composite types.
  SemanticTypeFunction
    :: [(Text, SemanticType phase)]
    -> SemanticType phase
    -> SemanticEffect phase
    -> SemanticType phase
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
  deriving (Eq, Show)

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
