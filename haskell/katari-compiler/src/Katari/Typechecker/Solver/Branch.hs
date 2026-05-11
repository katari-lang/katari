{- HLINT ignore "Redundant bracket" -}

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
-- a triple @(subst, newConstraints, nextTypeVariableId)@: the variable
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
import Katari.SemanticType
  ( RequestVariableId (..),
    SemanticRequest (..),
    SemanticType (..),
    TypeVariableId (..),
    Unresolved,
    singletonRequestVariable,
  )
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
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
-- for fresh-var allocation (both type and request).
data BranchAlt = BranchAlt
  { branchSubst :: Substitution,
    branchNewConstraints :: (Set Constraint),
    branchNextTypeVariableId :: Int,
    branchNextRequestVariableId :: Int
  }
  deriving (Show)

-- ===========================================================================
-- branchConstraint
-- ===========================================================================

-- | Branch a single constraint into one or more alternatives. Returns
-- 'Nothing' if the constraint is not branchable (the solver should
-- continue with bound aggregation / final-substitution collection).
--
-- The two 'Int' parameters are the next free TypeVariableId / RequestVariableId
-- counters; each branch may allocate fresh vars and updates them
-- accordingly.
branchConstraint :: Int -> Int -> Constraint -> Maybe [BranchAlt]
branchConstraint nextTypeVariableId nextRequestVariableId = \case
  TypeConstraint leftType rightType reason ->
    branchType nextTypeVariableId nextRequestVariableId leftType rightType reason
  RequestConstraint {} -> Nothing

branchType ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Maybe [BranchAlt]
branchType nextTypeVariableId nextRequestVariableId leftType rightType reason =
  case (leftType, rightType) of
    -- α <: B | C : try α <: B OR α <: C.
    -- Only branch when LHS contains a type variable; if LHS is concrete the
    -- decomposer already settled or rejected this constraint via subtypeNormalizedType.
    (_, SemanticTypeUnion branches)
      | not (Set.null (typeVarsIn leftType)) ->
          Just
            [ BranchAlt
                { branchSubst = Map.empty,
                  branchNewConstraints =
                    Set.singleton (TypeConstraint leftType branch reason),
                  branchNextTypeVariableId = nextTypeVariableId,
                  branchNextRequestVariableId = nextRequestVariableId
                }
              | branch <- branches
            ]
    -- α <: composite (LHS is var, RHS has structure).
    (SemanticTypeVariable typeVarId, _)
      | isBranchableShape rightType ->
          Just
            ( branchVarOnLeft nextTypeVariableId nextRequestVariableId typeVarId rightType reason
            )
    -- composite <: α (RHS is var, LHS has structure).
    (_, SemanticTypeVariable typeVarId)
      | isBranchableShape leftType ->
          Just
            ( branchVarOnRight nextTypeVariableId nextRequestVariableId leftType typeVarId reason
            )
    _ -> Nothing

-- | True iff the shape has internal structure that warrants branching.
-- Primitives, literals, bare data refs, and the function top type
-- ('function') don't need branching — bound aggregation handles them.
isBranchableShape :: SemanticType Unresolved -> Bool
isBranchableShape = \case
  SemanticTypeFunction {} -> True
  SemanticTypeArray _ -> True
  SemanticTypeTuple _ -> True
  SemanticTypeObject _ -> True
  -- 'function' (function-top) is treated as a primitive: it has no
  -- internal structure to branch on; the constraint goes straight to
  -- bound aggregation just like @α \<: integer@ or @integer \<: α@.
  SemanticTypeFunctionAny -> False
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

-- | Request-constraint counterpart of 'emitCovariantType'.
emitCovariantRequest ::
  BranchSide ->
  SemanticRequest Unresolved ->
  SemanticRequest Unresolved ->
  ConstraintReason ->
  Constraint
emitCovariantRequest side variableSide originalSide reason = case side of
  LeftVar -> RequestConstraint variableSide originalSide reason
  RightVar -> RequestConstraint originalSide variableSide reason

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
  TypeVariableId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnLeft = branchVar LeftVar

branchVarOnRight ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  TypeVariableId ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnRight nextTypeVariableId nextRequestVariableId shape typeVarId =
  branchVar RightVar nextTypeVariableId nextRequestVariableId typeVarId shape

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
  TypeVariableId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVar side nextTypeVariableId nextRequestVariableId typeVarId shape reason =
  let (narrowedShape, freshConstraints, nextTypeVariableIdAfter, nextRequestVariableIdAfter) =
        narrowShape side nextTypeVariableId nextRequestVariableId shape reason
      -- Fallback substitution for the second branch. For @α \<: F@ the
      -- vacuous bound is 'SemanticTypeNever' (bottom). For @F \<: α@ we
      -- pick the tightest top that still satisfies the constraint:
      --   * If F is a function shape, use 'SemanticTypeFunctionAny' —
      --     the function-lattice top — so that α need only be \"some
      --     function or wider\" rather than the full \"unknown\". This
      --     keeps later constraints like @α \<: integer@ correctly
      --     rejecting (a callable is not an integer).
      --   * Otherwise (array / tuple / object), keep 'SemanticTypeUnknown'.
      fallback = case side of
        LeftVar -> SemanticTypeNever
        RightVar -> case shape of
          SemanticTypeFunction {} -> SemanticTypeFunctionAny
          _ -> SemanticTypeUnknown
   in [ BranchAlt
          { branchSubst = Map.singleton typeVarId narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVariableId = nextTypeVariableIdAfter,
            branchNextRequestVariableId = nextRequestVariableIdAfter
          },
        BranchAlt
          { branchSubst = Map.singleton typeVarId fallback,
            branchNewConstraints = Set.empty,
            branchNextTypeVariableId = nextTypeVariableId,
            branchNextRequestVariableId = nextRequestVariableId
          }
      ]

-- | Build a fresh-var \"shape skeleton\" for α matching @shape@, plus the
-- variance-respecting sub-constraints. 'BranchSide' selects which side of
-- @<:@ α sits on, which flips every emitted constraint's direction.
--
-- For 'SemanticTypeFunction', a fresh 'RequestVariableId' is allocated and an
-- request constraint is added at the covariant position.
narrowShape ::
  BranchSide ->
  Int ->
  Int ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, Set Constraint, Int, Int)
narrowShape side nextTypeVariableId nextRequestVariableId shape reason = case shape of
  SemanticTypeFunction parameters returnType requests ->
    let parameterEntries = Map.toList parameters
        (parameterVars, nextAfterParams) = freshVars nextTypeVariableId (length parameterEntries)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        (requestVar, nextRequestAfter) = freshRequestVar nextRequestVariableId
        narrowedParameters =
          Map.fromList
            [ (label, SemanticTypeVariable parameterVar)
              | ((label, _), parameterVar) <- zip parameterEntries parameterVars
            ]
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (singletonRequestVariable requestVar)
        parameterConstraints =
          [ emitContravariantType side (SemanticTypeVariable parameterVar) originalParameter reason
            | ((_, originalParameter), parameterVar) <- zip parameterEntries parameterVars
          ]
        returnConstraint =
          emitCovariantType side (SemanticTypeVariable returnVar) returnType reason
        requestConstraint =
          emitCovariantRequest
            side
            (singletonRequestVariable requestVar)
            requests
            reason
     in ( narrowedShape,
          Set.fromList (requestConstraint : returnConstraint : parameterConstraints),
          nextAfterReturn,
          nextRequestAfter
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVariableId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          emitCovariantType side (SemanticTypeVariable elementVar) element reason
     in (narrowedShape, Set.singleton elementConstraint, nextAfterElement, nextRequestVariableId)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVariableId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ emitCovariantType side (SemanticTypeVariable elementVar) originalElement reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, Set.fromList elementConstraints, nextAfterElements, nextRequestVariableId)
  SemanticTypeObject fields ->
    let (fieldVars, nextAfterFields) = freshVars nextTypeVariableId (Map.size fields)
        fieldLabels = Map.keys fields
        narrowedFields =
          Map.fromList (zip fieldLabels (SemanticTypeVariable <$> fieldVars))
        narrowedShape = SemanticTypeObject narrowedFields
        fieldConstraints =
          [ emitCovariantType side (SemanticTypeVariable fieldVar) originalField reason
            | (fieldVar, originalField) <- zip fieldVars (Map.elems fields)
          ]
     in (narrowedShape, Set.fromList fieldConstraints, nextAfterFields, nextRequestVariableId)
  -- Defensive: 'isBranchableShape' guards the call site so this is unreachable.
  _ -> (shape, Set.empty, nextTypeVariableId, nextRequestVariableId)

-- ---------------------------------------------------------------------------
-- Fresh var allocation
-- ---------------------------------------------------------------------------

freshVar :: Int -> (TypeVariableId, Int)
freshVar nextTypeVariableId = (TypeVariableId nextTypeVariableId, nextTypeVariableId + 1)

freshRequestVar :: Int -> (RequestVariableId, Int)
freshRequestVar nextRequestVariableId = (RequestVariableId nextRequestVariableId, nextRequestVariableId + 1)

freshVars :: Int -> Int -> ([TypeVariableId], Int)
freshVars nextTypeVariableId 0 = ([], nextTypeVariableId)
freshVars nextTypeVariableId count =
  let (typeVarId, nextAfterFirst) = freshVar nextTypeVariableId
      (remaining, nextAfterAll) = freshVars nextAfterFirst (count - 1)
   in (typeVarId : remaining, nextAfterAll)

-- ===========================================================================
-- branchConstraints
-- ===========================================================================

-- | Find the first branchable constraint in the list and fan it out.
-- Returns 'Nothing' if no constraint is branchable.
--
-- Each result is @(subst, newConstraintList, nextTypeVariableId, nextRequestVariableId)@:
-- the alt's substitution, the worklist after the branch (remaining
-- constraints + new sub-constraints, with the substitution applied), and
-- the updated counters.
branchConstraints ::
  Int ->
  Int ->
  Set Constraint ->
  Maybe [(Substitution, Set Constraint, Int, Int)]
branchConstraints nextTypeVariableId nextRequestVariableId constraints =
  case findFirstBranch nextTypeVariableId nextRequestVariableId constraints of
    Nothing -> Nothing
    Just (chosen, alternatives) ->
      let untouched = Set.delete chosen constraints
       in Just
            [ ( alternative.branchSubst,
                Set.union alternative.branchNewConstraints untouched,
                alternative.branchNextTypeVariableId,
                alternative.branchNextRequestVariableId
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
findFirstBranch nextTypeVariableId nextRequestVariableId constraints =
  go (Set.toAscList constraints)
  where
    go [] = Nothing
    go (current : remaining) =
      case branchConstraint nextTypeVariableId nextRequestVariableId current of
        Just alternatives -> Just (current, alternatives)
        Nothing -> go remaining
