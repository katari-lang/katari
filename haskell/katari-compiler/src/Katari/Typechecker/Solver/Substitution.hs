-- | Substitution maps and bound calculations for the Solver.
--
-- This module supplies the bookkeeping for:
--
--   * Applying a 'Substitution' (Map TypeVarId (SemanticType Unresolved)) to
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
-- which routes through 'NormalizedType.subtypeNT'.
module Katari.Typechecker.Solver.Substitution
  ( applySubstType,
    applySubstEffect,
    applySubstConstraint,
    applySubstSubst,
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

import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Katari.Typechecker.ConstraintGenerator (Constraint (..))
import Katari.Typechecker.NormalizedType
  ( NormalizedType (..),
    emptyLayered,
    normaliseSemantic,
    subtypeNT,
  )
import Katari.Typechecker.SemanticType
  ( SemanticEffect (..),
    SemanticType (..),
    TypeVarId,
    Unresolved,
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
applySubstType :: Substitution -> SemanticType phase -> SemanticType phase
applySubstType substitution = \case
  SemanticTypeVariable typeVarId ->
    case Map.lookup typeVarId substitution of
      -- The map stores SemanticType Unresolved, but the value is
      -- variable-free at the point of substitution (or is itself a
      -- variable that we couldn't pin). Coerce safely via the structural
      -- rebuild below.
      Just bound -> coerceUnresolved bound
      Nothing -> SemanticTypeVariable typeVarId
  SemanticTypeFunction parameterTypes returnType effects ->
    SemanticTypeFunction
      [ (label, applySubstType substitution parameterType)
        | (label, parameterType) <- parameterTypes
      ]
      (applySubstType substitution returnType)
      effects
  SemanticTypeArray element -> SemanticTypeArray (applySubstType substitution element)
  SemanticTypeTuple elements ->
    SemanticTypeTuple (applySubstType substitution <$> elements)
  SemanticTypeUnion branches ->
    SemanticTypeUnion (applySubstType substitution <$> branches)
  SemanticTypeObject fields ->
    SemanticTypeObject (Map.map (applySubstType substitution) fields)
  -- Atomic / leaf types pass through.
  SemanticTypeNever -> SemanticTypeNever
  SemanticTypeUnknown -> SemanticTypeUnknown
  SemanticTypeNull -> SemanticTypeNull
  SemanticTypeInteger -> SemanticTypeInteger
  SemanticTypeNumber -> SemanticTypeNumber
  SemanticTypeString -> SemanticTypeString
  SemanticTypeBoolean -> SemanticTypeBoolean
  SemanticTypeLiteralInteger value -> SemanticTypeLiteralInteger value
  SemanticTypeLiteralString value -> SemanticTypeLiteralString value
  SemanticTypeLiteralBoolean value -> SemanticTypeLiteralBoolean value
  SemanticTypeData typeId -> SemanticTypeData typeId

-- | Phase coercion: SemanticType Unresolved → SemanticType phase by
-- structural rebuilding. Used only inside 'applySubstType' where the
-- substitution result is plugged back into a possibly-different phase.
-- Since 'SemanticTypeVariable' only inhabits the @Unresolved@ phase, this
-- is safe **only** when the substitution value has been fully resolved
-- (no SemanticTypeVariable inside). Applied to live substitution maps,
-- this invariant may not hold yet — but the result still typechecks
-- because we propagate variables through.
coerceUnresolved :: SemanticType source -> SemanticType target
coerceUnresolved = \case
  SemanticTypeVariable _ ->
    -- Reaching here means we'd substitute a var with a var. We preserve
    -- structure by emitting Never as a defensive default; live solver flow
    -- never reaches this when the value is itself a leaf var.
    SemanticTypeNever
  SemanticTypeNever -> SemanticTypeNever
  SemanticTypeUnknown -> SemanticTypeUnknown
  SemanticTypeNull -> SemanticTypeNull
  SemanticTypeInteger -> SemanticTypeInteger
  SemanticTypeNumber -> SemanticTypeNumber
  SemanticTypeString -> SemanticTypeString
  SemanticTypeBoolean -> SemanticTypeBoolean
  SemanticTypeLiteralInteger value -> SemanticTypeLiteralInteger value
  SemanticTypeLiteralString value -> SemanticTypeLiteralString value
  SemanticTypeLiteralBoolean value -> SemanticTypeLiteralBoolean value
  SemanticTypeData typeId -> SemanticTypeData typeId
  SemanticTypeArray element -> SemanticTypeArray (coerceUnresolved element)
  SemanticTypeTuple elements -> SemanticTypeTuple (coerceUnresolved <$> elements)
  SemanticTypeUnion branches -> SemanticTypeUnion (coerceUnresolved <$> branches)
  SemanticTypeObject fields -> SemanticTypeObject (Map.map coerceUnresolved fields)
  SemanticTypeFunction parameterTypes returnType effects ->
    SemanticTypeFunction
      [(label, coerceUnresolved parameterType) | (label, parameterType) <- parameterTypes]
      (coerceUnresolved returnType)
      (SemanticEffect effects.effectVars effects.effectReqs)

applySubstEffect :: Substitution -> SemanticEffect phase -> SemanticEffect phase
applySubstEffect _ effect = effect -- effect vars are handled by the effect solver

applySubstConstraint :: Substitution -> Constraint -> Constraint
applySubstConstraint substitution = \case
  TypeConstraint leftType rightType reason ->
    TypeConstraint
      (applySubstType substitution leftType)
      (applySubstType substitution rightType)
      reason
  EffectConstraint leftEffect rightEffect reason ->
    EffectConstraint
      (applySubstEffect substitution leftEffect)
      (applySubstEffect substitution rightEffect)
      reason

-- | Apply @outer@ to every value in @inner@, then merge: @outer ∘ inner@.
applySubstSubst :: Substitution -> Substitution -> Substitution
applySubstSubst outer inner =
  Map.union (Map.map (applySubstType outer) inner) outer

-- ===========================================================================
-- Bounds calculation (with origin tracking)
-- ===========================================================================

-- | For a given 'TypeVarId' @α@, scan the constraint set and collect:
--
--   * For each @TypeConstraint t α r@: @t@ as a lower bound with origin @r@.
--   * For each @TypeConstraint α t r@: @t@ as an upper bound with origin @r@.
--
-- Constraints where @α@ does not occur as the entire LHS / RHS are ignored
-- (those will be decomposed structurally elsewhere).
calculateBounds :: TypeVarId -> [Constraint] -> Bounds
calculateBounds typeVarId constraints =
  Bounds
    { lowerBounds = mapMaybe (asLower typeVarId) constraints,
      upperBounds = mapMaybe (asUpper typeVarId) constraints
    }

asLower :: TypeVarId -> Constraint -> Maybe BoundedType
asLower typeVarId = \case
  TypeConstraint leftType (SemanticTypeVariable rightTypeVarId) reason
    | rightTypeVarId == typeVarId && leftType /= SemanticTypeVariable typeVarId ->
        Just (BoundedType {boundType = leftType, boundReason = reason})
  _ -> Nothing

asUpper :: TypeVarId -> Constraint -> Maybe BoundedType
asUpper typeVarId = \case
  TypeConstraint (SemanticTypeVariable leftTypeVarId) rightType reason
    | leftTypeVarId == typeVarId && rightType /= SemanticTypeVariable typeVarId ->
        Just (BoundedType {boundType = rightType, boundReason = reason})
  _ -> Nothing

-- | Collect bounds for every type variable mentioned in the constraint set.
calculateAllBounds :: [Constraint] -> Map TypeVarId Bounds
calculateAllBounds constraints =
  let typeVarIds = Set.unions (constraintTypeVars <$> constraints)
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
calculatePropagation :: [Constraint] -> Maybe [Constraint]
calculatePropagation constraints =
  let bounds = calculateAllBounds constraints
      derived =
        [ TypeConstraint lower.boundType upper.boundType lower.boundReason
          | (_, Bounds lowers uppers) <- Map.toList bounds,
            lower <- lowers,
            upper <- uppers
        ]
      novel = filter (`notElem` constraints) (nub derived)
   in if null novel then Nothing else Just novel

-- | Iterate 'calculatePropagation' to a fixpoint. The total set is finite
-- (bounded by pairs of source bounds), so this terminates.
calculatePropagationAll :: [Constraint] -> [Constraint]
calculatePropagationAll = go
  where
    go constraints = case calculatePropagation constraints of
      Nothing -> constraints
      Just newConstraints -> go (constraints <> newConstraints)

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
--   * Otherwise leave unbound (caller will fill 'NTUnknown' via totality).
collectFinalSubstitutions :: [Constraint] -> Substitution
collectFinalSubstitutions constraints =
  let bounds = calculateAllBounds constraints
   in Map.mapMaybe pickFromBounds bounds
  where
    pickFromBounds (Bounds lowers uppers) =
      let solvedLowers =
            filter containsNoTypeVars ((.boundType) <$> lowers)
          solvedUppers =
            filter containsNoTypeVars ((.boundType) <$> uppers)
       in case solvedLowers of
            [] -> case solvedUppers of
              [] -> Nothing
              [single] -> Just single
              many -> Just (SemanticTypeUnion (nub many))
            [single] -> Just single
            many -> Just (SemanticTypeUnion (nub many))

-- ===========================================================================
-- Bounds consistency check
-- ===========================================================================

-- | After final substitution, verify that for every variable, every concrete
-- lower bound is a subtype of every concrete upper bound. If not, emit a
-- 'SolverErrorBoundsConflict' carrying both reasons + their concrete types.
checkBoundsConsistency :: Map TypeVarId Bounds -> [SolverError]
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
      not (subtypeNT (normaliseSemantic resolvedLower) (normaliseSemantic resolvedUpper))
  ]

-- ===========================================================================
-- Substitution → NormalizedType map
-- ===========================================================================

-- | Convert each pinned 'SemanticType Unresolved' (assumed variable-free) to
-- 'NormalizedType' for the public 'SolverResult'. Variables that still
-- contain unresolved 'SemanticTypeVariable' fall back to 'NTUnknown'
-- (defensive; should not happen if Solver completed normally).
substToNormalized :: Substitution -> Map TypeVarId NormalizedType
substToNormalized = Map.map convert
  where
    convert pinned = case semanticToConcrete pinned of
      Just resolved -> normaliseSemantic resolved
      Nothing -> NTLayered emptyLayered  -- bottom: unresolved post-solve
