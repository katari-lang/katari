{- | Assumption decomposition for the constraint solver.

Assumptions (from pattern matching) are decomposed structurally to derive
effective bounds for generic type variables.  This is analogous to
@calculateGenericBounds@ in memento-compiler.

Algorithm:
  1. Decompose each assumption by structure (same-name data types by variance,
     unions, intersections, functions).
  2. Keep constraints that directly mention a generic (@TVar G <: T@ or @T <: TVar G@).
  3. Propagate transitive relationships (if @T <: G@ and @G <: U@, then @T <: U@).
  4. After propagation, re-decompose (fixpoint) to catch transitive structural bounds.
  5. Collect per-generic lower/upper bounds.
-}
module QataliCompiler.TypeSolver.SolveAssumptions (
    calculateGenericBounds,
) where

import           Data.Map.Strict                       (Map)
import qualified Data.Map.Strict                       as Map
import           Data.Set                              (Set)
import qualified Data.Set                              as Set

import           Data.Proxy                            (Proxy (..))
import           QataliCompiler.Name                   (Name (..))
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Type.Defs              (TypeDefs,
                                                        getVariancesDef)
import           QataliCompiler.Type.Type
import           QataliCompiler.TypeSolver.Constraint  (Assumption,
                                                        Constraint (..),
                                                        mkVarianceConstraints,
                                                        propagateTransitive)
import           QataliCompiler.TypeSolver.Types       (GenericInfo (..))

-- ---------------------------------------------------------------------------
-- Public API

-- | Calculate effective (lower bound, upper bound) for each generic variable
-- by decomposing assumptions structurally and collecting bounds.
--
-- Uses a fixpoint loop: decompose → propagate → re-decompose until stable.
calculateGenericBounds
    :: TypeDefs
    -> Map Name GenericInfo
    -> Set Assumption
    -> Map Name (Type, Type)
calculateGenericBounds defs generics assumptions =
    let -- Fixpoint: decompose → propagate → re-decompose
        stable = decomposeAndPropagateFixpoint defs generics assumptions

        -- Collect per-generic bounds
        genericNames = Map.keys generics
        boundsMap = Map.fromList
            [ (name, collectBounds name stable)
            | name <- genericNames
            ]

    in  Map.mapWithKey (mergeDeclaredBounds generics) boundsMap

-- ---------------------------------------------------------------------------
-- Fixpoint: decompose + propagate

-- | Run decompose → propagate in a fixpoint loop until no new constraints.
decomposeAndPropagateFixpoint
    :: TypeDefs
    -> Map Name GenericInfo
    -> Set Assumption
    -> Set Assumption
decomposeAndPropagateFixpoint defs generics initial = go (50 :: Int) Set.empty initial
  where
    go 0 acc _todo = acc
    go fuel acc todo =
        -- Step 1: Decompose
        let results = Set.map (decomposeAssumption defs generics) todo
            remained  = Set.unions $ Set.map fst results
            decomposed = Set.unions $ Set.map snd results
            acc' = Set.union acc remained
        in  if Set.null decomposed
                then
                    -- Step 2: Propagate on accumulated
                    let propagated = propagateAll acc'
                    in  if Set.size propagated == Set.size acc'
                            then acc'  -- Fixpoint reached
                            else
                                -- New constraints from propagation → re-decompose them
                                let newFromPropagation = Set.difference propagated acc'
                                in  go (fuel - 1) acc' newFromPropagation
                else go (fuel - 1) acc' decomposed

-- ---------------------------------------------------------------------------
-- Decompose assumptions

-- | Decompose a single assumption.
-- Returns @(remained, freshlyDecomposed)@.
decomposeAssumption
    :: TypeDefs
    -> Map Name GenericInfo
    -> Assumption
    -> (Set Assumption, Set Assumption)
decomposeAssumption defs generics (IsSubtypeOf _sp t1 t2)
    -- Trivial cases
    | t1 == t2  = (Set.empty, Set.empty)
    | TNever <- t1 = (Set.empty, Set.empty)
    | TUnknown <- t2 = (Set.empty, Set.empty)
    -- No generics involved → drop
    | not (containsTVar t1 || containsTVar t2) = (Set.empty, Set.empty)
    | otherwise = decomposeByStructure t1 t2
  where
    isGeneric n = Map.member n generics

    decomposeByStructure left right = case (left, right) of
        -- Union on left: (A | B) <: C → A <: C, B <: C
        (TUnion a b, _) ->
            (Set.empty, Set.fromList [IsSubtypeOf NoSpan a right, IsSubtypeOf NoSpan b right])

        -- Intersection on right: A <: (B & C) → A <: B, A <: C
        (_, TIntersection a b) ->
            (Set.empty, Set.fromList [IsSubtypeOf NoSpan left a, IsSubtypeOf NoSpan left b])

        -- Generic on either side → keep for bound extraction
        (TVar g, _) | isGeneric g ->
            (Set.singleton (IsSubtypeOf NoSpan left right), Set.empty)
        (_, TVar g) | isGeneric g ->
            (Set.singleton (IsSubtypeOf NoSpan left right), Set.empty)

        -- Same data type → decompose by variance
        (TData n1 args1, TData n2 args2)
            | n1 == n2, length args1 == length args2 ->
                let variances = getVariancesDef defs n1 (length args1)
                    newCs = concat $ zipWith3 (mkVarianceConstraints NoSpan) variances args1 args2
                in  (Set.empty, Set.fromList newCs)

        -- Same data type on left, union on right
        (TData n1 args1, _) ->
            let rightAlts = flattenUnion right
                matching  = [ args2
                            | TData n2 args2 <- rightAlts
                            , n1 == n2
                            , length args1 == length args2
                            ]
            in  case matching of
                    [] -> (Set.empty, Set.empty)
                    _ ->
                        let variances = getVariancesDef defs n1 (length args1)
                            argAssumptions idx =
                                let arg2s = map (!! idx) matching
                                    v = variances !! idx
                                    arg1 = args1 !! idx
                                in  case v of
                                        Covariant ->
                                            [IsSubtypeOf NoSpan arg1 (foldr1 TUnion arg2s)]
                                        Contravariant ->
                                            [IsSubtypeOf NoSpan (foldr1 TIntersection arg2s) arg1]
                                        Invariant ->
                                            [ IsSubtypeOf NoSpan arg1 (foldr1 TUnion arg2s)
                                            , IsSubtypeOf NoSpan (foldr1 TIntersection arg2s) arg1
                                            ]
                                        Bivariant -> []
                        in  (Set.empty, Set.fromList $ concatMap argAssumptions [0 .. length args1 - 1])

        -- Function types
        (TFun ps1 r1 _, TFun ps2 r2 _)
            | length ps1 == length ps2 ->
                let paramCs = [IsSubtypeOf NoSpan (fpType p2) (fpType p1) | (p1, p2) <- zip ps1 ps2]
                    retC    = IsSubtypeOf NoSpan r1 r2
                in  (Set.empty, Set.fromList (retC : paramCs))

        -- Array types
        (TArray e1, TArray e2) ->
            (Set.empty, Set.singleton (IsSubtypeOf NoSpan e1 e2))

        -- Cannot decompose further
        _ -> (Set.empty, Set.empty)

-- ---------------------------------------------------------------------------
-- Propagation

-- | Propagate transitive relationships until fixpoint.
propagateAll :: Set Assumption -> Set Assumption
propagateAll = propagateTransitive (Proxy :: Proxy TyVarKind) 50

-- ---------------------------------------------------------------------------
-- Collect bounds

-- | Collect lower and upper bounds for a specific generic.
collectBounds :: Name -> Set Assumption -> ([Type], [Type])
collectBounds name assumptions =
    let asList = Set.toList assumptions
        lowers = [ t | IsSubtypeOf _ t (TVar n) <- asList, n == name, not (isTVar t) ]
        uppers = [ t | IsSubtypeOf _ (TVar n) t <- asList, n == name, not (isTVar t) ]
    in  (lowers, uppers)
  where
    isTVar (TVar _) = True
    isTVar _        = False

-- ---------------------------------------------------------------------------
-- Merge with declared bounds

-- | Merge assumption-derived bounds with declared bounds from GenericInfo.
mergeDeclaredBounds
    :: Map Name GenericInfo
    -> Name
    -> ([Type], [Type])
    -> (Type, Type)
mergeDeclaredBounds generics name (lowers, uppers) =
    let gi = Map.lookup name generics
        declaredUpper = case gi of
            Just g -> case giBound g of
                BoundSub ty -> [ty]
                BoundIs ty  -> [ty]
                _           -> []
            Nothing -> []
        declaredLower = case gi of
            Just g -> case giBound g of
                BoundSup ty -> [ty]
                BoundIs ty  -> [ty]
                _           -> []
            Nothing -> []
        allUppers = uppers ++ declaredUpper
        allLowers = lowers ++ declaredLower
        effectiveUpper = case allUppers of
            []  -> TUnknown
            [t] -> t
            ts  -> foldr1 TIntersection ts
        effectiveLower = case allLowers of
            []  -> TNever
            [t] -> t
            ts  -> foldr1 TUnion ts
    in  (effectiveLower, effectiveUpper)

-- ---------------------------------------------------------------------------
-- Utility

flattenUnion :: Type -> [Type]
flattenUnion (TUnion a b) = flattenUnion a ++ flattenUnion b
flattenUnion t            = [t]
