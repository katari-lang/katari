{- | Subtype constraints and assumptions for the constraint solver.

A 'Constraint' @IsSubtypeOf sp a b@ asserts that @a <: b@ must hold,
where @sp@ records the source location that generated this constraint.

An 'Assumption' is structurally identical — it records a known subtype
relationship (e.g. from a generics bound).

'Eq' and 'Ord' instances ignore 'SrcSpan' so that constraints can be
stored in 'Set' without location-based duplicates.
-}
module QataliCompiler.TypeSolver.Constraint (
    Constraint (..),
    Assumption,
    (?<:),
    withSpan,
    constraintSpan,
    constraintTVars,
    constraintUnknownVars,
    overConstraint,
    isGroundConstraint,
    isTrivialConstraint,
    hasVariables,
    mkVarianceConstraints,
    propagateTransitive,
) where

import           Data.Proxy             (Proxy)
import           Data.Set               (Set)
import qualified Data.Set               as Set
import           QataliCompiler.Name    (Name)
import           QataliCompiler.SrcLoc  (SrcSpan (..))
import           QataliCompiler.Type.Type (Type (..), TypeVar (..), Variance (..),
                                           containsTVar, containsUnknownVar,
                                           freeVarsOf, typeVarNames,
                                           unknownVarNames)

-- | A subtype constraint: @left <: right@ with source location.
data Constraint = IsSubtypeOf !SrcSpan !Type !Type
    deriving Show

-- | Eq ignores SrcSpan so Set membership is location-independent.
instance Eq Constraint where
    IsSubtypeOf _ a1 b1 == IsSubtypeOf _ a2 b2 = a1 == a2 && b1 == b2

-- | Ord ignores SrcSpan so Set ordering is location-independent.
instance Ord Constraint where
    compare (IsSubtypeOf _ a1 b1) (IsSubtypeOf _ a2 b2) = compare (a1, b1) (a2, b2)

-- | An assumption is structurally the same as a constraint.
type Assumption = Constraint

-- | Infix constructor for readability (no source location): @a ?<: b@.
(?<:) :: Type -> Type -> Constraint
a ?<: b = IsSubtypeOf NoSpan a b
infixl 4 ?<:

-- | Create a constraint with a source location.
withSpan :: SrcSpan -> Type -> Type -> Constraint
withSpan = IsSubtypeOf

-- | Extract the source location from a constraint.
constraintSpan :: Constraint -> SrcSpan
constraintSpan (IsSubtypeOf sp _ _) = sp

-- | Collect all type variable names from both sides.
constraintTVars :: Constraint -> Set Name
constraintTVars (IsSubtypeOf _ a b) = typeVarNames a <> typeVarNames b

-- | Collect all unknown variable names from both sides.
constraintUnknownVars :: Constraint -> Set Name
constraintUnknownVars (IsSubtypeOf _ a b) = unknownVarNames a <> unknownVarNames b

-- | Apply a function to both sides of a constraint, preserving the span.
overConstraint :: (Type -> Type) -> Constraint -> Constraint
overConstraint f (IsSubtypeOf sp a b) = IsSubtypeOf sp (f a) (f b)

-- | Both sides are ground (no TVar, no TUnknownVar)?
isGroundConstraint :: Constraint -> Bool
isGroundConstraint (IsSubtypeOf _ a b) =
    not (containsTVar a) && not (containsTVar b) &&
    not (containsUnknownVar a) && not (containsUnknownVar b)

-- | Trivially true: same type, TNever <: _, or _ <: TUnknown.
isTrivialConstraint :: Constraint -> Bool
isTrivialConstraint (IsSubtypeOf _ a b)
    | a == b    = True
    | TNever <- a = True
    | TUnknown <- b = True
    | otherwise = False

-- | Does this constraint contain any type variables or unknown variables?
hasVariables :: Constraint -> Bool
hasVariables (IsSubtypeOf _ a b) =
    containsTVar a || containsTVar b ||
    containsUnknownVar a || containsUnknownVar b

-- | Generate constraints from a variance-aware comparison of two types.
mkVarianceConstraints :: SrcSpan -> Variance -> Type -> Type -> [Constraint]
mkVarianceConstraints sp v a b = case v of
    Covariant     -> [IsSubtypeOf sp a b]
    Contravariant -> [IsSubtypeOf sp b a]
    Invariant     -> [IsSubtypeOf sp a b, IsSubtypeOf sp b a]
    Bivariant     -> []

-- ---------------------------------------------------------------------------
-- Transitive propagation (generic over variable kind)

-- | Propagate transitive relationships for variables of the given kind
-- until fixpoint or fuel exhaustion.
--
-- For each variable @v@ of the given kind, if @A <: v@ and @v <: B@ both
-- exist, add @A <: B@.
propagateTransitive :: forall v. TypeVar v => Proxy v -> Int -> Set Constraint -> Set Constraint
propagateTransitive p fuel = go fuel
  where
    go 0 cs = cs
    go n cs =
        case propagateOnceWith cs of
            Nothing    -> cs
            Just newCs -> go (n - 1) (Set.union cs newCs)

    propagateOnceWith :: Set Constraint -> Maybe (Set Constraint)
    propagateOnceWith cs =
        let asList = Set.toList cs
            vars = Set.toList $ Set.unions
                [ freeVarsOf p l <> freeVarsOf p r
                | IsSubtypeOf _ l r <- asList
                ]
            boundsFor name =
                let lowers = [ t | IsSubtypeOf _ t rhs <- asList, extractVar p rhs == Just name ]
                    uppers = [ t | IsSubtypeOf _ lhs t <- asList, extractVar p lhs == Just name ]
                in  [ IsSubtypeOf NoSpan lo hi | lo <- lowers, hi <- uppers ]
            newConstraints = filter isActuallyNew (concatMap boundsFor vars)
            isActuallyNew c@(IsSubtypeOf _ a b) =
                a /= b && not (Set.member c cs)
                && case (a, b) of
                    (TNever, _)   -> False
                    (_, TUnknown) -> False
                    _             -> True
        in  if null newConstraints
                then Nothing
                else Just (Set.fromList newConstraints)
