{- | Qatali Intermediate Representation (IR).

The IR is a lower-level, explicit representation of Qatali programs
that is suitable for interpretation or further compilation by the runtime.

Design goals:
  * All types are fully erased (type information used only during lowering)
  * Explicit closures and calling conventions
  * ANF-like structure: complex expressions are named, no nested applications

TODO: This is a placeholder. The actual IR design will be determined
      in collaboration with the qatali-runtime specification.
-}
module QataliCompiler.IR.IR (
    -- * Programs
    IRModule (..),
    IRDef (..),

    -- * Expressions (ANF-style)
    IRExpr (..),
    IRValue (..),
    IRAtom (..),

    -- * Instructions / operations
    IROp (..),
    IRBranch (..),

    -- * Types (runtime representation)
    IRType (..),
) where

import           Data.Text           (Text)
import           QataliCompiler.Name (ModuleName, Name)

-- ---------------------------------------------------------------------------
-- Top-level

-- | A compiled module in IR form.
data IRModule = IRModule
    { irModName :: !ModuleName
    , irDefs    :: ![IRDef]
    }
    deriving (Eq, Show)

-- | A top-level definition in the IR.
data IRDef
    = -- | A value definition: name, type, body
      IRDefVal !Name !IRType !IRExpr
    | -- | An externally-provided value (from the runtime)
      IRDefExtern !Name !IRType
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Expressions (ANF / let-normal form)

{- | An IR expression in Administrative Normal Form (ANF).
Complex computations are broken into a sequence of let bindings,
ensuring all arguments to operations are atomic values.
-}
data IRExpr
    = -- | @let x = val in rest@
      IRLet !Name !IRValue !IRExpr
    | -- | Tail position: return an atom
      IRTail !IRAtom
    | -- | Pattern match on an atom; optional default branch
      IRCase !IRAtom ![IRBranch] !(Maybe IRExpr)
    deriving (Eq, Show)

-- | A non-trivial value binding (right-hand side of IRLet).
data IRValue
    = -- | Just an atom (no computation)
      IRAtomV !IRAtom
    | -- | A primitive operation applied to atoms
      IROp !IROp ![IRAtom]
    | -- | Function call: @f(a1, a2, ...)@
      IRCall !IRAtom ![IRAtom]
    | -- | Create a closure over a function and captured variables
      IRClosure !Name ![IRAtom]
    | -- | Allocate a heap object of the given type
      IRAlloc !IRType
    deriving (Eq, Show)

{- | An atomic value: either a literal or a variable reference.
Atoms require no computation and can be passed directly.
-}
data IRAtom
    = IRVar !Name
    | IRInt !Integer
    | IRFlt !Double
    | IRStr !Text
    | IRBool !Bool
    | IRUnit
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Branching

-- | A single branch in a case expression.
data IRBranch = IRBranch
    { branchTag  :: !Text
    -- ^ Constructor tag or literal
    , branchVars :: ![Name]
    -- ^ Bound variables from deconstruction
    , branchBody :: !IRExpr
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Primitive operations

-- | Primitive operations provided by the runtime.
data IROp
    = -- Arithmetic
      OpAddInt
    | OpSubInt
    | OpMulInt
    | OpDivInt
    | OpModInt
    | OpAddFlt
    | OpSubFlt
    | OpMulFlt
    | OpDivFlt
    | -- Comparison
      OpEqInt
    | OpNeInt
    | OpLtInt
    | OpLeInt
    | OpGtInt
    | OpGeInt
    | OpEqFlt
    | OpNeFlt
    | OpLtFlt
    | OpLeFlt
    | OpGtFlt
    | OpGeFlt
    | -- Logic
      OpAnd
    | OpOr
    | OpNot
    | -- Strings
      OpConcat
    | OpLength
    | OpIndex
    -- TODO: add more as the runtime specification evolves
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Runtime types

{- | Type tags for the IR runtime representation.
Used for code generation and runtime type checking.
-}
data IRType
    = IRTInt
    | IRTFloat
    | IRTString
    | IRTBool
    | IRTUnit
    | -- | Function type (arity, return type)
      IRTFun ![IRType] !IRType
    | -- | Reference to a named type
      IRTRef !Text
    | -- | Untyped / unknown (for generics)
      IRTAny
    deriving (Eq, Show)
