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
    | IArrSlice   !VarId !VarId !VarId !VarId
      -- ^ @dst = arr[from..to]@ — slice from index (inclusive) to index (exclusive).

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
    | TContinue   !VarId !VarId ![VarId] !VarId !BlockId
      -- ^ @continue(contVar, valueVar, hvUpdates) -> resultVar, contBlock@
      -- One-shot: resume body with valueVar, body's result goes to resultVar,
      -- then continue at contBlock. contVar IS consumed (not reusable).
      -- hvUpdates are updated handler variable values (same order as hVarInits).

    -- ** FFI
    | TFfiCall    !VarId !Text !Text ![VarId] !BlockId
      -- ^ @dst = ffi_call(moduleName, fnName, args...)@, continue at contBlock.
      -- Calls a foreign (JavaScript) function by module/name.

    -- ** Parallel execution
    | TParAll     !VarId ![VarId] !BlockId
      -- ^ @dst = parallel_all(task_closures...)@, continue at contBlock.
      -- Executes task closures in parallel, collects results into an array.

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
-- All handler cases and the optional return handler are compiled as
-- **separate closures** (each gets its own 'Function'). This ensures
-- that each handler invocation receives its own stack frame.
--
-- One-shot semantics: each continuation can be used at most once
-- (via 'TContinue' or discarded via 'TReturn' / break).
--
-- Execution flow:
--
-- 1. Runtime pushes handler frame with initial handler var values (@hVarInits@),
--    then calls body closure (@hBody@).
-- 2. If body performs a handled effect:
--    a. Capture continuation (one-shot).
--    b. Call the handler closure with
--       @[captures..., effect_args..., continuation, hvar_current_values...]@.
--    c. Handler may 'TContinue' (resume body with updated hvar values)
--       or 'TReturn' (produce result / break).
--    d. Handler's 'TReturn' value → @hResultVar@, pop handler, jump @hContBlock@.
-- 3. If body returns normally:
--    a. If return handler exists: call it with
--       @[captures..., body_return_value, hvar_current_values...]@.
--       Its 'TReturn' value is the effective result.
--    b. If no return handler: body's return value is the effective result.
--    c. Effective result → @hResultVar@, pop handler, jump @hContBlock@.
data HandleInfo = HandleInfo
    { hBody      :: !VarId
      -- ^ Body closure (zero user-arguments). Compiled as a separate
      -- function with captured variables via 'IMakeClosure'.
    , hHandlers  :: ![(EffectId, VarId)]
      -- ^ One handler closure per effect being handled.
      -- Each closure's parameters are:
      -- @[captures..., effect_arg_1, ..., effect_arg_N, continuation, hvar_1, hvar_2, ...]@.
      -- The closure produces the handle result via 'TReturn' (break)
      -- or resumes via 'TContinue'.
    , hReturn    :: !(Maybe VarId)
      -- ^ Optional return handler closure. Parameters:
      -- @[captures..., body_return_value, hvar_1, hvar_2, ...]@.
      -- Transforms the body's return value; its 'TReturn' value is the
      -- effective body result. If absent, the body's return value is
      -- used directly.
    , hResultVar :: !VarId
      -- ^ Variable to store the final result of the handle expression.
    , hContBlock :: !BlockId
      -- ^ Block to continue at after the handle expression completes.
    , hVarInits  :: ![VarId]
      -- ^ Initial values for handler variables, in declaration order.
      -- These are VarIds in the enclosing function's scope.
    }
    deriving (Eq, Show, Generic)
