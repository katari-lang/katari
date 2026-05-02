-- | Request-constraint solver.
--
-- Request constraints have the form @e1 \<: e2@ where each request is a
-- 'SemanticRequest' = (Set RequestVariableId, Set RequestId). The semantics:
--
-- > contents(e) = requestsOf(e.requestVars) ∪ e.requestReqs
-- > e1 <: e2  iff  contents(e1) ⊆ contents(e2)
--
-- Solving:
--
--   * Each 'RequestVariableId' has a current "value" (a 'Set RequestId') that
--     accumulates the concrete requests it must include.
--   * For each constraint @e1 \<: e2@, propagate any concrete request in
--     @e1@ that does not appear in @e2@'s concrete part to @e2@'s request
--     vars (as a lower bound).
--   * Request vars in @e1@ propagate their current value (minus @e2@'s
--     concrete part) to @e2@'s request vars.
--   * Iterate to fixpoint.
module Katari.Typechecker.Solver.Request
  ( solveRequestConstraints,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.SemanticType
  ( RequestVariableId,
    SemanticRequest (..),
  )
import Katari.Typechecker.ConstraintGenerator (Constraint (..))
import Katari.Typechecker.Identifier (RequestId)
import Katari.Typechecker.Solver.Internal
  ( SolverError,
  )

-- | Solve request constraints by lower-bound accumulation. Returns the
-- per-request-var set of concrete request 'RequestId's, plus any errors
-- (currently empty — requests rarely produce conflicts under Katari's
-- usage patterns).
solveRequestConstraints ::
  Set Constraint ->
  (Map RequestVariableId (Set RequestId), [SolverError])
solveRequestConstraints constraints =
  let allRequestVars = collectRequestVars constraints
      initialAssignment =
        Map.fromList [(requestVarId, Set.empty) | requestVarId <- Set.toList allRequestVars]
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

-- | Apply each constraint once: for every request var on the RHS, update its
-- accumulated value with the contributions inferred from the LHS.
propagateOnce ::
  Set Constraint ->
  Map RequestVariableId (Set RequestId) ->
  Map RequestVariableId (Set RequestId)
propagateOnce constraints initial = foldr (applyConstraint initial) initial constraints
  where
    applyConstraint _ constraint accumulator = case constraint of
      RequestConstraint leftRequest rightRequest _ ->
        propagate leftRequest rightRequest accumulator
      TypeConstraint {} -> accumulator
    propagate ::
      SemanticRequest phase ->
      SemanticRequest phase ->
      Map RequestVariableId (Set RequestId) ->
      Map RequestVariableId (Set RequestId)
    propagate leftRequest rightRequest assignment =
      let leftConcreteReqs = leftRequest.requestReqs
          rightConcreteReqs = rightRequest.requestReqs
          rightRequestVars = rightRequest.requestVars
          -- Concrete reqs in lhs that aren't already covered by rhs concrete
          -- must be absorbed by rhs request vars.
          concreteContribution = leftConcreteReqs `Set.difference` rightConcreteReqs
          -- Lhs request vars contribute their current value (minus rhs
          -- concrete) to rhs vars.
          leftVarContribution =
            Set.unions
              [ Map.findWithDefault Set.empty leftRequestVariableId assignment
                  `Set.difference` rightConcreteReqs
                | leftRequestVariableId <- Set.toList leftRequest.requestVars
              ]
          contribution = Set.union concreteContribution leftVarContribution
       in if Set.null contribution
            then assignment
            else
              foldr
                ( Map.adjust (Set.union contribution)
                )
                assignment
                (Set.toList rightRequestVars)

-- ===========================================================================
-- Helpers
-- ===========================================================================

collectRequestVars :: Set Constraint -> Set RequestVariableId
collectRequestVars = foldr addFromConstraint Set.empty
  where
    addFromConstraint (RequestConstraint leftRequest rightRequest _) accumulator =
      Set.unions [accumulator, leftRequest.requestVars, rightRequest.requestVars]
    addFromConstraint TypeConstraint {} accumulator = accumulator
