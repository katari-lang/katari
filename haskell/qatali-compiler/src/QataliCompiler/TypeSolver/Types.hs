{- | Data structures for the constraint solver.

Defines the core types used throughout the solver:
  * 'Level' — generics nesting level
  * 'GenericInfo' — metadata for each generic type variable
  * 'UnknownBounds' — accumulated lower/upper bounds for unknown variables
  * 'Substitution' — mapping from unknown variable names to types
  * 'SolverEnv' — immutable environment shared across branches
-}
module QataliCompiler.TypeSolver.Types (
    Level,
    GenericInfo (..),
    UnknownBounds (..),
    emptyBounds,
    addLowerBound,
    addUpperBound,
    Substitution,
    SolverEnv (..),
) where

import           Data.Map.Strict                    (Map)
import           Data.Set                           (Set)
import qualified Data.Set                           as Set

import           QataliCompiler.Name                (Name)
import           QataliCompiler.Type.Normalize      (TypeDefs)
import           QataliCompiler.Type.Type           (Bound, Type)
import           QataliCompiler.TypeSolver.Constraint (Assumption)

-- ---------------------------------------------------------------------------
-- Level

-- | Generics nesting level. Higher levels depend on lower levels,
-- but not vice versa.
type Level = Int

-- ---------------------------------------------------------------------------
-- GenericInfo

-- | Metadata for a generic type variable introduced by the user
-- (or by pattern matching).
data GenericInfo = GenericInfo
    { giName  :: !Name
    -- ^ The variable name (unique within the solver context)
    , giLevel :: !Level
    -- ^ Nesting level (0 = outermost)
    , giBound :: !Bound
    -- ^ The declared bound (BoundSub, BoundSup, BoundIs, or BoundNone)
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- UnknownBounds

-- | Accumulated lower and upper bounds for a solver-introduced unknown
-- variable. An unknown @X@ is satisfiable when there exists a type @T@
-- such that every lower bound <: T and T <: every upper bound.
data UnknownBounds = UnknownBounds
    { ubLowers :: !(Set Type)
    -- ^ Lower bounds: each L in this set satisfies @L <: X@
    , ubUppers :: !(Set Type)
    -- ^ Upper bounds: each U in this set satisfies @X <: U@
    }
    deriving (Eq, Show)

-- | Empty bounds (no constraints on the unknown variable).
emptyBounds :: UnknownBounds
emptyBounds = UnknownBounds Set.empty Set.empty

-- | Add a lower bound to the unknown variable's bounds.
addLowerBound :: Type -> UnknownBounds -> UnknownBounds
addLowerBound ty ub = ub { ubLowers = Set.insert ty (ubLowers ub) }

-- | Add an upper bound to the unknown variable's bounds.
addUpperBound :: Type -> UnknownBounds -> UnknownBounds
addUpperBound ty ub = ub { ubUppers = Set.insert ty (ubUppers ub) }

-- ---------------------------------------------------------------------------
-- Substitution

-- | A mapping from unknown variable names to their resolved types.
type Substitution = Map Name Type

-- ---------------------------------------------------------------------------
-- SolverEnv

-- | Immutable environment shared across all branches during solving.
data SolverEnv = SolverEnv
    { seTypeDefs       :: !TypeDefs
    -- ^ All type/data/effect definitions in scope
    , seGenerics       :: !(Map Name GenericInfo)
    -- ^ Metadata for each generic type variable
    , seAssumptions    :: !(Set Assumption)
    -- ^ Known subtype relationships (from generics bounds)
    , seGenericBounds  :: !(Map Name (Type, Type))
    -- ^ Effective (lower, upper) bounds for each generic,
    -- computed from assumptions + declared bounds.
    -- Used by decomposition for 'TVar' constraints.
    }
    deriving (Show)
