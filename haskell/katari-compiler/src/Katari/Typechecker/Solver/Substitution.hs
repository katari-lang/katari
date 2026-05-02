-- | Substitution maps and bound calculations for the Solver.
--
-- This module supplies the bookkeeping for:
--
--   * Applying a 'Substitution' (Map TypeVariableId (SemanticType Unresolved)) to
--     individual types and constraints.
--   * Computing 'Bounds' (lower / upper) for each type variable from the
--     current constraint set, **with origin tracking** — each entry of a
--     bound carries the 'ConstraintReason' of the constraint it came from.
--   * Propagating @t \<: α@ + @α \<: u@ to derive @t \<: u@ (transitive
--     closure), again preserving 'ConstraintReason' on the new constraint.
--   * Pinning a variable to a candidate concrete instance when its lower
--     and upper bounds are both pinned-down concrete types and agree.
--   * Collecting the final substitution at the end (preferring the union
--     of lower bounds for each variable).
--   * Checking bound consistency: each lower-vs-upper pair must satisfy
--     subtype on the canonical 'NormalizedType'; failures emit
--     'SolverErrorBoundsConflict'.
--
-- Subtype check happens **only** through 'isSubtypeConcrete' (Solver.hs),
-- which routes through 'NormalizedType.subtypeNormalizedType'.
module Katari.Typechecker.Solver.Substitution
  ( applySubstType,
    applySubstRequest,
    applySubstConstraint,
    applySubstSubst,
    applyRequestSubstToType,
    calculateBounds,
    calculateAllBounds,
    calculateInstanceFromBounds,
    calculatePropagation,
    calculatePropagationAll,
    collectFinalSubstitutions,
    checkBoundsConsistency,
    substToNormalized,
  )
where

import Data.Functor.Identity (Identity (..))
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.SemanticType
  ( RequestVariableId,
    Resolved,
    SemanticRequest (..),
    SemanticRequestElement (SemanticRequestElementConcrete),
    SemanticType (..),
    TypeVariableId,
    Unresolved,
    singletonRequestVariable,
    substituteVariable,
    unionSemantic,
  )
import Katari.Typechecker.ConstraintGenerator (Constraint (..))
import Katari.Typechecker.Identifier (RequestId)
import Katari.Typechecker.NormalizedType
  ( NormalizedType (..),
    denormalise,
    intersectNT,
    normaliseSemantic,
    subtypeNormalizedType,
  )
import Katari.Typechecker.Solver.Internal
  ( BoundedType (..),
    Bounds (..),
    SolverError (..),
    Substitution,
    constraintTypeVars,
    containsNoTypeVars,
    semanticToConcrete,
  )

-- ===========================================================================
-- Apply substitution
-- ===========================================================================

-- | Substitute every 'SemanticTypeVariable' that has an entry in the
-- substitution map. Variables without entries pass through unchanged.
--
-- The substitution maps to 'SemanticType' 'Unresolved' values, so this
-- function is naturally Unresolved-typed: variables that the substitution
-- itself still contains (transitive references) are left in place to be
-- substituted on a subsequent pass.
applySubstType :: Substitution -> SemanticType Unresolved -> SemanticType Unresolved
applySubstType substitution =
  runIdentity
    . substituteVariable
      (\typeVariableId -> Identity $ Map.findWithDefault (SemanticTypeVariable typeVariableId) typeVariableId substitution)
      (Identity . singletonRequestVariable)

-- | Resolve every 'RequestVariableId' inside a 'SemanticType' against the request
-- substitution, replacing each var with the concrete 'RequestId' set the
-- request solver assigned to it. Type variables are left untouched — apply
-- 'applySubstSubst' first if the value still contains them.
--
-- This is the missing half of "deep substitution composition": without it,
-- a narrowed function shape like @α := (x: t_p) -> r_var, eff e_var@ keeps
-- @e_var@ alive after type vars are pinned, and 'semanticToConcrete' rejects
-- the value (forcing the downstream to fall back to NormalizedTypeUnknown).
applyRequestSubstToType ::
  Map RequestVariableId (Set RequestId) ->
  SemanticType Unresolved ->
  SemanticType Unresolved
applyRequestSubstToType requestSubstitution =
  runIdentity
    . substituteVariable
      (Identity . SemanticTypeVariable)
      ( \requestVariableId ->
          Identity $ SemanticRequest $ Set.map SemanticRequestElementConcrete $ Map.findWithDefault Set.empty requestVariableId requestSubstitution
      )

applySubstRequest :: Substitution -> SemanticRequest phase -> SemanticRequest phase
applySubstRequest _ request = request -- request vars are handled by the request solver

applySubstConstraint :: Substitution -> Constraint -> Constraint
applySubstConstraint substitution = \case
  TypeConstraint leftType rightType reason ->
    TypeConstraint
      (applySubstType substitution leftType)
      (applySubstType substitution rightType)
      reason
  RequestConstraint leftRequest rightRequest reason ->
    RequestConstraint
      (applySubstRequest substitution leftRequest)
      (applySubstRequest substitution rightRequest)
      reason

-- | Apply @outer@ to every value in @inner@, then merge: @outer ∘ inner@.
applySubstSubst :: Substitution -> Substitution -> Substitution
applySubstSubst outer inner =
  Map.union (Map.map (applySubstType outer) inner) outer

-- ===========================================================================
-- Bounds calculation (with origin tracking)
-- ===========================================================================

-- | For a given 'TypeVariableId' @α@, scan the constraint set and collect:
--
--   * For each @TypeConstraint t α r@: @t@ as a lower bound with origin @r@.
--   * For each @TypeConstraint α t r@: @t@ as an upper bound with origin @r@.
--
-- Constraints where @α@ does not occur as the entire LHS / RHS are ignored
-- (those will be decomposed structurally elsewhere).
calculateBounds :: TypeVariableId -> Set Constraint -> Bounds
calculateBounds typeVarId constraints =
  Bounds
    { lowerBounds = mapMaybe (asLower typeVarId) (Set.toList constraints),
      upperBounds = mapMaybe (asUpper typeVarId) (Set.toList constraints)
    }

asLower :: TypeVariableId -> Constraint -> Maybe BoundedType
asLower typeVarId = \case
  TypeConstraint leftType (SemanticTypeVariable rightTypeVariableId) reason
    | rightTypeVariableId == typeVarId && leftType /= SemanticTypeVariable typeVarId ->
        Just (BoundedType {boundType = leftType, boundReason = reason})
  _ -> Nothing

asUpper :: TypeVariableId -> Constraint -> Maybe BoundedType
asUpper typeVarId = \case
  TypeConstraint (SemanticTypeVariable leftTypeVariableId) rightType reason
    | leftTypeVariableId == typeVarId && rightType /= SemanticTypeVariable typeVarId ->
        Just (BoundedType {boundType = rightType, boundReason = reason})
  _ -> Nothing

-- | Collect bounds for every type variable mentioned in the constraint set.
calculateAllBounds :: Set Constraint -> Map TypeVariableId Bounds
calculateAllBounds constraints =
  let typeVarIds = foldr (Set.union . constraintTypeVars) Set.empty constraints
   in Map.fromList
        [ (typeVarId, calculateBounds typeVarId constraints)
          | typeVarId <- Set.toList typeVarIds
        ]

-- ===========================================================================
-- Instance pinning
-- ===========================================================================

-- | Try to pin a variable to a single concrete value based on its bounds.
--
-- Heuristics (mirror memento):
--
--   1. If any upper bound is 'never', the variable must be 'never'.
--   2. If any lower bound is 'unknown', the variable must be 'unknown'.
--   3. If a lower bound and an upper bound are syntactically equal and
--      variable-free, pin to that.
--   4. Otherwise, leave unpinned (defer to final-substitution collection).
calculateInstanceFromBounds :: Bounds -> Maybe (SemanticType Unresolved)
calculateInstanceFromBounds (Bounds lowers uppers)
  | any (isNeverSemantic . (.boundType)) uppers = Just SemanticTypeNever
  | any (isUnknownSemantic . (.boundType)) lowers = Just SemanticTypeUnknown
  | otherwise =
      let concreteLowers = filter (containsNoTypeVars . (.boundType)) lowers
          concreteUppers = filter (containsNoTypeVars . (.boundType)) uppers
          common =
            [ lower.boundType
              | lower <- concreteLowers,
                any ((lower.boundType ==) . (.boundType)) concreteUppers
            ]
       in case common of
            (firstCommon : _) -> Just firstCommon
            [] -> Nothing

isNeverSemantic :: SemanticType phase -> Bool
isNeverSemantic = \case
  SemanticTypeNever -> True
  _ -> False

isUnknownSemantic :: SemanticType phase -> Bool
isUnknownSemantic = \case
  SemanticTypeUnknown -> True
  _ -> False

-- ===========================================================================
-- Bound propagation: t <: α and α <: u  =>  t <: u
-- ===========================================================================

-- | One step of propagation: produce all newly-derivable @t \<: u@ constraints
-- from existing bounds. Returns 'Nothing' if no new constraint was derived.
calculatePropagation :: Set Constraint -> Maybe (Set Constraint)
calculatePropagation constraints =
  let bounds = calculateAllBounds constraints
      derived =
        Set.fromList
          [ TypeConstraint lower.boundType upper.boundType lower.boundReason
            | (_, Bounds lowers uppers) <- Map.toList bounds,
              lower <- lowers,
              upper <- uppers
          ]
      novel = derived `Set.difference` constraints
   in if Set.null novel then Nothing else Just novel

-- | Iterate 'calculatePropagation' to a fixpoint. The total set is finite
-- (bounded by pairs of source bounds), so this terminates.
calculatePropagationAll :: Set Constraint -> Set Constraint
calculatePropagationAll = go
  where
    go constraints = case calculatePropagation constraints of
      Nothing -> constraints
      Just newConstraints -> go (Set.union constraints newConstraints)

-- ===========================================================================
-- Final substitution collection
-- ===========================================================================

-- | After all decomposition / propagation has settled, produce a
-- substitution mapping each type variable to a 'SemanticType Unresolved'.
--
-- For each variable @α@:
--
--   * Filter its lower / upper bounds down to concrete (var-free) ones.
--   * Prefer the union of concrete lower bounds (most specific known type).
--   * Otherwise pick a concrete upper bound if available.
--   * Otherwise pin to 'SemanticTypeUnknown' (lattice top) — there is no
--     concrete information about α, so the safest assumption is "any value".
--     This makes deep substitution composition self-contained: an indirect
--     entry like @β := F(α)@ resolves to @β := F(unknown)@ rather than
--     leaving α dangling for the totality pass to fill in (which would
--     break composition by leaving 'SemanticTypeVariable' inside β's value).
collectFinalSubstitutions :: Set Constraint -> Substitution
collectFinalSubstitutions constraints =
  let bounds = calculateAllBounds constraints
   in Map.map pickFromBounds bounds
  where
    pickFromBounds (Bounds lowers uppers) =
      let solvedLowers = nub (filter containsNoTypeVars ((.boundType) <$> lowers))
          solvedUppers = nub (filter containsNoTypeVars ((.boundType) <$> uppers))
       in case solvedLowers of
            -- No concrete lower bound: pin to the principal upper bound
            -- (intersection of all known upper bounds) if any. With a
            -- single upper bound the intersection is that bound itself.
            [] -> case solvedUppers of
              [] -> SemanticTypeUnknown
              [single] -> single
              manyUppers -> intersectUpperBoundsViaNT manyUppers
            -- One or more concrete lower bounds: pin to their union (the
            -- least upper bound), which is the most precise type that
            -- subsumes every flow into α.
            lowersOnly -> unionSemantic lowersOnly

-- | Take the intersection of multiple upper bounds. SemanticType has no
-- intersection constructor, so we go through 'NormalizedType' which does:
-- normalise each bound, intersect at the lattice level, then denormalise
-- back. The result is sound (still a subtype of every upper bound) but
-- may lose fidelity (e.g. cross-component correlation in tuple unions).
intersectUpperBoundsViaNT :: [SemanticType Unresolved] -> SemanticType Unresolved
intersectUpperBoundsViaNT items = case traverse semanticToConcrete items of
  Just concretes ->
    case fmap normaliseSemantic concretes of
      [] -> SemanticTypeUnknown
      (firstNT : restNT) ->
        resolvedToUnresolved (denormalise (foldr intersectNT firstNT restNT))
  -- Defensive: caller filters via containsNoTypeVars so this branch is
  -- unreachable. Fall back to 'never' (sound: never <: any T).
  Nothing -> SemanticTypeNever

-- | Phase coercion: 'SemanticType' 'Resolved' has no 'SemanticTypeVariable'
-- inhabitants, so the structural rebuild is total. Used to lift the result of
-- 'denormalise' back into the 'Unresolved' phase the substitution expects.
-- Delegates to 'traverseSemanticChildren' for the structural recursion.
resolvedToUnresolved :: SemanticType Resolved -> SemanticType Unresolved
resolvedToUnresolved =
  runIdentity
    . substituteVariable
      (Identity . SemanticTypeVariable)
      (Identity . singletonRequestVariable)

-- ===========================================================================
-- Bounds consistency check
-- ===========================================================================

-- | After final substitution, verify that for every variable, every concrete
-- lower bound is a subtype of every concrete upper bound. If not, emit a
-- 'SolverErrorBoundsConflict' carrying both reasons + their concrete types.
checkBoundsConsistency :: Map TypeVariableId Bounds -> [SolverError]
checkBoundsConsistency boundsMap =
  [ SolverErrorBoundsConflict
      typeVarId
      lower.boundReason
      resolvedLower
      upper.boundReason
      resolvedUpper
    | (typeVarId, Bounds lowers uppers) <- Map.toList boundsMap,
      lower <- lowers,
      upper <- uppers,
      Just resolvedLower <- [semanticToConcrete lower.boundType],
      Just resolvedUpper <- [semanticToConcrete upper.boundType],
      not (subtypeNormalizedType (normaliseSemantic resolvedLower) (normaliseSemantic resolvedUpper))
  ]

-- ===========================================================================
-- Substitution → NormalizedType map
-- ===========================================================================

-- | Convert each pinned 'SemanticType Unresolved' (assumed variable-free) to
-- 'NormalizedType' for the public 'SolverResult'. Variables that still
-- contain unresolved 'SemanticTypeVariable' fall back to 'NormalizedTypeUnknown'
-- (defensive; should not happen if Solver completed normally).
substToNormalized :: Substitution -> Map TypeVariableId NormalizedType
substToNormalized = Map.map convert
  where
    convert pinned = maybe NormalizedTypeUnknown normaliseSemantic (semanticToConcrete pinned)
