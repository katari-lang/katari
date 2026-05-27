-- | Internal types and helpers shared by the Solver pipeline.
--
-- Sub-modules ('Decompose', 'Branch', 'Substitution', etc.) import from this
-- module instead of 'Katari.Typechecker.Solver' so that the top-level
-- 'Solver' module can depend on the sub-modules without creating an import
-- cycle.
module Katari.Typechecker.Solver.Internal
  ( -- * Result
    SolverResult (..),
    SolverError (..),

    -- * Internal types
    Substitution,
    VarBounds (..),
    BoundsMap,
    VarGraph,
    emptyVarBounds,

    -- * Helpers
    semanticToConcrete,
    containsNoTypeVars,
    typeVarsIn,
    isTypeConstraint,
    isRequestConstraint,
  )
where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Common (QualifiedName)
import Katari.SemanticType
  ( RequestVariableId,
    Resolved,
    SemanticType (..),
    TypeVariableId,
    Unresolved,
    foldVariable,
    substituteVariable,
  )
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.NormalizedType
  ( NormalizedType (..),
    emptyLayered,
  )

-- ===========================================================================
-- Result types
-- ===========================================================================

-- | Final output of the constraint solver. 'typeSubstitution' /
-- 'requestSubstitution' cover every ID allocated by the
-- ConstraintGenerator (totality is part of the Zonker-plan contract).
-- Unresolvable constraints are recorded in the right side of the 'solve'
-- result tuple ([SolverError]); the corresponding vars fall back to
-- NormalizedTypeUnknown / the empty set.
data SolverResult = SolverResult
  { typeSubstitution :: Map TypeVariableId NormalizedType,
    requestSubstitution :: Map RequestVariableId (Set QualifiedName)
  }
  deriving (Show)

-- | A type error detected by the Solver. Each variant carries the
-- original 'ConstraintReason' so diagnostics can report the precise
-- location.
data SolverError where
  SolverErrorContradiction ::
    ConstraintReason ->
    SemanticType Resolved ->
    SemanticType Resolved ->
    SolverError
  SolverErrorBoundsConflict ::
    TypeVariableId ->
    ConstraintReason ->
    SemanticType Resolved ->
    ConstraintReason ->
    SemanticType Resolved ->
    SolverError
  SolverErrorStructuralMismatch ::
    ConstraintReason ->
    Text ->
    SolverError

deriving instance Eq SolverError

deriving instance Show SolverError

-- ===========================================================================
-- Internal types
-- ===========================================================================

type Substitution = Map TypeVariableId (SemanticType Unresolved)

-- | Per-variable bounds in the bound-pair Solver model.
--
-- Each type variable carries a SINGLE normalized lower (= union of every
-- concrete flow into the variable) and a SINGLE normalized upper (=
-- intersection of every concrete constraint flowing out of the variable).
-- This replaces the older list-of-'BoundedType' model: as soon as a new
-- concrete bound arrives, it is folded into the existing one via
-- 'unionNT' / 'intersectNT', so the bounds are always already-aggregated.
--
-- The 'lowerReasons' / 'upperReasons' lists keep the originating
-- 'ConstraintReason' of every contribution for diagnostics — the lattice
-- collapse loses per-contribution shape, but we still want to point users
-- at the source spans when a bounds conflict surfaces.
--
-- Initial state: lower = 'NTNever' (= 'NormalizedTypeLayered' 'emptyLayered'),
-- upper = 'NormalizedTypeUnknown'. Both bounds are vacuously satisfied by
-- any value; the variable is "unconstrained" until something is added.
data VarBounds = VarBounds
  { vbLower :: NormalizedType,
    vbUpper :: NormalizedType,
    vbLowerReasons :: [ConstraintReason],
    vbUpperReasons :: [ConstraintReason]
  }
  deriving (Eq, Show)

emptyVarBounds :: VarBounds
emptyVarBounds =
  VarBounds
    { vbLower = NormalizedTypeLayered emptyLayered,
      vbUpper = NormalizedTypeUnknown,
      vbLowerReasons = [],
      vbUpperReasons = []
    }

type BoundsMap = Map TypeVariableId VarBounds

-- | Adjacency for the var-on-var subtype graph: each entry @α ↦ {β₁, β₂}@
-- records edges @α ⊑ β₁@ and @α ⊑ β₂@. After the worklist settles, the
-- transitive closure of this graph drives bound propagation through
-- variable chains (= @α ⊑ β ⊑ γ@ implies α's upper inherits γ's upper
-- and γ's lower inherits α's lower).
type VarGraph = Map TypeVariableId (Set TypeVariableId)

-- ===========================================================================
-- Conversion helpers
-- ===========================================================================

-- | 'SemanticType' 'Unresolved' (no vars) -> 'SemanticType' 'Resolved'.
-- Returns 'Nothing' iff the input contains any 'SemanticTypeVariable' or any
-- function request set with unresolved 'RequestVariableId's. The structural recursion
-- is delegated to 'traverseSemanticChildren'; this body only handles the
-- two phase-changing concerns (variable elimination, request concreteness).
semanticToConcrete :: SemanticType Unresolved -> Maybe (SemanticType Resolved)
semanticToConcrete =
  substituteVariable
    (const Nothing)
    (const Nothing)

-- ===========================================================================
-- Variable predicates / collection
-- ===========================================================================

containsNoTypeVars :: SemanticType Unresolved -> Bool
containsNoTypeVars = Set.null . typeVarsIn

-- | Free 'TypeVariableId's appearing anywhere in the type. Variable case is
-- handled directly; everything else delegates to 'foldSemantic'.
typeVarsIn :: SemanticType Unresolved -> Set TypeVariableId
typeVarsIn =
  foldVariable
    Set.singleton
    (const Set.empty)

-- ===========================================================================
-- Constraint partitioning
-- ===========================================================================

isTypeConstraint :: Constraint -> Bool
isTypeConstraint = \case
  TypeConstraint {} -> True
  _ -> False

isRequestConstraint :: Constraint -> Bool
isRequestConstraint = \case
  RequestConstraint {} -> True
  _ -> False
