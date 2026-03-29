{- | Instructions and terminators for the Qatali IR.

Instructions perform computation without altering control flow.
Terminators end a basic block and transfer control to another block,
return from the function, or interact with the algebraic effect system.

Every function call (TCall, TCallDirect) terminates a block, making
each call site a potential async suspension / PostgreSQL persistence point.
-}
module QataliCompiler.IR.Instruction (
    -- * Instructions (no control flow)
    Instr (..),
    -- * Terminators (control flow)
    Terminator (..),
    -- * Switch cases
    SwitchCase (..),
    -- * Handle-related types
    HandleInfo (..),
    HandlerDef (..),
    ReturnDef (..),
) where

import           Data.Text              (Text)
import           Data.Word              (Word16)
import           GHC.Generics           (Generic)

import           QataliCompiler.IR.Types

-- ---------------------------------------------------------------------------
-- Instructions

-- | A flat instruction that does not alter control flow.
-- The first 'VarId' argument is always the destination (result).
data Instr
    = -- ** Constants and moves
      ILoadConst   !VarId !ConstId
      -- ^ @dst = constants[constId]@
    | ILoadNull    !VarId
      -- ^ @dst = null@
    | IMove        !VarId !VarId
      -- ^ @dst = src@

    -- ** Integer arithmetic
    | IAddInt      !VarId !VarId !VarId   -- ^ @dst = lhs + rhs@ (integer)
    | ISubInt      !VarId !VarId !VarId   -- ^ @dst = lhs - rhs@ (integer)
    | IMulInt      !VarId !VarId !VarId   -- ^ @dst = lhs * rhs@ (integer)
    | IDivInt      !VarId !VarId !VarId   -- ^ @dst = lhs / rhs@ (integer)
    | IModInt      !VarId !VarId !VarId   -- ^ @dst = lhs % rhs@ (integer)
    | INegInt      !VarId !VarId          -- ^ @dst = -src@ (integer)

    -- ** Float arithmetic
    | IAddFlt      !VarId !VarId !VarId   -- ^ @dst = lhs + rhs@ (float)
    | ISubFlt      !VarId !VarId !VarId   -- ^ @dst = lhs - rhs@ (float)
    | IMulFlt      !VarId !VarId !VarId   -- ^ @dst = lhs * rhs@ (float)
    | IDivFlt      !VarId !VarId !VarId   -- ^ @dst = lhs / rhs@ (float)
    | INegFlt      !VarId !VarId          -- ^ @dst = -src@ (float)

    -- ** Comparison (polymorphic, result is Bool)
    | ICmpEq       !VarId !VarId !VarId   -- ^ @dst = (lhs == rhs)@
    | ICmpNe       !VarId !VarId !VarId   -- ^ @dst = (lhs /= rhs)@
    | ICmpLt       !VarId !VarId !VarId   -- ^ @dst = (lhs <  rhs)@
    | ICmpLe       !VarId !VarId !VarId   -- ^ @dst = (lhs <= rhs)@
    | ICmpGt       !VarId !VarId !VarId   -- ^ @dst = (lhs >  rhs)@
    | ICmpGe       !VarId !VarId !VarId   -- ^ @dst = (lhs >= rhs)@

    -- ** Boolean logic
    | IAnd         !VarId !VarId !VarId   -- ^ @dst = lhs && rhs@
    | IOr          !VarId !VarId !VarId   -- ^ @dst = lhs || rhs@
    | INot         !VarId !VarId          -- ^ @dst = !src@

    -- ** String operations
    | IConcat      !VarId !VarId !VarId   -- ^ @dst = lhs ++ rhs@ (string)

    -- ** Nominal type operations
    | IConstruct   !VarId !TypeId ![VarId]
      -- ^ @dst = TypeId(fields...)@ — construct a nominal value.
    | IGetField    !VarId !VarId !Word16
      -- ^ @dst = src.fieldIndex@ — access field by position.
    | IGetTag      !VarId !VarId
      -- ^ @dst = tag(src)@ — extract the TypeId tag.

    -- ** Array operations
    | INewArray    !VarId ![VarId]
      -- ^ @dst = [elems...]@
    | IArrGet      !VarId !VarId !VarId
      -- ^ @dst = arr[index]@
    | IArrLen      !VarId !VarId
      -- ^ @dst = length(arr)@
    | IArrPush     !VarId !VarId !VarId
      -- ^ @dst = push(arr, elem)@ — produces a new array.
    | IArrConcat   !VarId !VarId !VarId
      -- ^ @dst = arr1 ++ arr2@

    -- ** Tuple operations
    | INewTuple    !VarId ![VarId]
      -- ^ @dst = (elems...)@
    | ITupGet      !VarId !VarId !Word16
      -- ^ @dst = tuple.index@

    -- ** Closure operations
    | IMakeClosure !VarId !FuncId ![VarId]
      -- ^ @dst = closure(funcId, captures...)@

    -- ** Conversion
    | IIntToFlt    !VarId !VarId    -- ^ @dst = intToFloat(src)@
    | IFltToInt    !VarId !VarId    -- ^ @dst = floatToInt(src)@ (truncate)

    deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Terminators

-- | A terminator ends a basic block and transfers control.
data Terminator
    = -- ** Standard control flow
      TReturn     !VarId
      -- ^ Return a value from the current function.
    | TJump       !BlockId
      -- ^ Unconditional jump to a block.
    | TBranch     !VarId !BlockId !BlockId
      -- ^ @if cond then trueBlock else falseBlock@.
    | TSwitch     !VarId ![(SwitchCase, BlockId)] !BlockId
      -- ^ Switch on a value. Cases + default block.

    -- ** Function calls
    -- Each call terminates its block, making it an async/persistence point.
    | TCall       !VarId !VarId ![VarId] !BlockId
      -- ^ @dst = func(args...)@, continue at contBlock.
    | TCallDirect !VarId !FuncId ![VarId] !BlockId
      -- ^ @dst = funcId(args...)@, continue at contBlock (no closure indirection).
    | TTailCall   !VarId ![VarId]
      -- ^ Tail call: @func(args...)@.
    | TTailCallDirect !FuncId ![VarId]
      -- ^ Direct tail call.

    -- ** Algebraic effects
    | TPerform    !VarId !EffectId ![VarId] !BlockId
      -- ^ @dst = perform effectId(args...)@, continue at contBlock.
      -- Suspends until a handler resumes with a value.
    | THandle     !HandleInfo
      -- ^ Set up a handler and call the body closure.
    | TContinue   !VarId !VarId !VarId !BlockId
      -- ^ @continue(contVar, valueVar) -> resultVar, contBlock@
      -- Multi-shot: resume body with valueVar, body's result goes to resultVar,
      -- then continue at contBlock. contVar is NOT consumed (reusable).
    | THandleRet  !VarId
      -- ^ Produce the handle expression's result (abort the body).

    -- ** Unreachable
    | TUnreachable
      -- ^ Should never be reached (after exhaustive match, etc.).

    deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Switch cases

-- | A case in a 'TSwitch' terminator.
data SwitchCase
    = CaseTag  !TypeId     -- ^ Match on a nominal type tag.
    | CaseInt  !Integer    -- ^ Match on an integer literal.
    | CaseStr  !Text       -- ^ Match on a string literal.
    | CaseBool !Bool       -- ^ Match on a boolean value.
    deriving (Eq, Show, Generic)

-- ---------------------------------------------------------------------------
-- Handle-related types

-- | Information for a @handle@ expression.
--
-- Execution flow:
--
-- 1. Runtime pushes handler frame, calls body closure (@hBody@).
-- 2. If body performs a handled effect → capture continuation, jump to handler.
-- 3. Handler can 'TContinue' (resume body) or 'THandleRet' (short-circuit).
-- 4. If body returns normally → optional return handler, then @hContBlock@.
data HandleInfo = HandleInfo
    { hBody      :: !VarId
      -- ^ Body closure (zero-argument). Compiled as a separate function
      -- with captured variables via 'IMakeClosure'.
    , hHandlers  :: ![(EffectId, HandlerDef)]
      -- ^ One handler per effect being handled.
    , hReturnDef :: !(Maybe ReturnDef)
      -- ^ Optional return handler (transforms the body's return value).
      -- If absent, the body's return value becomes the handle result directly.
    , hResultVar :: !VarId
      -- ^ Variable to store the final result of the handle expression.
    , hContBlock :: !BlockId
      -- ^ Block to continue at after the handle expression completes.
    }
    deriving (Eq, Show, Generic)

-- | Definition of a single effect handler case.
data HandlerDef = HandlerDef
    { hdBlock :: !BlockId
      -- ^ Block that implements this handler.
    , hdArgs  :: ![VarId]
      -- ^ Variables pre-assigned for the effect's arguments
      -- (filled by the runtime when the effect is performed).
    , hdCont  :: !VarId
      -- ^ Variable pre-assigned for the captured continuation object.
    }
    deriving (Eq, Show, Generic)

-- | Definition of the return handler clause.
data ReturnDef = ReturnDef
    { rdBlock :: !BlockId
      -- ^ Block that implements the return handler.
    , rdArg   :: !VarId
      -- ^ Variable pre-assigned for the body's return value.
    }
    deriving (Eq, Show, Generic)
