{- | Constraint solver for the Qatali type system.

Following memento-compiler's recursive branching architecture:

  1. 'substInstancesAsPossible' — eagerly substitute known variables
  2. 'calculateGenericBounds' — compute generic bounds from assumptions
  3. 'decomposeAll' — structural decomposition to fixpoint
  4. 'branchConstraints' — if branching needed, split and recurse
  5. No branching — propagate, collect substitutions, check contradictions

Any single branch succeeding means overall success.
-}
module QataliCompiler.TypeSolver.Solve (
    SolveResult (..),
    solve,
) where

import           Data.Map.Strict                       (Map)
import qualified Data.Map.Strict                       as Map
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.Text                             (Text)
import qualified Data.Text                             as T

import           QataliCompiler.Name                   (Name (..), mkName)
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Type.Normalize         (TypeDefs,
                                                         getVariancesDef)
import           QataliCompiler.Type.Type
import           QataliCompiler.TypeSolver.Constraint
import           QataliCompiler.TypeSolver.Decompose   (decomposeAll)
import           QataliCompiler.TypeSolver.SolveAssumptions (calculateGenericBounds)
import           QataliCompiler.TypeSolver.Substitute  (substInstancesAsPossible,
                                                         propagateAll,
                                                         collectFinalSubstitutions,
                                                         checkContradictions)
import           QataliCompiler.TypeSolver.Types

-- ---------------------------------------------------------------------------
-- Result

-- | Result of constraint solving.
data SolveResult
    = SolveSuccess
    | SolveContradiction !SrcSpan !Text
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Entry point

-- | Solve constraints under assumptions.
solve
    :: TypeDefs
    -> Map Name GenericInfo
    -> Set Assumption
    -> [Constraint]
    -> Map Name UnknownBounds
    -> SolveResult
solve defs generics assumptions constraints unknownBounds =
    let -- Convert unknown bounds to initial constraints
        boundsCs = boundsToConstraints unknownBounds
        allCs = Set.fromList (constraints ++ boundsCs)
        env0 = SolverEnv
            { seTypeDefs      = defs
            , seGenerics      = generics
            , seAssumptions   = assumptions
            , seGenericBounds = Map.empty  -- will be computed in solveRec
            }
    in  solveRec env0 assumptions allCs 50

-- ---------------------------------------------------------------------------
-- Recursive solver

-- | Recursive solver following memento-compiler's architecture.
solveRec :: SolverEnv -> Set Assumption -> Set Constraint -> Int -> SolveResult
solveRec env assumptions cs fuel
    | fuel <= 0 = SolveContradiction NoSpan "solver depth limit exceeded"
    | Set.null cs = SolveSuccess
    | otherwise =
        -- Step 1: substInstancesAsPossible
        let (as1, cs1, _subst1) = substInstancesAsPossible assumptions cs

            -- Step 2: calculateGenericBounds
            genBounds = calculateGenericBounds (seTypeDefs env) (seGenerics env) as1
            env1 = env { seGenericBounds = genBounds, seAssumptions = as1 }

        -- Step 3: decomposeAll
        in  case decomposeAll env1 cs1 of
                Left (sp, err) -> SolveContradiction sp err
                Right remaining
                    | Set.null remaining -> SolveSuccess
                    | otherwise ->
                        -- Step 4: branchConstraints
                        case branchConstraints env1 as1 remaining of
                            Nothing ->
                                -- No branching needed → propagate + check
                                let propagated = propagateAll remaining
                                    finalSubst = collectFinalSubstitutions propagated
                                    finalAs = Set.map (applySubst finalSubst) as1
                                    finalGenBounds = calculateGenericBounds (seTypeDefs env) (seGenerics env) finalAs
                                    env2 = env1 { seGenericBounds = finalGenBounds }
                                    finalCs = Set.map (applySubst finalSubst) propagated
                                in  case checkContradictions env2 finalCs of
                                        Just (sp, err) -> SolveContradiction sp err
                                        Nothing  -> SolveSuccess
                            Just branches ->
                                tryBranches env1 branches fuel

-- | Try each branch, return first success.
tryBranches :: SolverEnv -> [(Set Assumption, Set Constraint)] -> Int -> SolveResult
tryBranches _ [] _ = SolveContradiction NoSpan "all branches failed"
tryBranches env ((as, cs) : rest) fuel =
    case solveRec env as cs (fuel - 1) of
        SolveSuccess           -> SolveSuccess
        SolveContradiction _ _ -> tryBranches env rest fuel

-- ---------------------------------------------------------------------------
-- Branch constraints
-- (corresponds to memento's branchConstraints + branchConstraint)

-- | Find the first branchable constraint, split it, and return branches.
-- Each branch is (assumptions, constraints) — the branched constraint is
-- replaced with the branch's specific constraints, and any substitution
-- is applied to the remaining constraints and assumptions.
branchConstraints
    :: SolverEnv
    -> Set Assumption
    -> Set Constraint
    -> Maybe [(Set Assumption, Set Constraint)]
branchConstraints env as cs =
    case partitionFirst (branchConstraint env) (Set.toList cs) of
        Nothing -> Nothing
        Just (branches, remaining) ->
            Just $ map
                (\(subst, branchCs) ->
                    ( Set.map (applySubst subst) as
                    , Set.map (applySubst subst) $
                        Set.union (Set.fromList remaining) branchCs
                    ))
                branches

-- | Try to branch a single constraint.
-- Returns Nothing if no branching possible, or Just branches.
-- Each branch is (substitution, new constraints).
branchConstraint :: SolverEnv -> Constraint -> Maybe [(Substitution, Set Constraint)]
branchConstraint env (IsSubtypeOf sp left right) = case (left, right) of
    -- Intersection on left: (A & B) <: T → branch A <: T or B <: T
    (TIntersection a b, _) ->
        Just [ (Map.empty, Set.singleton (IsSubtypeOf sp a right))
             , (Map.empty, Set.singleton (IsSubtypeOf sp b right))
             ]

    -- Union on right: T <: (A | B) → branch T <: A or T <: B
    (_, TUnion a b) ->
        Just [ (Map.empty, Set.singleton (IsSubtypeOf sp left a))
             , (Map.empty, Set.singleton (IsSubtypeOf sp left b))
             ]

    -- Unknown var vs structured type
    (TUnknownVar xName, TFun params ret eff) ->
        Just (branchUnknownVsFunLeft env xName params ret eff)
    (TFun params ret eff, TUnknownVar xName) ->
        Just (branchFunVsUnknownRight env xName params ret eff)
    (TUnknownVar xName, TData dName dArgs) ->
        Just (branchUnknownVsNominalLeft env xName dName dArgs)
    (TData dName dArgs, TUnknownVar xName) ->
        Just (branchNominalVsUnknownRight env xName dName dArgs)
    (TUnknownVar xName, TArray elemTy) ->
        Just (branchUnknownVsArrayLeft xName elemTy)
    (TArray elemTy, TUnknownVar xName) ->
        Just (branchArrayVsUnknownRight xName elemTy)

    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Branch: Unknown vs Function

-- | X <: (params) => ret with eff
-- Branch 1: X = (freshParams) => freshRet with eff, + variance constraints
-- Branch 2: X = TNever
branchUnknownVsFunLeft :: SolverEnv -> Name -> [FunParam] -> Type -> Effect -> [(Substitution, Set Constraint)]
branchUnknownVsFunLeft _env xName params ret eff =
    let n = length params
        freshParamNames = [mkFreshName xName ("p" <> T.pack (show i)) | i <- [0 :: Int .. n - 1]]
        freshRetName = mkFreshName xName "ret"
        freshParamVars = map TUnknownVar freshParamNames
        freshRetVar = TUnknownVar freshRetName
        freshParams = zipWith (FunParam . fpName) params freshParamVars
        substShape = Map.singleton xName (TFun freshParams freshRetVar eff)
        -- Params contravariant: original param <: fresh param (NoSpan: solver-internal)
        paramCs = zipWith (\orig fresh -> IsSubtypeOf NoSpan (fpType orig) fresh) params freshParamVars
        retC = IsSubtypeOf NoSpan freshRetVar ret
        substNever = Map.singleton xName TNever
    in  [ (substShape, Set.fromList (retC : paramCs))
        , (substNever, Set.empty)
        ]

-- | (params) => ret with eff <: X
branchFunVsUnknownRight :: SolverEnv -> Name -> [FunParam] -> Type -> Effect -> [(Substitution, Set Constraint)]
branchFunVsUnknownRight _env xName params ret eff =
    let n = length params
        freshParamNames = [mkFreshName xName ("p" <> T.pack (show i)) | i <- [0 :: Int .. n - 1]]
        freshRetName = mkFreshName xName "ret"
        freshParamVars = map TUnknownVar freshParamNames
        freshRetVar = TUnknownVar freshRetName
        freshParams = zipWith (FunParam . fpName) params freshParamVars
        substShape = Map.singleton xName (TFun freshParams freshRetVar eff)
        -- Params contravariant: fresh param <: original param (NoSpan: solver-internal)
        paramCs = zipWith (\fresh orig -> IsSubtypeOf NoSpan fresh (fpType orig)) freshParamVars params
        retC = IsSubtypeOf NoSpan ret freshRetVar
        substUnknown = Map.singleton xName TUnknown
    in  [ (substShape, Set.fromList (retC : paramCs))
        , (substUnknown, Set.empty)
        ]

-- ---------------------------------------------------------------------------
-- Branch: Unknown vs Nominal (Data type)

-- | X <: Data<A1, ..., An>
branchUnknownVsNominalLeft :: SolverEnv -> Name -> Name -> [Type] -> [(Substitution, Set Constraint)]
branchUnknownVsNominalLeft env xName dName dArgs =
    let defs = seTypeDefs env
        variances = getVariancesDef defs dName (length dArgs)
        freshNames = [mkFreshName xName (unName dName <> T.pack (show i)) | i <- [0 :: Int .. length dArgs - 1]]
        freshVars = map TUnknownVar freshNames
        substShape = Map.singleton xName (TData dName freshVars)
        varianceCs = concat $ zipWith3 (mkVarianceConstraints NoSpan) variances freshVars dArgs
        substNever = Map.singleton xName TNever
    in  [ (substShape, Set.fromList varianceCs)
        , (substNever, Set.empty)
        ]

-- | Data<A1, ..., An> <: X
branchNominalVsUnknownRight :: SolverEnv -> Name -> Name -> [Type] -> [(Substitution, Set Constraint)]
branchNominalVsUnknownRight env xName dName dArgs =
    let defs = seTypeDefs env
        variances = getVariancesDef defs dName (length dArgs)
        freshNames = [mkFreshName xName (unName dName <> T.pack (show i)) | i <- [0 :: Int .. length dArgs - 1]]
        freshVars = map TUnknownVar freshNames
        substShape = Map.singleton xName (TData dName freshVars)
        varianceCs = concat $ zipWith3 (mkVarianceConstraints NoSpan) variances dArgs freshVars
        substUnknown = Map.singleton xName TUnknown
    in  [ (substShape, Set.fromList varianceCs)
        , (substUnknown, Set.empty)
        ]

-- ---------------------------------------------------------------------------
-- Branch: Unknown vs Array

-- | X <: Array<E>
branchUnknownVsArrayLeft :: Name -> Type -> [(Substitution, Set Constraint)]
branchUnknownVsArrayLeft xName elemTy =
    let freshElemName = mkFreshName xName "elem"
        freshElemVar = TUnknownVar freshElemName
        substShape = Map.singleton xName (TArray freshElemVar)
        substNever = Map.singleton xName TNever
    in  [ (substShape, Set.singleton (IsSubtypeOf NoSpan freshElemVar elemTy))
        , (substNever, Set.empty)
        ]

-- | Array<E> <: X
branchArrayVsUnknownRight :: Name -> Type -> [(Substitution, Set Constraint)]
branchArrayVsUnknownRight xName elemTy =
    let freshElemName = mkFreshName xName "elem"
        freshElemVar = TUnknownVar freshElemName
        substShape = Map.singleton xName (TArray freshElemVar)
        substUnknown = Map.singleton xName TUnknown
    in  [ (substShape, Set.singleton (IsSubtypeOf NoSpan elemTy freshElemVar))
        , (substUnknown, Set.empty)
        ]

-- ---------------------------------------------------------------------------
-- Helpers

-- | Generate variance-based constraints.
mkVarianceConstraints :: SrcSpan -> Variance -> Type -> Type -> [Constraint]
mkVarianceConstraints sp v a b = case v of
    Covariant     -> [IsSubtypeOf sp a b]
    Contravariant -> [IsSubtypeOf sp b a]
    Invariant     -> [IsSubtypeOf sp a b, IsSubtypeOf sp b a]
    Bivariant     -> []

-- | Convert unknown bounds to constraints.
boundsToConstraints :: Map Name UnknownBounds -> [Constraint]
boundsToConstraints = concatMap toCs . Map.toList
  where
    toCs (name, ub) =
        [IsSubtypeOf NoSpan l (TUnknownVar name) | l <- Set.toList (ubLowers ub)] ++
        [IsSubtypeOf NoSpan (TUnknownVar name) u | u <- Set.toList (ubUppers ub)]

-- | Apply a substitution to a constraint.
applySubst :: Substitution -> Constraint -> Constraint
applySubst subst = overConstraint (substituteUnknownVars subst)

-- | Create a fresh name for branching.
mkFreshName :: Name -> Text -> Name
mkFreshName (Name base) suffix = mkName (base <> "$" <> suffix)

-- | Find the first element that matches, returning the match result
-- and the remaining elements.
partitionFirst :: (a -> Maybe b) -> [a] -> Maybe (b, [a])
partitionFirst f = go []
  where
    go _ [] = Nothing
    go acc (x : rest) =
        case f x of
            Just b  -> Just (b, reverse acc ++ rest)
            Nothing -> go (x : acc) rest
