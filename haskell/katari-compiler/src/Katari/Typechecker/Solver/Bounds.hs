-- | Per-variable bound aggregation for the Solver (bound-pair model).
--
-- Each 'TypeVariableId' carries a single normalized lower / upper pair
-- (= 'VarBounds'). New contributions are folded into the existing bound
-- via 'unionNT' (lower) / 'intersectNT' (upper), so the bounds are always
-- already-aggregated and consistency reduces to a single
-- 'subtypeNormalizedType' check.
--
-- The var-on-var subtype graph is handled separately: edges accumulate
-- during the worklist phase, then 'propagateBoundsViaGraph' computes the
-- transitive closure and lifts bounds across chains
-- (@α ⊑ β ⊑ γ@ ⇒ α's upper inherits γ's upper, γ's lower inherits α's lower).
module Katari.Typechecker.Solver.Bounds
  ( -- * VarBounds operations
    addLowerConcrete,
    addUpperConcrete,
    isVarBoundsConsistent,
    lookupBounds,

    -- * NormalizedType predicates
    isNeverNT,
    isUnknownNT,

    -- * Var-graph operations
    addVarEdge,
    propagateBoundsViaGraph,

    -- * Eager pin candidates
    EagerPin (..),
    findEagerPins,

    -- * Final substitution from bounds
    finalizeBoundsToSubstitution,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Katari.SemanticType (TypeVariableId)
import Katari.Typechecker.ConstraintGenerator (ConstraintReason)
import Katari.Typechecker.NormalizedType
  ( DataFieldEnv,
    NormalizedType (..),
    emptyLayered,
    intersectNT,
    subtypeNormalizedType,
    unionNT,
  )
import Katari.Typechecker.Solver.Internal
  ( BoundsMap,
    VarBounds (..),
    VarGraph,
    emptyVarBounds,
  )

-- ===========================================================================
-- VarBounds operations
-- ===========================================================================

-- | Fold a concrete lower-bound contribution into the variable's bounds.
-- The new lower = @unionNT (old lower) new@ (= the least upper bound of
-- every flow into the variable). The reason is prepended for diagnostics.
addLowerConcrete ::
  NormalizedType ->
  ConstraintReason ->
  VarBounds ->
  VarBounds
addLowerConcrete newLower reason vb =
  vb
    { vbLower = unionNT vb.vbLower newLower,
      vbLowerReasons = reason : vb.vbLowerReasons
    }

-- | Fold a concrete upper-bound contribution into the variable's bounds.
-- The new upper = @intersectNT (old upper) new@ (= the greatest lower
-- bound of every constraint flowing out of the variable).
addUpperConcrete ::
  NormalizedType ->
  ConstraintReason ->
  VarBounds ->
  VarBounds
addUpperConcrete newUpper reason vb =
  vb
    { vbUpper = intersectNT vb.vbUpper newUpper,
      vbUpperReasons = reason : vb.vbUpperReasons
    }

-- | @lower ⊑ upper@? The bounds are inconsistent (= no value can satisfy
-- both sides simultaneously) iff this returns 'False'. Callers use this
-- for the per-variable consistency check both during incremental
-- bound-adds and at the final substitution step.
isVarBoundsConsistent :: DataFieldEnv -> VarBounds -> Bool
isVarBoundsConsistent env vb = subtypeNormalizedType env vb.vbLower vb.vbUpper

-- | Look up bounds, defaulting to 'emptyVarBounds' (= lower = never,
-- upper = unknown) if the variable has no entry yet. Saves callers the
-- 'Map.findWithDefault' boilerplate at every bound update.
lookupBounds :: TypeVariableId -> BoundsMap -> VarBounds
lookupBounds = Map.findWithDefault emptyVarBounds

-- | The bottom of the lattice (= 'NormalizedTypeLayered' with every
-- layer empty). Returned as the initial lower bound of every variable.
isNeverNT :: NormalizedType -> Bool
isNeverNT = \case
  NormalizedTypeLayered layered -> layered == emptyLayered
  _ -> False

-- | The top of the lattice. Returned as the initial upper bound of every
-- variable.
isUnknownNT :: NormalizedType -> Bool
isUnknownNT = \case
  NormalizedTypeUnknown -> True
  _ -> False

-- ===========================================================================
-- Var-graph operations
-- ===========================================================================

-- | Record an @α ⊑ β@ edge in the var graph. Self-edges are dropped
-- (vacuously true; cluttering the graph hurts the transitive-closure
-- pass without benefit).
addVarEdge ::
  TypeVariableId ->
  TypeVariableId ->
  VarGraph ->
  VarGraph
addVarEdge from to graph
  | from == to = graph
  | otherwise = Map.insertWith Set.union from (Set.singleton to) graph

-- | Transitive closure of the var graph. Floyd-Warshall-ish: iterate
-- until no new edges appear. The graph is sparse and small (= a few
-- hundred vars per module), so the naive fixpoint terminates quickly.
transitiveClosure :: VarGraph -> VarGraph
transitiveClosure = go
  where
    go g =
      let next = step g
       in if next == g then g else go next
    step g =
      Map.mapWithKey
        ( \_ direct ->
            Set.union
              direct
              (Set.unions [Map.findWithDefault Set.empty t g | t <- Set.toList direct])
        )
        g

-- | After the worklist settles, propagate bounds along the var-graph
-- transitive closure:
--
--   * For each edge @α ⊑ β@ (in the closure): β's lower must subsume
--     α's lower, and α's upper must be contained by β's upper.
--   * Concretely: @β.lower := unionNT (β.lower) (α.lower)@ and
--     @α.upper := intersectNT (α.upper) (β.upper)@.
--
-- The merged bounds reasons union both sides' contributions so the
-- diagnostic can point at the constraint that injected each side.
propagateBoundsViaGraph :: VarGraph -> BoundsMap -> BoundsMap
propagateBoundsViaGraph graph initial =
  let closure = transitiveClosure graph
      -- For each α and each β reachable from α (= α ⊑ β):
      -- (1) α's upper absorbs β's upper (= intersect more constraints in)
      -- (2) β's lower absorbs α's lower (= union more sources into β)
      stepUpper bm =
        foldr
          ( \(from, tos) acc ->
              foldr (`liftUpperFrom` from) acc (Set.toList tos)
          )
          bm
          (Map.toList closure)
      stepLower bm =
        foldr
          ( \(from, tos) acc ->
              foldr (`liftLowerTo` from) acc (Set.toList tos)
          )
          bm
          (Map.toList closure)
   in stepLower (stepUpper initial)
  where
    -- α ⊑ β: pull β's upper into α
    liftUpperFrom :: TypeVariableId -> TypeVariableId -> BoundsMap -> BoundsMap
    liftUpperFrom toVar fromVar bm =
      let toBounds = lookupBounds toVar bm
          fromBounds = lookupBounds fromVar bm
          merged =
            fromBounds
              { vbUpper = intersectNT fromBounds.vbUpper toBounds.vbUpper,
                vbUpperReasons = toBounds.vbUpperReasons <> fromBounds.vbUpperReasons
              }
       in Map.insert fromVar merged bm
    -- α ⊑ β: push α's lower into β
    liftLowerTo :: TypeVariableId -> TypeVariableId -> BoundsMap -> BoundsMap
    liftLowerTo toVar fromVar bm =
      let toBounds = lookupBounds toVar bm
          fromBounds = lookupBounds fromVar bm
          merged =
            toBounds
              { vbLower = unionNT toBounds.vbLower fromBounds.vbLower,
                vbLowerReasons = fromBounds.vbLowerReasons <> toBounds.vbLowerReasons
              }
       in Map.insert toVar merged bm

-- ===========================================================================
-- Eager pin candidates
-- ===========================================================================

-- | One eager-pin decision for a variable. Returned by 'findEagerPins'
-- so the Solver can apply each pin (= insert into 'stSubst', drop the
-- var's bounds, and re-loop) along with any required diagnostic.
data EagerPin where
  EagerPin ::
    { -- | The variable to pin.
      epTypeVarId :: TypeVariableId,
      -- | The 'NormalizedType' to bind the variable to.
      epValue :: NormalizedType,
      -- | If 'True', the bounds were inconsistent (= lower not ⊑ upper)
      -- and the value was forced to 'NormalizedTypeUnknown' as a
      -- recovery; the Solver should emit a 'SolverErrorBoundsConflict'.
      epInconsistent :: Bool,
      -- | The bounds at the time of pinning (for diagnostic span info).
      epBounds :: VarBounds
    } ->
    EagerPin
  deriving (Eq, Show)

-- | Walk the bounds map and find variables whose bounds determine their
-- value:
--
--   * @lower NT == upper NT@ (both fully aggregated, syntactically
--     equal as 'NormalizedType') → pin to that value.
--   * @subtypeNormalizedType lower upper == False@ → inconsistent,
--     pin to 'NormalizedTypeUnknown' and let the caller emit a
--     'SolverErrorBoundsConflict'.
--
-- Variables with neither condition met stay in 'BoundsMap'.
findEagerPins :: DataFieldEnv -> BoundsMap -> [EagerPin]
findEagerPins env bm =
  [ pin
    | (a, vb) <- Map.toList bm,
      Just pin <- [tryPin a vb]
  ]
  where
    tryPin a vb
      | not (isVarBoundsConsistent env vb) =
          Just (EagerPin a NormalizedTypeUnknown True vb)
      | vb.vbLower == vb.vbUpper && not (isUnknownNT vb.vbLower) =
          Just (EagerPin a vb.vbLower False vb)
      | otherwise = Nothing

-- ===========================================================================
-- Final substitution from bounds
-- ===========================================================================

-- | Pick the final 'NormalizedType' for each variable from its bounds.
--
-- Convention: pin to the LOWER bound (= the union of all sources flowing
-- in). This is the most precise type that subsumes every concrete flow.
-- Downstream Zonker / Schema read this as the variable's resolved type.
--
-- Special cases:
--
--   * If the bounds are inconsistent (= lower not ⊑ upper), pin to
--     'NormalizedTypeUnknown' (per the "fallback = Unknown" decision)
--     and the caller emits a 'SolverErrorBoundsConflict' separately.
--   * If lower is empty (= 'never') AND upper is non-trivial, pin to
--     the upper instead — the var has only "constraints from above"
--     (no incoming flow), so the safest non-bottom value is the upper
--     bound. This makes downstream phases see "the var is bounded above
--     by X" rather than "the var must be never".
--   * Else: pin to lower.
finalizeBoundsToSubstitution :: DataFieldEnv -> BoundsMap -> Map TypeVariableId NormalizedType
finalizeBoundsToSubstitution env = Map.map pick
  where
    pick vb
      | not (isVarBoundsConsistent env vb) = NormalizedTypeUnknown
      | isNeverNT vb.vbLower = vb.vbUpper
      | otherwise = vb.vbLower
