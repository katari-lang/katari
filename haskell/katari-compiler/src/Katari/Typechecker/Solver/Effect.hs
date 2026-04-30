-- | Effect-constraint solver.
--
-- Effect constraints have the form @e1 \<: e2@ where each effect is a
-- 'SemanticEffect' = (Set EffectVarId, Set RequestId). The semantics:
--
-- > contents(e) = effectsOf(e.effectVars) ∪ e.effectReqs
-- > e1 <: e2  iff  contents(e1) ⊆ contents(e2)
--
-- Solving:
--
--   * Each 'EffectVarId' has a current "value" (a 'Set RequestId') that
--     accumulates the concrete requests it must include.
--   * For each constraint @e1 \<: e2@, propagate any concrete request in
--     @e1@ that does not appear in @e2@'s concrete part to @e2@'s effect
--     vars (as a lower bound).
--   * Effect vars in @e1@ propagate their current value (minus @e2@'s
--     concrete part) to @e2@'s effect vars.
--   * Iterate to fixpoint.
module Katari.Typechecker.Solver.Effect
  ( solveEffectConstraints,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.Typechecker.ConstraintGenerator (Constraint (..))
import Katari.Typechecker.Identifier (RequestId)
import Katari.Typechecker.SemanticType
  ( EffectVarId,
    SemanticEffect (..),
  )
import Katari.Typechecker.Solver.Internal
  ( SolverError,
  )

-- | Solve effect constraints by lower-bound accumulation. Returns the
-- per-effect-var set of concrete request 'RequestId's, plus any errors
-- (currently empty — effects rarely produce conflicts under Katari's
-- usage patterns).
solveEffectConstraints ::
  Set Constraint ->
  (Map EffectVarId (Set RequestId), [SolverError])
solveEffectConstraints constraints =
  let allEffectVars = collectEffectVars constraints
      initialAssignment =
        Map.fromList [(effectVarId, Set.empty) | effectVarId <- Set.toList allEffectVars]
      finalAssignment = fixpoint (propagateOnce constraints) initialAssignment
   in (finalAssignment, [])

-- ===========================================================================
-- Fixpoint helper
-- ===========================================================================

fixpoint :: (Eq a) => (a -> a) -> a -> a
fixpoint step current =
  let next = step current
   in if current == next then current else fixpoint step next

-- ===========================================================================
-- Single propagation step
-- ===========================================================================

-- | Apply each constraint once: for every effect var on the RHS, update its
-- accumulated value with the contributions inferred from the LHS.
propagateOnce ::
  Set Constraint ->
  Map EffectVarId (Set RequestId) ->
  Map EffectVarId (Set RequestId)
propagateOnce constraints initial = foldr (applyConstraint initial) initial constraints
  where
    applyConstraint _ constraint accumulator = case constraint of
      EffectConstraint leftEffect rightEffect _ ->
        propagate leftEffect rightEffect accumulator
      TypeConstraint {} -> accumulator
    propagate ::
      SemanticEffect phase ->
      SemanticEffect phase ->
      Map EffectVarId (Set RequestId) ->
      Map EffectVarId (Set RequestId)
    propagate leftEffect rightEffect assignment =
      let leftConcreteReqs = leftEffect.effectReqs
          rightConcreteReqs = rightEffect.effectReqs
          rightEffectVars = rightEffect.effectVars
          -- Concrete reqs in lhs that aren't already covered by rhs concrete
          -- must be absorbed by rhs effect vars.
          concreteContribution = leftConcreteReqs `Set.difference` rightConcreteReqs
          -- Lhs effect vars contribute their current value (minus rhs
          -- concrete) to rhs vars.
          leftVarContribution =
            Set.unions
              [ Map.findWithDefault Set.empty leftEffectVarId assignment
                  `Set.difference` rightConcreteReqs
                | leftEffectVarId <- Set.toList leftEffect.effectVars
              ]
          contribution = Set.union concreteContribution leftVarContribution
       in if Set.null contribution
            then assignment
            else
              foldr
                ( Map.adjust (Set.union contribution)
                )
                assignment
                (Set.toList rightEffectVars)

-- ===========================================================================
-- Helpers
-- ===========================================================================

collectEffectVars :: Set Constraint -> Set EffectVarId
collectEffectVars = foldr addFromConstraint Set.empty
  where
    addFromConstraint (EffectConstraint leftEffect rightEffect _) accumulator =
      Set.unions [accumulator, leftEffect.effectVars, rightEffect.effectVars]
    addFromConstraint TypeConstraint {} accumulator = accumulator
