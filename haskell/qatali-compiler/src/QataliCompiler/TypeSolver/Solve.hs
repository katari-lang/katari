{- | Constraint solver for the Qatali type system.

Verifies that a set of subtype constraints is satisfiable under
a set of assumptions (generics bounds).

Algorithm (per declaration):
  1. Remove trivial constraints
  2. Check ground constraints via isSubtype directly on Type
  3. Decompose structural constraints (union, intersection, function, data, etc.)
  4. Branch on undecidable constraints (A & B <: C, A <: B | C)
  5. Propagate TVar bounds transitively
  6. Final contradiction check
-}
module QataliCompiler.TypeSolver.Solve (
    SolveResult (..),
    solve,
) where

import           Data.Map.Strict                       (Map)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe)
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.Text                             (Text)
import qualified Data.Text                             as T

import           QataliCompiler.Name                   (Name (..))
import           QataliCompiler.Type.Normalize         (TypeDefs (..), DataDef (..),
                                                        normalizeEffect)
import           QataliCompiler.Type.Subtype           (isSubtype, isEffectSubtype)
import           QataliCompiler.Type.Type
import           QataliCompiler.TypeSolver.Constraint

-- | Result of constraint solving.
data SolveResult
    = SolveSuccess
    | SolveContradiction !Text
    deriving (Eq, Show)

-- | Solve constraints under assumptions.
solve :: TypeDefs -> Set Assumption -> Set Constraint -> SolveResult
solve defs assumptions constraints =
    let cleaned = Set.filter (not . isTrivialConstraint) constraints
        bounds = calculateGenericBounds assumptions
    in  solveLoop defs bounds cleaned

-- | Main solving loop: decompose → branch → propagate → check.
solveLoop :: TypeDefs -> Map Name BoundInfo -> Set Constraint -> SolveResult
solveLoop defs bounds cs =
    case decomposeAll defs bounds cs of
        Left err -> SolveContradiction err
        Right remaining ->
            case findBranch remaining of
                Just branches ->
                    let results = map (solveLoop defs bounds) branches
                    in  case [() | SolveSuccess <- results] of
                            (_:_) -> SolveSuccess
                            []    -> case results of
                                (SolveContradiction e : _) -> SolveContradiction e
                                _ -> SolveContradiction "all branches failed"
                Nothing ->
                    let propagated = propagateAll bounds remaining
                    in  checkContradictions defs bounds propagated

-- =========================================================================
-- Generic bounds
-- =========================================================================

-- | Upper and lower bounds for a type variable.
data BoundInfo = BoundInfo
    { biLowers :: !(Set Type)
    , biUppers :: !(Set Type)
    }

emptyBoundInfo :: BoundInfo
emptyBoundInfo = BoundInfo Set.empty Set.empty

-- | Extract generic bounds from assumptions.
calculateGenericBounds :: Set Assumption -> Map Name BoundInfo
calculateGenericBounds = foldl addAssumption Map.empty . Set.toList
  where
    addAssumption acc (IsSubtypeOf (TVar n) upper) =
        Map.alter (Just . addUpper upper . fromMaybe emptyBoundInfo) n acc
    addAssumption acc (IsSubtypeOf lower (TVar n)) =
        Map.alter (Just . addLower lower . fromMaybe emptyBoundInfo) n acc
    addAssumption acc _ = acc

    addUpper ty bi = bi { biUppers = Set.insert ty (biUppers bi) }
    addLower ty bi = bi { biLowers = Set.insert ty (biLowers bi) }

-- =========================================================================
-- Decomposition
-- =========================================================================

data DecomposeResult
    = Trivial
    | Decomposed (Set Constraint)
    | GroundContradiction Text
    | Undecided

-- | Decompose all constraints iteratively until fixpoint.
decomposeAll :: TypeDefs -> Map Name BoundInfo -> Set Constraint -> Either Text (Set Constraint)
decomposeAll defs bounds cs = go Set.empty (Set.toList cs)
  where
    go acc [] = Right acc
    go acc (c:rest) = case decomposeOne defs bounds c of
        Trivial               -> go acc rest
        Decomposed newCs      -> go acc (Set.toList newCs ++ rest)
        GroundContradiction e -> Left e
        Undecided             -> go (Set.insert c acc) rest

-- | Decompose a single constraint.
decomposeOne :: TypeDefs -> Map Name BoundInfo -> Constraint -> DecomposeResult
decomposeOne defs _bounds (IsSubtypeOf a b)
    -- Trivial cases
    | a == b = Trivial
    | TNever <- a = Trivial
    | TUnknown <- b = Trivial
    -- Ground constraint (no TVars) → direct isSubtype check
    | not (containsTVar a) && not (containsTVar b) =
        if isSubtype defs a b
            then Trivial
            else GroundContradiction $
                "type mismatch: " <> showType a <> " is not a subtype of " <> showType b
    -- Structural decomposition
    | otherwise = decomposeStructural defs a b

decomposeStructural :: TypeDefs -> Type -> Type -> DecomposeResult
decomposeStructural defs a b = case (a, b) of
    -- Union on left: A | B <: C  →  {A <: C, B <: C}
    (TUnion a1 a2, _) ->
        Decomposed $ Set.fromList [IsSubtypeOf a1 b, IsSubtypeOf a2 b]

    -- Intersection on right: A <: B & C  →  {A <: B, A <: C}
    (_, TIntersection b1 b2) ->
        Decomposed $ Set.fromList [IsSubtypeOf a b1, IsSubtypeOf a b2]

    -- Function: (p1) => r1 eff1  <:  (p2) => r2 eff2
    (TFun ps1 r1 e1, TFun ps2 r2 e2)
        | length ps1 == length ps2 ->
            let paramCs = [IsSubtypeOf (fpType p2) (fpType p1) | (p1, p2) <- zip ps1 ps2]
                retC    = IsSubtypeOf r1 r2
                effOk   = isEffectSubtype defs (normalizeEffect defs e1) (normalizeEffect defs e2)
            in  if effOk
                    then Decomposed $ Set.fromList (retC : paramCs)
                    else GroundContradiction
                        "effect mismatch in function subtype"
        | otherwise ->
            GroundContradiction $
                "function arity mismatch: " <> T.pack (show (length ps1))
                <> " vs " <> T.pack (show (length ps2))

    -- Data: Same constructor → decompose by variance
    (TData n1 args1, TData n2 args2)
        | n1 == n2 && length args1 == length args2 ->
            let variances = case Map.lookup n1 (tdData defs) of
                    Just dd -> map dtpVariance (ddParams dd)
                    Nothing -> replicate (length args1) Covariant
                cs = concat $ zipWith3 mkVarianceConstraints variances args1 args2
            in  Decomposed (Set.fromList cs)
        | n1 /= n2 ->
            GroundContradiction $
                "data type mismatch: " <> unName n1 <> " vs " <> unName n2

    -- Object: for every field k in right, left[k] <: right[k]
    (TObject fa, TObject fb) ->
        let cs = [ case Map.lookup k fa of
                        Just aTy -> IsSubtypeOf aTy bTy
                        Nothing  -> IsSubtypeOf TUnknown bTy
                 | (k, bTy) <- Map.toList fb ]
        in  Decomposed (Set.fromList cs)

    -- Tuple: element-wise
    (TTuple ts1, TTuple ts2)
        | length ts1 >= length ts2 ->
            Decomposed $ Set.fromList [IsSubtypeOf t1 t2 | (t1, t2) <- zip ts1 ts2]
        | otherwise ->
            GroundContradiction "tuple length mismatch"

    -- Array: covariant
    (TArray e1, TArray e2) ->
        Decomposed $ Set.singleton (IsSubtypeOf e1 e2)

    -- Intersection on left / Union on right → leave for branching
    (TIntersection _ _, _) -> Undecided
    (_, TUnion _ _)        -> Undecided

    -- TVar involved → leave for propagation/final check
    (TVar _, _) -> Undecided
    (_, TVar _) -> Undecided

    -- Anything else with no TVars → direct check
    _ | not (containsTVar a) && not (containsTVar b) ->
        if isSubtype defs a b
            then Trivial
            else GroundContradiction $
                "type mismatch: " <> showType a <> " is not a subtype of " <> showType b
      | otherwise -> Undecided

-- | Generate constraints based on variance.
mkVarianceConstraints :: Variance -> Type -> Type -> [Constraint]
mkVarianceConstraints v a b = case v of
    Covariant     -> [IsSubtypeOf a b]
    Contravariant -> [IsSubtypeOf b a]
    Invariant     -> [IsSubtypeOf a b, IsSubtypeOf b a]
    Bivariant     -> []

-- =========================================================================
-- Branching
-- =========================================================================

-- | Find a constraint that can be branched on.
findBranch :: Set Constraint -> Maybe [Set Constraint]
findBranch cs = go (Set.toList cs)
  where
    go [] = Nothing
    go (c:rest) = case branchOne c of
        Nothing       -> go rest
        Just branches ->
            let others = Set.fromList rest
            in  Just [Set.union others branch | branch <- branches]

-- | Try to branch a single constraint.
branchOne :: Constraint -> Maybe [Set Constraint]
branchOne (IsSubtypeOf a b) = case (a, b) of
    (TIntersection a1 a2, _) ->
        Just [ Set.singleton (IsSubtypeOf a1 b)
             , Set.singleton (IsSubtypeOf a2 b) ]
    (_, TUnion b1 b2) ->
        Just [ Set.singleton (IsSubtypeOf a b1)
             , Set.singleton (IsSubtypeOf a b2) ]
    _ -> Nothing

-- =========================================================================
-- Propagation
-- =========================================================================

-- | Propagate TVar bounds transitively until fixpoint.
propagateAll :: Map Name BoundInfo -> Set Constraint -> Set Constraint
propagateAll bounds cs =
    let newCs = propagateOnce bounds cs
    in  if newCs `Set.isSubsetOf` cs
            then cs
            else propagateAll bounds (Set.union cs newCs)

-- | One step of transitive propagation.
propagateOnce :: Map Name BoundInfo -> Set Constraint -> Set Constraint
propagateOnce _bounds cs =
    let varBounds = collectVarBounds cs
        newConstraints = concatMap pairBounds (Map.toList varBounds)
    in  Set.fromList $ filter (not . isTrivialConstraint) newConstraints
  where
    pairBounds (_, bi) =
        [ IsSubtypeOf l u | l <- Set.toList (biLowers bi)
                           , u <- Set.toList (biUppers bi) ]

-- | Collect variable bounds from a constraint set.
collectVarBounds :: Set Constraint -> Map Name BoundInfo
collectVarBounds = foldl addC Map.empty . Set.toList
  where
    addC acc (IsSubtypeOf (TVar n) upper) =
        Map.alter (Just . addU upper . fromMaybe emptyBoundInfo) n acc
    addC acc (IsSubtypeOf lower (TVar n)) =
        Map.alter (Just . addL lower . fromMaybe emptyBoundInfo) n acc
    addC acc _ = acc

    addU ty bi = bi { biUppers = Set.insert ty (biUppers bi) }
    addL ty bi = bi { biLowers = Set.insert ty (biLowers bi) }

-- =========================================================================
-- Final contradiction check
-- =========================================================================

-- | Check remaining constraints for contradictions.
checkContradictions :: TypeDefs -> Map Name BoundInfo -> Set Constraint -> SolveResult
checkContradictions defs bounds cs = go (Set.toList cs)
  where
    go [] = SolveSuccess
    go (IsSubtypeOf a b : rest) = checkOne a b rest

    checkOne a b rest
        -- Ground: direct isSubtype
        | not (containsTVar a) && not (containsTVar b) =
            if isSubtype defs a b
                then go rest
                else SolveContradiction $
                    "type mismatch: " <> showType a <> " is not a subtype of " <> showType b
    checkOne (TVar n) b rest
        | TVar _n2 <- b = go rest
        | not (containsTVar b) =
            case Map.lookup n bounds of
                Just bi | not (Set.null (biUppers bi)) ->
                    let upperOk = any (\u -> checkGround defs u b) (Set.toList (biUppers bi))
                    in  if upperOk then go rest
                        else SolveContradiction $
                            "type variable " <> unName n <> " (upper bounded) is not a subtype of " <> showType b
                _ -> go rest
    checkOne a (TVar n) rest
        | not (containsTVar a) =
            case Map.lookup n bounds of
                Just bi | not (Set.null (biLowers bi)) ->
                    let lowerOk = any (\l -> checkGround defs a l) (Set.toList (biLowers bi))
                    in  if lowerOk then go rest
                        else SolveContradiction $
                            showType a <> " is not a subtype of type variable " <> unName n <> " (lower bounded)"
                _ -> go rest
    checkOne _ _ rest = go rest

-- | Check ground subtype relationship directly on Type.
checkGround :: TypeDefs -> Type -> Type -> Bool
checkGround defs a b
    | containsTVar a || containsTVar b = False
    | otherwise = isSubtype defs a b
