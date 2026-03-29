{- | Constraint decomposition for the solver.

Structural decomposition following memento-compiler's architecture.
Each constraint is classified as:

  * 'Trivial' — always true, remove it
  * 'Decomposed' — replaced by smaller constraints
  * 'Kept' — cannot decompose further (contains variables); leave for branching
  * 'Contradiction' — unsatisfiable (carries 'SrcSpan' from parent constraint)

Branching logic (intersection-on-left, union-on-right, unknown-vs-nominal)
is handled separately in Solve.hs, not here.
-}
module QataliCompiler.TypeSolver.Decompose (
    DecomposeResult (..),
    decomposeConstraint,
    decomposeAll,
) where

import qualified Data.Map.Strict                       as Map
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.Text                             (Text)
import qualified Data.Text                             as T

import           QataliCompiler.Name                   (Name (..))
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Type.Normalize         (normalizeEffect,
                                                         getVariancesDef)
import           QataliCompiler.Type.Subtype           (isSubtype,
                                                         isEffectSubtype)
import           QataliCompiler.Type.Type
import           QataliCompiler.TypeSolver.Constraint
import           QataliCompiler.TypeSolver.Types

-- ---------------------------------------------------------------------------
-- DecomposeResult

-- | The result of decomposing a single constraint.
data DecomposeResult
    = Trivial
    -- ^ The constraint is trivially true; remove it.
    | Decomposed ![Constraint]
    -- ^ Replace the constraint with these smaller constraints.
    | Kept
    -- ^ Cannot decompose further (contains variables or needs branching).
    -- Left for branchConstraints in Solve.hs.
    | Contradiction !SrcSpan !Text
    -- ^ The constraint is unsatisfiable (carries the source location).
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Public API

-- | Decompose all constraints until fixpoint.
-- Returns only the 'Kept' constraints (the rest are resolved or decomposed).
-- Fails with Left on contradiction (with source location).
decomposeAll :: SolverEnv -> Set Constraint -> Either (SrcSpan, Text) (Set Constraint)
decomposeAll env cs = go (100 :: Int) cs
  where
    go 0 remaining = Right remaining  -- safety limit
    go fuel remaining =
        case decomposeStep env remaining of
            Left err -> Left err
            Right (kept, toDecompose)
                | Set.null toDecompose -> Right kept
                | otherwise -> go (fuel - 1) (Set.union kept toDecompose)

-- | Single decomposition step: process each constraint once.
-- Returns (kept, freshlyDecomposed).
decomposeStep :: SolverEnv -> Set Constraint -> Either (SrcSpan, Text) (Set Constraint, Set Constraint)
decomposeStep env cs = do
    results <- mapM (decomposeOne env) (Set.toList cs)
    let (kept, decomposed) = mconcat results
    pure (Set.fromList kept, Set.fromList decomposed)

-- | Decompose a single constraint.
-- Returns (kept, freshlyDecomposed).
decomposeOne :: SolverEnv -> Constraint -> Either (SrcSpan, Text) ([Constraint], [Constraint])
decomposeOne env c =
    case decomposeConstraint env c of
        Trivial          -> Right ([], [])
        Decomposed newCs -> Right ([], newCs)
        Kept             -> Right ([c], [])
        Contradiction sp e -> Left (sp, e)

-- ---------------------------------------------------------------------------
-- Main decomposition function

-- | Decompose a single constraint given the solver environment.
decomposeConstraint :: SolverEnv -> Constraint -> DecomposeResult
decomposeConstraint env (IsSubtypeOf sp left right) =
    decompose env sp left right

-- ---------------------------------------------------------------------------
-- Internal dispatcher

decompose :: SolverEnv -> SrcSpan -> Type -> Type -> DecomposeResult
decompose env sp left right = case (left, right) of
    -- -----------------------------------------------------------------
    -- 1. Top/Bottom
    -- -----------------------------------------------------------------
    (TNever, _)    -> Trivial
    (_, TUnknown)  -> Trivial

    -- -----------------------------------------------------------------
    -- 2. Same type
    -- -----------------------------------------------------------------
    _ | left == right -> Trivial

    -- -----------------------------------------------------------------
    -- 3. Generic guard: if either side is a generic, keep for later
    --    (generic bounds are resolved by calculateGenericBounds)
    -- -----------------------------------------------------------------
    (TVar gName, _)
        | Map.member gName (seGenerics env) ->
            -- Replace with effective upper bound and re-decompose
            let upper = effectiveUpperBound env gName
            in  Decomposed [IsSubtypeOf sp upper right]
    (_, TVar gName)
        | Map.member gName (seGenerics env) ->
            let lower = effectiveLowerBound env gName
            in  Decomposed [IsSubtypeOf sp left lower]
    -- TVar not in generics map → keep (could be from outer scope)
    (TVar _, _) -> Kept
    (_, TVar _) -> Kept

    -- -----------------------------------------------------------------
    -- 4. Ground types: no unknowns/generics → use direct isSubtype
    -- -----------------------------------------------------------------
    _ | isGround left && isGround right ->
        let defs = seTypeDefs env
        in  if isSubtype defs left right
                then Trivial
                else Contradiction sp $
                    "type mismatch: " <> showType left
                    <> " is not a subtype of " <> showType right

    -- -----------------------------------------------------------------
    -- 5. Union on left: (A | B) <: C → {A <: C, B <: C}
    -- -----------------------------------------------------------------
    (TUnion a1 a2, _) ->
        Decomposed [IsSubtypeOf sp a1 right, IsSubtypeOf sp a2 right]

    -- -----------------------------------------------------------------
    -- 6. Intersection on right: A <: (B & C) → {A <: B, A <: C}
    -- -----------------------------------------------------------------
    (_, TIntersection b1 b2) ->
        Decomposed [IsSubtypeOf sp left b1, IsSubtypeOf sp left b2]

    -- -----------------------------------------------------------------
    -- 7. Intersection on left / Union on right → Kept for branching
    -- -----------------------------------------------------------------
    (TIntersection _ _, _) -> Kept
    (_, TUnion _ _)        -> Kept

    -- -----------------------------------------------------------------
    -- 8. Function subtyping: params contravariant, return covariant, effect covariant
    -- -----------------------------------------------------------------
    (TFun ps1 r1 e1, TFun ps2 r2 e2)
        | length ps1 == length ps2 ->
            let defs = seTypeDefs env
                paramCs = [IsSubtypeOf sp (fpType p2) (fpType p1) | (p1, p2) <- zip ps1 ps2]
                retC    = IsSubtypeOf sp r1 r2
                effOk   = isEffectSubtype defs
                            (normalizeEffect defs e1) (normalizeEffect defs e2)
            in  if effOk
                    then Decomposed (retC : paramCs)
                    else Contradiction sp "effect mismatch in function subtype"
        | otherwise ->
            Contradiction sp $
                "function arity mismatch: " <> T.pack (show (length ps1))
                <> " vs " <> T.pack (show (length ps2))

    -- -----------------------------------------------------------------
    -- 9. Same nominal type → decompose by variance
    -- -----------------------------------------------------------------
    (TData n1 args1, TData n2 args2)
        | n1 == n2 && length args1 == length args2 ->
            decomposeByVariance env sp n1 args1 args2
        | n1 /= n2 ->
            Contradiction sp $
                "data type mismatch: " <> unName n1 <> " vs " <> unName n2
        | otherwise ->
            Contradiction sp $
                "arity mismatch for " <> unName n1 <> ": "
                <> T.pack (show (length args1)) <> " vs "
                <> T.pack (show (length args2))

    -- Array: covariant
    (TArray e1, TArray e2) ->
        Decomposed [IsSubtypeOf sp e1 e2]

    -- -----------------------------------------------------------------
    -- 10. Cross-category mismatches (concrete vs concrete)
    -- -----------------------------------------------------------------
    (TData n _, TPrim p) ->
        Contradiction sp $ "data type " <> unName n <> " is not a subtype of " <> showPrim p
    (TPrim p, TData n _) ->
        Contradiction sp $ showPrim p <> " is not a subtype of data type " <> unName n
    (TData n _, TLit l) ->
        Contradiction sp $ "data type " <> unName n <> " is not a subtype of " <> showLit l
    (TLit l, TData n _) ->
        Contradiction sp $ showLit l <> " is not a subtype of data type " <> unName n
    (TFun {}, TPrim p) ->
        Contradiction sp $ "function is not a subtype of " <> showPrim p
    (TPrim p, TFun {}) ->
        Contradiction sp $ showPrim p <> " is not a subtype of function"
    (TFun {}, TLit l) ->
        Contradiction sp $ "function is not a subtype of " <> showLit l
    (TLit l, TFun {}) ->
        Contradiction sp $ showLit l <> " is not a subtype of function"
    (TArray _, TPrim p) ->
        Contradiction sp $ "array is not a subtype of " <> showPrim p
    (TPrim p, TArray _) ->
        Contradiction sp $ showPrim p <> " is not a subtype of array"
    (TArray _, TLit l) ->
        Contradiction sp $ "array is not a subtype of " <> showLit l
    (TLit l, TArray _) ->
        Contradiction sp $ showLit l <> " is not a subtype of array"
    (TFun {}, TData n _) ->
        Contradiction sp $ "function is not a subtype of " <> unName n
    (TData n _, TFun {}) ->
        Contradiction sp $ unName n <> " is not a subtype of function"
    (TFun {}, TArray _) ->
        Contradiction sp "function is not a subtype of array"
    (TArray _, TFun {}) ->
        Contradiction sp "array is not a subtype of function"
    (TArray _, TData n _) ->
        Contradiction sp $ "array is not a subtype of " <> unName n
    (TData n _, TArray _) ->
        Contradiction sp $ unName n <> " is not a subtype of array"

    -- -----------------------------------------------------------------
    -- 11. Contains type variables → Kept for branching
    -- -----------------------------------------------------------------
    _ -> Kept

-- ---------------------------------------------------------------------------
-- Helpers

-- | Does this type contain no unknowns or generics?
isGround :: Type -> Bool
isGround = \case
    TUnknownVar _ -> False
    TVar _        -> False
    TUnion a b    -> isGround a && isGround b
    TIntersection a b -> isGround a && isGround b
    TData _ args  -> all isGround args
    TFun ps r _   -> all (isGround . fpType) ps && isGround r
    TArray e      -> isGround e
    _             -> True  -- TPrim, TLit, TNever, TUnknown

-- | Get the effective upper bound of a generic.
effectiveUpperBound :: SolverEnv -> Name -> Type
effectiveUpperBound env name =
    case Map.lookup name (seGenericBounds env) of
        Just (_, upper) -> upper
        Nothing         -> TUnknown

-- | Get the effective lower bound of a generic.
effectiveLowerBound :: SolverEnv -> Name -> Type
effectiveLowerBound env name =
    case Map.lookup name (seGenericBounds env) of
        Just (lower, _) -> lower
        Nothing         -> TNever

-- ---------------------------------------------------------------------------
-- Variance-based decomposition

decomposeByVariance :: SolverEnv -> SrcSpan -> Name -> [Type] -> [Type] -> DecomposeResult
decomposeByVariance env sp dName args1 args2 =
    let defs = seTypeDefs env
        variances = getVariancesDef defs dName (length args1)
        cs = concat $ zipWith3 (mkVarianceConstraints sp) variances args1 args2
    in  Decomposed cs

mkVarianceConstraints :: SrcSpan -> Variance -> Type -> Type -> [Constraint]
mkVarianceConstraints sp v a b = case v of
    Covariant     -> [IsSubtypeOf sp a b]
    Contravariant -> [IsSubtypeOf sp b a]
    Invariant     -> [IsSubtypeOf sp a b, IsSubtypeOf sp b a]
    Bivariant     -> []
