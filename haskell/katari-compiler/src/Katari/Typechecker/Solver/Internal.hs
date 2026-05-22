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
    BoundedType (..),
    Bounds (..),
    emptyBounds,

    -- * Helpers
    semanticToConcrete,
    isSubtypeConcrete,
    containsNoTypeVars,
    constraintTypeVars,
    typeVarsIn,
    requestVarsIn,
    isTypeConstraint,
    isRequestConstraint,
  )
where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Id (RequestId)
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
  ( NormalizedType,
    normaliseSemantic,
    subtypeNormalizedType,
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
    requestSubstitution :: Map RequestVariableId (Set RequestId)
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

data BoundedType = BoundedType
  { boundType :: SemanticType Unresolved,
    boundReason :: ConstraintReason
  }
  deriving (Eq, Show)

data Bounds = Bounds
  { lowerBounds :: [BoundedType],
    upperBounds :: [BoundedType]
  }
  deriving (Eq, Show)

emptyBounds :: Bounds
emptyBounds = Bounds {lowerBounds = [], upperBounds = []}

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

-- | Subtype check between two var-free 'SemanticType' values via
-- 'NormalizedType.subtypeNormalizedType'. Caller MUST 'containsNoTypeVars' both sides.
isSubtypeConcrete :: SemanticType Unresolved -> SemanticType Unresolved -> Bool
isSubtypeConcrete leftType rightType =
  case (semanticToConcrete leftType, semanticToConcrete rightType) of
    (Just leftConcrete, Just rightConcrete) ->
      subtypeNormalizedType (normaliseSemantic leftConcrete) (normaliseSemantic rightConcrete)
    _ -> False

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

-- | Free 'RequestVariableId's appearing anywhere in the type. Function nodes are
-- the only constructors that carry requests; 'foldSemantic' delivers each
-- 'SemanticRequest' to the second argument.
requestVarsIn :: SemanticType Unresolved -> Set RequestVariableId
requestVarsIn =
  foldVariable
    (const Set.empty)
    Set.singleton

constraintTypeVars :: Constraint -> Set TypeVariableId
constraintTypeVars = \case
  TypeConstraint leftType rightType _ ->
    Set.union (typeVarsIn leftType) (typeVarsIn rightType)
  RequestConstraint {} -> Set.empty

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
