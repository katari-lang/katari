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
    effectVarsIn,
    isTypeConstraint,
    isEffectConstraint,
  )
where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.Identifier (VariableId)
import Katari.Typechecker.NormalizedType
  ( NormalizedType,
    normaliseSemantic,
    subtypeNT,
  )
import Katari.Typechecker.SemanticType
  ( EffectVarId,
    Resolved,
    SemanticEffect (..),
    SemanticType (..),
    TypeVarId,
    Unresolved,
    foldSemantic,
    traverseSemanticChildren,
  )

-- ===========================================================================
-- Result types
-- ===========================================================================

-- | Constraint solver の最終出力。'typeSubstitution' / 'effectSubstitution'
-- は ConstraintGenerator が allocate した全 ID をカバーする (Zonker plan で
-- 確定済 total 契約)。解決不能な制約は 'solverErrors' に記録され、対応する
-- var は NTUnknown / 空 set にフォールバック。
data SolverResult = SolverResult
  { typeSubstitution :: !(Map TypeVarId NormalizedType),
    effectSubstitution :: !(Map EffectVarId (Set VariableId)),
    solverErrors :: ![SolverError]
  }
  deriving (Show)

-- | Solver が検出した型エラー。各 variant は元 'ConstraintReason' を保持し、
-- diagnostics で正確な位置を報告できるようにする。
data SolverError where
  SolverErrorContradiction ::
    ConstraintReason ->
    SemanticType Resolved ->
    SemanticType Resolved ->
    SolverError
  SolverErrorBoundsConflict ::
    TypeVarId ->
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

type Substitution = Map TypeVarId (SemanticType Unresolved)

data BoundedType = BoundedType
  { boundType :: !(SemanticType Unresolved),
    boundReason :: !ConstraintReason
  }
  deriving (Eq, Show)

data Bounds = Bounds
  { lowerBounds :: ![BoundedType],
    upperBounds :: ![BoundedType]
  }
  deriving (Eq, Show)

emptyBounds :: Bounds
emptyBounds = Bounds {lowerBounds = [], upperBounds = []}

-- ===========================================================================
-- Conversion helpers
-- ===========================================================================

-- | 'SemanticType' 'Unresolved' (no vars) -> 'SemanticType' 'Resolved'.
-- Returns 'Nothing' iff the input contains any 'SemanticTypeVariable' or any
-- function effect set with unresolved 'EffectVarId's. The structural recursion
-- is delegated to 'traverseSemanticChildren'; this body only handles the
-- two phase-changing concerns (variable elimination, effect concreteness).
semanticToConcrete :: SemanticType Unresolved -> Maybe (SemanticType Resolved)
semanticToConcrete = \case
  SemanticTypeVariable _ -> Nothing
  t -> traverseSemanticChildren semanticToConcrete concretiseEffect t
  where
    concretiseEffect (SemanticEffect vars reqs)
      | Set.null vars = Just (SemanticEffect Set.empty reqs)
      | otherwise = Nothing

-- | Subtype check between two var-free 'SemanticType' values via
-- 'NormalizedType.subtypeNT'. Caller MUST 'containsNoTypeVars' both sides.
isSubtypeConcrete :: SemanticType Unresolved -> SemanticType Unresolved -> Bool
isSubtypeConcrete leftType rightType =
  case (semanticToConcrete leftType, semanticToConcrete rightType) of
    (Just leftConcrete, Just rightConcrete) ->
      subtypeNT (normaliseSemantic leftConcrete) (normaliseSemantic rightConcrete)
    _ -> False

-- ===========================================================================
-- Variable predicates / collection
-- ===========================================================================

containsNoTypeVars :: SemanticType Unresolved -> Bool
containsNoTypeVars = Set.null . typeVarsIn

-- | Free 'TypeVarId's appearing anywhere in the type. Variable case is
-- handled directly; everything else delegates to 'foldSemantic'.
typeVarsIn :: SemanticType Unresolved -> Set TypeVarId
typeVarsIn = \case
  SemanticTypeVariable typeVarId -> Set.singleton typeVarId
  t -> foldSemantic typeVarsIn (const Set.empty) t

-- | Free 'EffectVarId's appearing anywhere in the type. Function nodes are
-- the only constructors that carry effects; 'foldSemantic' delivers each
-- 'SemanticEffect' to the second argument.
effectVarsIn :: SemanticType Unresolved -> Set EffectVarId
effectVarsIn = foldSemantic effectVarsIn (.effectVars)

constraintTypeVars :: Constraint -> Set TypeVarId
constraintTypeVars = \case
  TypeConstraint leftType rightType _ ->
    Set.union (typeVarsIn leftType) (typeVarsIn rightType)
  EffectConstraint {} -> Set.empty

-- ===========================================================================
-- Constraint partitioning
-- ===========================================================================

isTypeConstraint :: Constraint -> Bool
isTypeConstraint = \case
  TypeConstraint {} -> True
  _ -> False

isEffectConstraint :: Constraint -> Bool
isEffectConstraint = \case
  EffectConstraint {} -> True
  _ -> False
