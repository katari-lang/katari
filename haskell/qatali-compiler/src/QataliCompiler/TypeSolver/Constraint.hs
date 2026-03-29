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
) where

import           Data.Set               (Set)
import           QataliCompiler.Name    (Name)
import           QataliCompiler.SrcLoc  (SrcSpan (..))
import           QataliCompiler.Type.Type (Type (..), containsTVar, containsUnknownVar,
                                           typeVarNames, unknownVarNames)

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
