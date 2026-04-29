-- | Constraint branching for the Solver.
--
-- When the decomposer is stuck on a constraint of the form
--
--   * @α \<: composite@ — type var on the left, composite (function /
--     array / tuple / object) on the right; or
--   * @composite \<: α@ — symmetric;
--   * @t \<: (B | C)@ — RHS union of two non-trivial branches;
--
-- we cannot make progress purely by structural decomposition. Instead, we
-- fan out into multiple alternative subgoals: pick fresh sub-vars to "narrow"
-- the variable's shape, OR commit the variable to 'never' / 'unknown'.
--
-- 'branchConstraint' returns a list of alternative branches. Each branch is
-- a triple @(subst, newConstraints, nextTypeVarId)@: the variable
-- assignment, additional constraints to satisfy, and the updated TypeVar
-- counter (since branching may allocate fresh vars).
--
-- 'branchConstraints' picks the first branchable constraint in the worklist
-- and fans it out, leaving the rest of the constraints untouched.
module Katari.Typechecker.Solver.Branch
  ( BranchAlt (..),
    branchConstraint,
    branchConstraints,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.SemanticType
  ( EffectVarId (..),
    SemanticEffect (..),
    SemanticType (..),
    TypeVarId (..),
    Unresolved,
  )
import Katari.Typechecker.Solver.Internal
  ( Substitution,
    typeVarsIn,
  )

-- | Which side of a stuck @α \<: composite@ constraint α sits on. Drives the
-- variance of every sub-constraint emitted by 'narrowShape': swapping the
-- side flips both the @<:@ direction (covariant ↔ contravariant flip per
-- position) and the fallback assignment ('Never' for left-α; 'Unknown' for
-- right-α).
data BranchSide where
  LeftVar :: BranchSide
  RightVar :: BranchSide
  deriving (Eq, Show)

-- ===========================================================================
-- BranchAlt
-- ===========================================================================

-- | One alternative produced by branching: the partial substitution to
-- apply, the additional constraints to satisfy, and the updated counters
-- for fresh-var allocation (both type and effect).
data BranchAlt = BranchAlt
  { branchSubst :: !Substitution,
    branchNewConstraints :: !(Set Constraint),
    branchNextTypeVarId :: !Int,
    branchNextEffectVarId :: !Int
  }
  deriving (Show)

-- ===========================================================================
-- branchConstraint
-- ===========================================================================

-- | Branch a single constraint into one or more alternatives. Returns
-- 'Nothing' if the constraint is not branchable (the solver should
-- continue with bound aggregation / final-substitution collection).
--
-- The two 'Int' parameters are the next free TypeVarId / EffectVarId
-- counters; each branch may allocate fresh vars and updates them
-- accordingly.
branchConstraint :: Int -> Int -> Constraint -> Maybe [BranchAlt]
branchConstraint nextTypeVarId nextEffectVarId = \case
  TypeConstraint leftType rightType reason ->
    branchType nextTypeVarId nextEffectVarId leftType rightType reason
  EffectConstraint {} -> Nothing

branchType ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Maybe [BranchAlt]
branchType nextTypeVarId nextEffectVarId leftType rightType reason =
  case (leftType, rightType) of
    -- α <: B | C : try α <: B OR α <: C.
    -- Only branch when LHS contains a type variable; if LHS is concrete the
    -- decomposer already settled or rejected this constraint via subtypeNT.
    (_, SemanticTypeUnion branches)
      | not (Set.null (typeVarsIn leftType)) ->
          Just
            [ BranchAlt
                { branchSubst = Map.empty,
                  branchNewConstraints =
                    Set.singleton (TypeConstraint leftType branch reason),
                  branchNextTypeVarId = nextTypeVarId,
                  branchNextEffectVarId = nextEffectVarId
                }
              | branch <- branches
            ]
    -- α <: composite (LHS is var, RHS has structure).
    (SemanticTypeVariable typeVarId, _)
      | isBranchableShape rightType ->
          Just
            ( branchVarOnLeft nextTypeVarId nextEffectVarId typeVarId rightType reason
            )
    -- composite <: α (RHS is var, LHS has structure).
    (_, SemanticTypeVariable typeVarId)
      | isBranchableShape leftType ->
          Just
            ( branchVarOnRight nextTypeVarId nextEffectVarId leftType typeVarId reason
            )
    _ -> Nothing

-- | True iff the shape has internal structure that warrants branching.
-- Primitives, literals, and bare data refs don't need branching — bound
-- aggregation handles them.
isBranchableShape :: SemanticType Unresolved -> Bool
isBranchableShape = \case
  SemanticTypeFunction {} -> True
  SemanticTypeArray _ -> True
  SemanticTypeTuple _ -> True
  SemanticTypeObject _ -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Variance-flipping helpers
-- ---------------------------------------------------------------------------

-- | Emit a constraint at a covariant position. \"Covariant\" means α-position
-- and original-position align with the @<:@ direction set by 'side': for
-- 'LeftVar' (α \<: F) the flow is @α-pos \<: F-pos@, and for 'RightVar' it
-- reverses.
emitCovariantType ::
  BranchSide ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Constraint
emitCovariantType side variableSide originalSide reason = case side of
  LeftVar -> TypeConstraint variableSide originalSide reason
  RightVar -> TypeConstraint originalSide variableSide reason

-- | Emit a constraint at a contravariant position (function parameters).
-- Same as 'emitCovariantType' but with the side flipped.
emitContravariantType ::
  BranchSide ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Constraint
emitContravariantType side = emitCovariantType (flipSide side)

-- | Effect-constraint counterpart of 'emitCovariantType'.
emitCovariantEffect ::
  BranchSide ->
  SemanticEffect Unresolved ->
  SemanticEffect Unresolved ->
  ConstraintReason ->
  Constraint
emitCovariantEffect side variableSide originalSide reason = case side of
  LeftVar -> EffectConstraint variableSide originalSide reason
  RightVar -> EffectConstraint originalSide variableSide reason

flipSide :: BranchSide -> BranchSide
flipSide = \case
  LeftVar -> RightVar
  RightVar -> LeftVar

-- ---------------------------------------------------------------------------
-- branchVar : unified narrow + fallback for both α \<: F and F \<: α
-- ---------------------------------------------------------------------------

branchVarOnLeft ::
  Int ->
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnLeft = branchVar LeftVar

branchVarOnRight ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  TypeVarId ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnRight nextTypeVarId nextEffectVarId shape typeVarId =
  branchVar RightVar nextTypeVarId nextEffectVarId typeVarId shape

-- | Two alternatives for a stuck @α \<: F@ or @F \<: α@:
--
--   1. α takes the structural shape with fresh sub-vars (variance constraints
--      are emitted via 'narrowShape').
--   2. α := 'SemanticTypeNever' (for 'LeftVar', vacuously @α \<: anything@) or
--      α := 'SemanticTypeUnknown' (for 'RightVar', vacuously @anything \<: α@).
branchVar ::
  BranchSide ->
  Int ->
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVar side nextTypeVarId nextEffectVarId typeVarId shape reason =
  let (narrowedShape, freshConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter) =
        narrowShape side nextTypeVarId nextEffectVarId shape reason
      fallback = case side of
        LeftVar -> SemanticTypeNever
        RightVar -> SemanticTypeUnknown
   in [ BranchAlt
          { branchSubst = Map.singleton typeVarId narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVarId = nextTypeVarIdAfter,
            branchNextEffectVarId = nextEffectVarIdAfter
          },
        BranchAlt
          { branchSubst = Map.singleton typeVarId fallback,
            branchNewConstraints = Set.empty,
            branchNextTypeVarId = nextTypeVarId,
            branchNextEffectVarId = nextEffectVarId
          }
      ]

-- | Build a fresh-var \"shape skeleton\" for α matching @shape@, plus the
-- variance-respecting sub-constraints. 'BranchSide' selects which side of
-- @<:@ α sits on, which flips every emitted constraint's direction.
--
-- For 'SemanticTypeFunction', a fresh 'EffectVarId' is allocated and an
-- effect constraint is added at the covariant position.
narrowShape ::
  BranchSide ->
  Int ->
  Int ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, Set Constraint, Int, Int)
narrowShape side nextTypeVarId nextEffectVarId shape reason = case shape of
  SemanticTypeFunction parameters returnType effects ->
    let parameterEntries = Map.toList parameters
        (parameterVars, nextAfterParams) = freshVars nextTypeVarId (length parameterEntries)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        (effectVar, nextEffectAfter) = freshEffectVar nextEffectVarId
        narrowedParameters =
          Map.fromList
            [ (label, SemanticTypeVariable parameterVar)
              | ((label, _), parameterVar) <- zip parameterEntries parameterVars
            ]
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (SemanticEffect (Set.singleton effectVar) Set.empty)
        parameterConstraints =
          [ emitContravariantType side (SemanticTypeVariable parameterVar) originalParameter reason
            | ((_, originalParameter), parameterVar) <- zip parameterEntries parameterVars
          ]
        returnConstraint =
          emitCovariantType side (SemanticTypeVariable returnVar) returnType reason
        effectConstraint =
          emitCovariantEffect
            side
            (SemanticEffect (Set.singleton effectVar) Set.empty)
            effects
            reason
     in ( narrowedShape,
          Set.fromList (effectConstraint : returnConstraint : parameterConstraints),
          nextAfterReturn,
          nextEffectAfter
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVarId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          emitCovariantType side (SemanticTypeVariable elementVar) element reason
     in (narrowedShape, Set.singleton elementConstraint, nextAfterElement, nextEffectVarId)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVarId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ emitCovariantType side (SemanticTypeVariable elementVar) originalElement reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, Set.fromList elementConstraints, nextAfterElements, nextEffectVarId)
  SemanticTypeObject fields ->
    let (fieldVars, nextAfterFields) = freshVars nextTypeVarId (Map.size fields)
        fieldLabels = Map.keys fields
        narrowedFields =
          Map.fromList (zip fieldLabels (SemanticTypeVariable <$> fieldVars))
        narrowedShape = SemanticTypeObject narrowedFields
        fieldConstraints =
          [ emitCovariantType side (SemanticTypeVariable fieldVar) originalField reason
            | (fieldVar, originalField) <- zip fieldVars (Map.elems fields)
          ]
     in (narrowedShape, Set.fromList fieldConstraints, nextAfterFields, nextEffectVarId)
  -- Defensive: 'isBranchableShape' guards the call site so this is unreachable.
  _ -> (shape, Set.empty, nextTypeVarId, nextEffectVarId)

-- ---------------------------------------------------------------------------
-- Fresh var allocation
-- ---------------------------------------------------------------------------

freshVar :: Int -> (TypeVarId, Int)
freshVar nextTypeVarId = (TypeVarId nextTypeVarId, nextTypeVarId + 1)

freshEffectVar :: Int -> (EffectVarId, Int)
freshEffectVar nextEffectVarId = (EffectVarId nextEffectVarId, nextEffectVarId + 1)

freshVars :: Int -> Int -> ([TypeVarId], Int)
freshVars nextTypeVarId 0 = ([], nextTypeVarId)
freshVars nextTypeVarId count =
  let (typeVarId, nextAfterFirst) = freshVar nextTypeVarId
      (remaining, nextAfterAll) = freshVars nextAfterFirst (count - 1)
   in (typeVarId : remaining, nextAfterAll)

-- ===========================================================================
-- branchConstraints
-- ===========================================================================

-- | Find the first branchable constraint in the list and fan it out.
-- Returns 'Nothing' if no constraint is branchable.
--
-- Each result is @(subst, newConstraintList, nextTypeVarId, nextEffectVarId)@:
-- the alt's substitution, the worklist after the branch (remaining
-- constraints + new sub-constraints, with the substitution applied), and
-- the updated counters.
branchConstraints ::
  Int ->
  Int ->
  Set Constraint ->
  Maybe [(Substitution, Set Constraint, Int, Int)]
branchConstraints nextTypeVarId nextEffectVarId constraints =
  case findFirstBranch nextTypeVarId nextEffectVarId constraints of
    Nothing -> Nothing
    Just (chosen, alternatives) ->
      let untouched = Set.delete chosen constraints
       in Just
            [ ( alternative.branchSubst,
                Set.union alternative.branchNewConstraints untouched,
                alternative.branchNextTypeVarId,
                alternative.branchNextEffectVarId
              )
              | alternative <- alternatives
            ]

-- | Find the first 'Constraint' in the set that is branchable, returning it
-- alongside its alternatives. Iteration order is the 'Ord'-defined ascending
-- traversal of the set, which is deterministic across runs.
findFirstBranch ::
  Int ->
  Int ->
  Set Constraint ->
  Maybe (Constraint, [BranchAlt])
findFirstBranch nextTypeVarId nextEffectVarId constraints =
  go (Set.toAscList constraints)
  where
    go [] = Nothing
    go (current : remaining) =
      case branchConstraint nextTypeVarId nextEffectVarId current of
        Just alternatives -> Just (current, alternatives)
        Nothing -> go remaining
