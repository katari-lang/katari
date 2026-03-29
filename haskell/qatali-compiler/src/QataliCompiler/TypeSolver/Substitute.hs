{- | Variable substitution and propagation for the constraint solver.

Following memento-compiler's architecture, this module provides:

  1. 'substInstancesAsPossible' — eagerly substitute uniquely-determined
     unknown variables, then eliminate non-nested variables by transitivity.

  2. 'propagateAll' — simple propagation: add transitivity constraints
     without removing variables. Used after decomposition.

  3. 'collectFinalSubstitutions' — build final substitution map from
     concrete bounds.

  4. 'checkContradictions' — verify all ground constraints via 'isSubtype'.
-}
module QataliCompiler.TypeSolver.Substitute (
    substInstancesAsPossible,
    propagateAll,
    collectFinalSubstitutions,
    checkContradictions,
) where

import qualified Data.Map.Strict                       as Map
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.Text                             (Text)

import           QataliCompiler.Name                   (Name)
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Type.Subtype           (isSubtype)
import           Data.Proxy                            (Proxy (..))
import           QataliCompiler.Type.Type              (Type (..), UnknownVarKind,
                                                         containsUnknownVar,
                                                         containsTVar,
                                                         unknownVarNames,
                                                         substituteUnknownVars,
                                                         showType)
import           QataliCompiler.TypeSolver.Constraint
import           QataliCompiler.TypeSolver.Types

-- ---------------------------------------------------------------------------
-- substInstancesAsPossible
-- (corresponds to memento's substInstancesAsPossible)

-- | Eagerly substitute unknown variables that are uniquely determined
-- by their bounds, then eliminate non-nested variables by full propagation.
substInstancesAsPossible
    :: Set Assumption
    -> Set Constraint
    -> (Set Assumption, Set Constraint, Substitution)
substInstancesAsPossible as cs = substLoop as cs Map.empty

substLoop
    :: Set Assumption
    -> Set Constraint
    -> Substitution
    -> (Set Assumption, Set Constraint, Substitution)
substLoop as cs accSubst =
    let csFiltered = filterTrivial cs
        vars = allUnknownVars csFiltered
        boundsMap = Map.fromList [(v, calculateBounds v csFiltered) | v <- Set.toList vars]
        instances = Map.mapMaybe calculateInstanceFromBounds boundsMap
        -- Filter out self-substitutions and already-substituted variables
        validInstances = Map.filterWithKey (\v instTy ->
            not (isUnknownVarItself v instTy) && not (Map.member v accSubst)) instances
    in  case Map.lookupMin validInstances of
            Just (v, instTy) ->
                let substMap = Map.singleton v instTy
                    newCs = Set.map (applySubst substMap) csFiltered
                    newAs = Set.map (applySubst substMap) as
                    newAccSubst = Map.insert v instTy accSubst
                in  substLoop newAs newCs newAccSubst
            Nothing ->
                -- No direct instances found → try full propagation
                let (finalAs, finalCs, propSubst) = fullPropagateAll as csFiltered
                    combinedSubst = Map.union accSubst propSubst
                in  (finalAs, finalCs, combinedSubst)

-- | Check if a type is just the unknown variable itself (self-substitution).
isUnknownVarItself :: Name -> Type -> Bool
isUnknownVarItself name (TUnknownVar n) = n == name
isUnknownVarItself _ _                  = False

-- ---------------------------------------------------------------------------
-- calculateBounds

-- | Calculate lower and upper bounds for an unknown variable from constraints.
calculateBounds :: Name -> Set Constraint -> ([Type], [Type])
calculateBounds varName cs =
    let lowers = [t | IsSubtypeOf _ t (TUnknownVar n) <- Set.toList cs, n == varName,
                      not (isUnknownVarItself varName t)]
        uppers = [t | IsSubtypeOf _ (TUnknownVar n) t <- Set.toList cs, n == varName,
                      not (isUnknownVarItself varName t)]
    in  (lowers, uppers)

-- | Try to determine a unique instance for a variable from its bounds.
-- (corresponds to memento's calculateInstanceFromBounds)
calculateInstanceFromBounds :: ([Type], [Type]) -> Maybe Type
calculateInstanceFromBounds (lowers, uppers)
    | any isNeverTy uppers  = Just TNever    -- forced to be Never
    | any isUnknownTy lowers = Just TUnknown  -- forced to be Unknown
    | not (null common)     = Just (head common)  -- lower ∩ upper
    | otherwise             = Nothing
  where
    common = filter (`elem` uppers) lowers

isNeverTy :: Type -> Bool
isNeverTy TNever = True
isNeverTy _      = False

isUnknownTy :: Type -> Bool
isUnknownTy TUnknown = True
isUnknownTy _        = False

-- ---------------------------------------------------------------------------
-- Full propagation (variable elimination)
-- (corresponds to memento's calculateFullPropagation)

-- | Eliminate a non-nested unknown variable by transitivity.
-- A "non-nested" variable appears only at the top level of constraints
-- (not inside type constructors), and not in assumptions.
fullPropagate
    :: Set Assumption
    -> Set Constraint
    -> Maybe (Set Constraint, Substitution)
fullPropagate as cs =
    let vars = allUnknownVars cs
        nestedVars = Set.unions $ Set.map getNestedUnknownVars cs
        assumptionVars = Set.unions $ Set.map constraintUnknownVars as
        nonNestedVars = (vars `Set.difference` nestedVars) `Set.difference` assumptionVars
    in  case Set.toList nonNestedVars of
            [] -> Nothing
            (targetVar : _) ->
                let (lowers, uppers) = calculateBounds targetVar cs
                    -- Generate transitivity constraints (NoSpan since solver-internal)
                    newConstraints = [IsSubtypeOf NoSpan lo hi | lo <- lowers, hi <- uppers]
                    -- Remove all constraints mentioning targetVar
                    filteredCs = Set.filter (not . mentionsUnknown targetVar) cs
                    -- Extract substitution
                    varSubst = buildSubstForVar targetVar lowers uppers
                in  Just (Set.union filteredCs (Set.fromList newConstraints), varSubst)

-- | Run full propagation to fixpoint, accumulating substitutions.
fullPropagateAll
    :: Set Assumption
    -> Set Constraint
    -> (Set Assumption, Set Constraint, Substitution)
fullPropagateAll as cs = go as cs Map.empty
  where
    go a c accSubst =
        case fullPropagate a c of
            Nothing -> (a, c, accSubst)
            Just (newCs, newSubst) ->
                go a newCs (Map.union accSubst newSubst)

-- | Get unknown variables that appear nested inside type constructors.
-- (corresponds to memento's getNestedVars)
getNestedUnknownVars :: Constraint -> Set Name
getNestedUnknownVars (IsSubtypeOf _ t1 t2) =
    case (isTopLevelUnknown t1, isTopLevelUnknown t2) of
        (True, True)   -> Set.empty  -- Both are type variables, no nesting
        (True, False)  -> unknownVarNames t2
        (False, True)  -> unknownVarNames t1
        (False, False) -> Set.union (unknownVarNames t1) (unknownVarNames t2)

-- | Is this type a top-level unknown variable (not nested)?
isTopLevelUnknown :: Type -> Bool
isTopLevelUnknown (TUnknownVar _) = True
isTopLevelUnknown _               = False

-- | Does this constraint mention a specific unknown variable?
mentionsUnknown :: Name -> Constraint -> Bool
mentionsUnknown name (IsSubtypeOf _ t1 t2) =
    Set.member name (unknownVarNames t1) || Set.member name (unknownVarNames t2)

-- | Build a substitution for an eliminated variable from its bounds.
buildSubstForVar :: Name -> [Type] -> [Type] -> Substitution
buildSubstForVar varName lowers uppers =
    let noVars t = not (containsUnknownVar t) && not (containsTVar t)
        solvedLowers = filter noVars lowers
        solvedUppers = filter noVars uppers
    in  case solvedLowers of
            [lower] -> Map.singleton varName lower
            (_:_)   -> Map.singleton varName (foldr1 TUnion solvedLowers)
            [] -> case solvedUppers of
                [upper] -> Map.singleton varName upper
                _       -> Map.empty

-- ---------------------------------------------------------------------------
-- Simple propagation (no variable elimination)
-- (corresponds to memento's calculatePropagationAll)

-- | Add transitivity constraints for all unknown variables.
-- Runs to fixpoint (up to fuel limit). Does NOT remove variables.
propagateAll :: Set Constraint -> Set Constraint
propagateAll = propagateTransitive (Proxy :: Proxy UnknownVarKind) 100

-- ---------------------------------------------------------------------------
-- collectFinalSubstitutions
-- (corresponds to memento's collectFinalSubstitutions)

-- | Build final substitutions from propagated constraints.
-- For each unknown variable, collect solved (no-variable) bounds
-- and create a substitution.
collectFinalSubstitutions :: Set Constraint -> Substitution
collectFinalSubstitutions cs =
    let vars = allUnknownVars cs
        collectForVar v =
            let (lowers, uppers) = calculateBounds v cs
                noVars t = not (containsUnknownVar t) && not (containsTVar t)
                solvedLowers = filter noVars lowers
                solvedUppers = filter noVars uppers
            in  case solvedLowers of
                    []  -> case solvedUppers of
                               []      -> Nothing
                               [upper] -> Just upper
                               us      -> Just (foldr1 TIntersection us)
                    [lower] -> Just lower
                    ls      -> Just (foldr1 TUnion ls)
    in  Map.fromList [(v, subst) | v <- Set.toList vars, Just subst <- [collectForVar v]]

-- ---------------------------------------------------------------------------
-- checkContradictions
-- (corresponds to memento's checkContradictions)

-- | Check all ground constraints via 'isSubtype'.
-- Returns Nothing if no contradictions, Just (span, error) otherwise.
checkContradictions :: SolverEnv -> Set Constraint -> Maybe (SrcSpan, Text)
checkContradictions env cs = go (Set.toList cs)
  where
    defs = seTypeDefs env
    noVars t = not (containsUnknownVar t) && not (containsTVar t)
    go [] = Nothing
    go (IsSubtypeOf sp t1 t2 : rest)
        | noVars t1 && noVars t2 =
            if isSubtype defs t1 t2
                then go rest
                else Just (sp, "type mismatch: " <> showType t1
                         <> " is not a subtype of " <> showType t2)
        | otherwise = go rest

-- ---------------------------------------------------------------------------
-- Utility

-- | Collect all unknown variable names from a set of constraints.
allUnknownVars :: Set Constraint -> Set Name
allUnknownVars = Set.unions . Set.map constraintUnknownVars

-- | Filter trivial constraints (a == b, TNever <: _, _ <: TUnknown).
filterTrivial :: Set Constraint -> Set Constraint
filterTrivial = Set.filter (not . isTrivialConstraint)

-- | Apply a substitution to a constraint.
applySubst :: Substitution -> Constraint -> Constraint
applySubst subst = overConstraint (substituteUnknownVars subst)
