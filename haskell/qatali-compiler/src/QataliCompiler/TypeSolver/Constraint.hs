{- | Subtype constraints and assumptions for the constraint solver.

A 'Constraint' @IsSubtypeOf a b@ asserts that @a <: b@ must hold.
An 'Assumption' is structurally identical — it records a known subtype
relationship (e.g. from a generics bound).
-}
module QataliCompiler.TypeSolver.Constraint (
    Constraint (..),
    Assumption,
    (?<:),
    constraintTVars,
    overConstraint,
    isGroundConstraint,
    isTrivialConstraint,
) where

import           Data.Set               (Set)
import           QataliCompiler.Name    (Name)
import           QataliCompiler.Type.Type (Type (..), containsTVar, typeVarNames)

-- | A subtype constraint: @left <: right@.
data Constraint = IsSubtypeOf !Type !Type
    deriving (Eq, Ord, Show)

-- | An assumption is structurally the same as a constraint.
type Assumption = Constraint

-- | Infix constructor for readability: @a ?<: b = IsSubtypeOf a b@.
(?<:) :: Type -> Type -> Constraint
(?<:) = IsSubtypeOf
infixl 4 ?<:

-- | Collect all type variable names from both sides.
constraintTVars :: Constraint -> Set Name
constraintTVars (IsSubtypeOf a b) = typeVarNames a <> typeVarNames b

-- | Apply a function to both sides of a constraint.
overConstraint :: (Type -> Type) -> Constraint -> Constraint
overConstraint f (IsSubtypeOf a b) = IsSubtypeOf (f a) (f b)

-- | Both sides are ground (no TVar)?
isGroundConstraint :: Constraint -> Bool
isGroundConstraint (IsSubtypeOf a b) = not (containsTVar a) && not (containsTVar b)

-- | Trivially true: same type, TNever <: _, or _ <: TUnknown.
isTrivialConstraint :: Constraint -> Bool
isTrivialConstraint (IsSubtypeOf a b)
    | a == b    = True
    | TNever <- a = True
    | TUnknown <- b = True
    | otherwise = False
