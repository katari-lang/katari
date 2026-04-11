# Qatali IR Specification v2

This document is the authoritative specification for the Qatali IR bytecode format.
It is intended as the contract between `qatali-compiler` (Haskell) and `qatali-runtime` (Rust).

---

## 1. Design Goals

| Goal                         | How the IR achieves it                                                                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Persistence**              | Every call/perform terminates a block. The runtime can snapshot `(FuncId, BlockId, vars, handler_stack)` to PostgreSQL at any block boundary.          |
| **Hot-swap**                 | `NameTable.ntFuncs` maps `FuncId -> QualifiedName`. The runtime resolves names to IDs at apply-time, allowing function replacement without restarting. |
| **Server-to-server effects** | `TPerform` + `THandle` encode algebraic effects. A runtime can forward `TPerform` across the network to a remote handler.                              |
| **Compact binary**           | All identifiers are small integers. Explicit opcode tags for instructions and terminators ensure forward/backward binary compatibility.                |

---

## 2. Identifier Types

All identifiers are **unsigned integers**.

| Type       | Rust type | Width   | Scope              | Description                                                       |
| ---------- | --------- | ------- | ------------------ | ----------------------------------------------------------------- |
| `VarId`    | `u32`     | 4 bytes | **function-local** | Variable register. Starts from 0 in each function.                |
| `BlockId`  | `u16`     | 2 bytes | **function-local** | Basic block index within a function. Block 0 is always the entry. |
| `FuncId`   | `u32`     | 4 bytes | **program-global** | Function identifier.                                              |
| `TypeId`   | `u32`     | 4 bytes | **program-global** | Nominal type tag (for `data` declarations).                       |
| `EffectId` | `u32`     | 4 bytes | **program-global** | Effect identifier (for `effect` declarations).                    |
| `ConstId`  | `u32`     | 4 bytes | **module-local**   | Index into the module's constant pool (0-based).                  |

**VarId scoping**: Each function has its own VarId space starting from 0. The runtime allocates a `Vec<Value>` per frame sized to the function's maximum VarId. This avoids global ID space waste and enables compact serialization.

---

## 3. Program Structure

```
Program
  modules: [Module]

Module
  name:          ModuleName          -- e.g. ["MyApp", "Core"]
  name_table:    NameTable
  nominal_types: [NominalTypeDef]
  effects:       [IREffectDef]
  constants:     [Constant]          -- indexed by ConstId (0-based)
  functions:     [Function]
```

### 3.1 ModuleName

A non-empty list of UTF-8 strings. Example: `["MyApp", "Core"]` represents `MyApp.Core`.

Binary encoding: length-prefixed list of length-prefixed UTF-8 strings.

### 3.2 NameTable

Maps numeric IDs back to human-readable names. **Optional for execution** but required for persistence, hot-swap, and debugging.

```
NameTable
  vars:    Map<VarId, Name>             -- variable names
  funcs:   Map<FuncId, QualifiedName>   -- function qualified names (hot-swap key)
  types:   Map<TypeId, String>          -- type names
  effects: Map<EffectId, String>        -- effect names
```

- `Name`: a single UTF-8 string (e.g. `"x"`, `"myFunc"`)
- `QualifiedName`: `{ module: Option<ModuleName>, name: Name }`

### 3.3 NominalTypeDef

```
NominalTypeDef
  id:          TypeId
  field_count: u16
  field_names: [String]     -- length == field_count; for debugging only
```

### 3.4 IREffectDef

```
IREffectDef
  id:        EffectId
  arg_count: u16
```

### 3.5 Constant

Tagged union:

| Tag       | Payload                         | Description     |
| --------- | ------------------------------- | --------------- |
| `CInt`    | `Integer` (arbitrary precision) | Integer literal |
| `CFloat`  | `f64`                           | Float literal   |
| `CString` | `String` (UTF-8)                | String literal  |
| `CBool`   | `bool`                          | Boolean literal |
| `CNull`   | (none)                          | Null literal    |

Note: `Integer` is Haskell's arbitrary-precision integer. In Binary encoding this is a variable-length encoding. The Rust runtime should use a big-integer library or decide on a maximum precision.

### 3.6 Function

```
Function
  id:          FuncId
  param_count: u16
  params:      [VarId]      -- length == param_count
  blocks:      [Block]       -- blocks[0] is the entry block
```

**Top-level let bindings**: Each top-level `let` declaration is compiled as a **named zero-argument function**. For example, `let pi = 3.14` becomes a function `pi()` that returns `3.14`. These functions are registered in the `NameTable` with their qualified names, and can be invoked via `qatali run <name>`.

**Closures**: When a function is used as a closure, the compiler emits `IMakeClosure dst func_id [capture_vars]`. The captures are prepended to the parameter list at the call site. So if a function has `param_count = 5` and was created with `IMakeClosure _ _ [a, b]`, the first 2 params are captures and the remaining 3 are user-visible arguments.

### 3.7 Block

```
Block
  id:         BlockId
  instrs:     [Instr]        -- zero or more instructions (no control flow)
  terminator: Terminator     -- exactly one (control flow)
```

---

## 4. Values (Runtime Representation)

The IR is **untyped at runtime**. The runtime must represent values as a tagged union:

```rust
enum Value {
    Null,
    Int(i64),           // or BigInt for arbitrary precision
    Float(f64),
    Bool(bool),
    String(RcStr),      // immutable, reference-counted
    Array(RcArray),     // immutable, reference-counted
    Nominal {           // data type instance
        tag: TypeId,
        fields: Vec<Value>,
    },
    Closure {
        func_id: FuncId,
        captures: Vec<Value>,
    },
    Continuation(ContId), // opaque handle to a captured continuation
}
```

---

## 5. Instructions

Instructions perform computation **without altering control flow**. The first `VarId` argument is always the **destination** (result register).

### 5.1 Constants and Moves

| Opcode       | Operands                   | Semantics                    |
| ------------ | -------------------------- | ---------------------------- |
| `ILoadConst` | `dst: VarId, cid: ConstId` | `dst = constants[cid]`       |
| `ILoadNull`  | `dst: VarId`               | `dst = null`                 |
| `IMove`      | `dst: VarId, src: VarId`   | `dst = src` (copy reference) |

### 5.2 Integer Arithmetic

| Opcode    | Operands        | Semantics                            |
| --------- | --------------- | ------------------------------------ |
| `IAddInt` | `dst, lhs, rhs` | `dst = lhs + rhs` (integer)          |
| `ISubInt` | `dst, lhs, rhs` | `dst = lhs - rhs`                    |
| `IMulInt` | `dst, lhs, rhs` | `dst = lhs * rhs`                    |
| `IDivInt` | `dst, lhs, rhs` | `dst = lhs / rhs` (integer division) |
| `IModInt` | `dst, lhs, rhs` | `dst = lhs % rhs`                    |
| `INegInt` | `dst, src`      | `dst = -src`                         |

### 5.3 Float Arithmetic

| Opcode    | Operands        | Semantics               |
| --------- | --------------- | ----------------------- |
| `IAddFlt` | `dst, lhs, rhs` | `dst = lhs + rhs` (f64) |
| `ISubFlt` | `dst, lhs, rhs` | `dst = lhs - rhs`       |
| `IMulFlt` | `dst, lhs, rhs` | `dst = lhs * rhs`       |
| `IDivFlt` | `dst, lhs, rhs` | `dst = lhs / rhs`       |
| `INegFlt` | `dst, src`      | `dst = -src`            |

### 5.4 Comparison

All comparisons produce a `Bool` value. They are polymorphic (work on any value with a defined ordering).

| Opcode   | Operands        | Semantics            |
| -------- | --------------- | -------------------- |
| `ICmpEq` | `dst, lhs, rhs` | `dst = (lhs == rhs)` |
| `ICmpNe` | `dst, lhs, rhs` | `dst = (lhs != rhs)` |
| `ICmpLt` | `dst, lhs, rhs` | `dst = (lhs < rhs)`  |
| `ICmpLe` | `dst, lhs, rhs` | `dst = (lhs <= rhs)` |
| `ICmpGt` | `dst, lhs, rhs` | `dst = (lhs > rhs)`  |
| `ICmpGe` | `dst, lhs, rhs` | `dst = (lhs >= rhs)` |

### 5.5 Boolean Logic

| Opcode | Operands        | Semantics            |
| ------ | --------------- | -------------------- |
| `IAnd` | `dst, lhs, rhs` | `dst = lhs && rhs`   |
| `IOr`  | `dst, lhs, rhs` | `dst = lhs \|\| rhs` |
| `INot` | `dst, src`      | `dst = !src`         |

**Note**: Source-level `&&` and `||` operators compile to **short-circuit control flow** (using `TBranch`), not `IAnd`/`IOr` instructions. These instructions perform eager boolean logic on pre-evaluated operands and are retained for potential use in optimized code paths.

### 5.6 String Operations

| Opcode    | Operands        | Semantics                                 |
| --------- | --------------- | ----------------------------------------- |
| `IConcat` | `dst, lhs, rhs` | `dst = lhs ++ rhs` (string concatenation) |

### 5.7 Nominal Type Operations

| Opcode       | Operands                                   | Semantics                                                |
| ------------ | ------------------------------------------ | -------------------------------------------------------- |
| `IConstruct` | `dst: VarId, tag: TypeId, fields: [VarId]` | `dst = Nominal { tag, fields }`                          |
| `IGetField`  | `dst: VarId, src: VarId, idx: u16`         | `dst = src.fields[idx]`                                  |
| `IGetTag`    | `dst: VarId, src: VarId`                   | `dst = src.tag` (as a TypeId, used with TSwitch/CaseTag) |

### 5.8 Array Operations

Arrays are **immutable**. Mutation operations produce new arrays.

| Opcode       | Operands                                         | Semantics                                            |
| ------------ | ------------------------------------------------ | ---------------------------------------------------- |
| `INewArray`  | `dst: VarId, elems: [VarId]`                     | `dst = [elems...]`                                   |
| `IArrGet`    | `dst: VarId, arr: VarId, idx: VarId`             | `dst = arr[idx]` (idx is an Int value)               |
| `IArrLen`    | `dst: VarId, arr: VarId`                         | `dst = length(arr)` (Int)                            |
| `IArrPush`   | `dst: VarId, arr: VarId, elem: VarId`            | `dst = arr ++ [elem]` (new array)                    |
| `IArrConcat` | `dst: VarId, arr1: VarId, arr2: VarId`           | `dst = arr1 ++ arr2` (new array)                     |
| `IArrSlice`  | `dst: VarId, arr: VarId, from: VarId, to: VarId` | `dst = arr[from..to]` (from inclusive, to exclusive) |

### 5.9 Closure Operations

| Opcode         | Operands                                         | Semantics                             |
| -------------- | ------------------------------------------------ | ------------------------------------- |
| `IMakeClosure` | `dst: VarId, func_id: FuncId, captures: [VarId]` | `dst = Closure { func_id, captures }` |

When calling a closure, the runtime prepends the captured values to the argument list before invoking the function.

### 5.10 Conversion

| Opcode      | Operands                 | Semantics                     |
| ----------- | ------------------------ | ----------------------------- |
| `IIntToFlt` | `dst: VarId, src: VarId` | `dst = src as f64`            |
| `IFltToInt` | `dst: VarId, src: VarId` | `dst = src as i64` (truncate) |

---

## 6. Terminators

Terminators end a basic block and transfer control. **Every block has exactly one terminator.**

### 6.1 Standard Control Flow

| Terminator | Operands                                                         | Semantics                               |
| ---------- | ---------------------------------------------------------------- | --------------------------------------- |
| `TReturn`  | `val: VarId`                                                     | Return `val` from the current function. |
| `TJump`    | `target: BlockId`                                                | Unconditional jump.                     |
| `TBranch`  | `cond: VarId, true_blk: BlockId, false_blk: BlockId`             | Branch on boolean.                      |
| `TSwitch`  | `scrut: VarId, cases: [(SwitchCase, BlockId)], default: BlockId` | Multi-way branch.                       |

**SwitchCase** variants:

| Case       | Payload   | Match condition        |
| ---------- | --------- | ---------------------- |
| `CaseTag`  | `TypeId`  | `scrut.tag == type_id` |
| `CaseInt`  | `Integer` | `scrut == int_val`     |
| `CaseStr`  | `String`  | `scrut == str_val`     |
| `CaseBool` | `bool`    | `scrut == bool_val`    |

### 6.2 Function Calls

**Every call terminates a block.** This is the key design decision enabling persistence: the runtime can snapshot state after any call instruction.

| Terminator        | Operands                                                    | Semantics                                                            |
| ----------------- | ----------------------------------------------------------- | -------------------------------------------------------------------- |
| `TCall`           | `dst: VarId, func: VarId, args: [VarId], cont: BlockId`     | Indirect call through closure. Result -> `dst`, then jump to `cont`. |
| `TCallDirect`     | `dst: VarId, func_id: FuncId, args: [VarId], cont: BlockId` | Direct call (no closure indirection).                                |
| `TTailCall`       | `func: VarId, args: [VarId]`                                | Tail call (reuse current frame).                                     |
| `TTailCallDirect` | `func_id: FuncId, args: [VarId]`                            | Direct tail call.                                                    |

**Call execution**:

1. Runtime saves current frame state (all var registers).
2. Push new frame for callee.
3. Execute callee until `TReturn val`.
4. Pop callee frame, write `val` to `dst` in caller frame.
5. Resume caller at `cont` block.

**Persistence point**: Between steps 1 and 2 (or after step 4), the runtime may serialize the entire call stack to PostgreSQL. On restart, it deserializes and resumes from `cont`.

### 6.3 Algebraic Effects

#### 6.3.1 TPerform

```
TPerform dst: VarId, effect_id: EffectId, args: [VarId], cont: BlockId
```

Perform an effect. This is the "throw" side of algebraic effects.

**Execution**:

1. Walk the handler stack upward looking for a handler for `effect_id`.
2. If found:
   a. Capture the current continuation (everything from the perform site up to, but not including, the handler frame). This continuation is a first-class value that can be resumed multiple times (multi-shot).
   b. Call the handler closure with `[effect_args..., continuation]` as arguments.
   c. The handler closure produces the handle result via `TReturn`.
3. If not found: runtime error (unhandled effect).

**Persistence point**: The captured continuation includes enough state to resume. If serialized, it must include the full call stack segment.

#### 6.3.2 THandle

```
THandle HandleInfo {
    body:        VarId,                  -- body closure (0 user args)
    handlers:    [(EffectId, VarId)],     -- handler closures
    return_handler: Option<VarId>,       -- optional return handler closure
    result_var:  VarId,
    cont_block:  BlockId,
}
```

All handler cases and the optional return handler are compiled as **separate closures** (each gets its own `Function`). This ensures that each handler invocation receives its own stack frame, which is essential for correct multi-shot continuation semantics -- without this, reentrant handler invocations would overwrite each other's variables.

**Handler closure parameters**: `[captures..., effect_arg_1, ..., effect_arg_N, continuation]`

The continuation is passed as a regular parameter named `$cont` internally. The handler closure can use `TContinue` with this parameter to resume the body.

**Return handler closure parameters**: `[captures..., body_return_value]`

Transforms the body's return value; its `TReturn` value is the effective body result.

**Execution**:

1. Push a new handler frame onto the handler stack. The frame records which effects are handled and which closures to call.
2. Call the `body` closure (invoke the closure value; it has 0 user arguments but may have captures).
3. **If the body returns normally** (via `TReturn`):
   - If `return_handler` is `Some(closure)`:
     - Call the return handler closure with `[body_return_value]`.
     - Its `TReturn` value is the effective result.
   - If `return_handler` is `None`:
     - The body's return value becomes the handle result directly.
   - If inside a `TContinue`: effective result goes to `TContinue`'s result_var.
   - Otherwise: effective result goes to `result_var`, pop handler frame, jump to `cont_block`.
4. **If the body performs a handled effect** (see `TPerform` above):
   - The handler closure is called with effect args and continuation.
   - The handler closure can:
     - Use `TContinue` to resume the body (multi-shot).
     - Use `TReturn` to produce the handle result.
   - Handler's `TReturn` value goes to `result_var`, pop handler, jump to `cont_block`.

#### 6.3.3 TContinue (Multi-shot)

```
TContinue cont_var: VarId, value_var: VarId, result_var: VarId, cont_block: BlockId
```

Resume a captured continuation. **The continuation is not consumed** (can be called multiple times).

**Execution**:

1. Clone the continuation (since it's multi-shot).
2. Resume the body by feeding `value_var` as the return value of the `TPerform` that originally suspended (i.e., write it to the perform's `dst` var).
3. The body continues executing from the perform's `cont` block.
4. When the body eventually returns or the handle completes for this resumption:
   - The result is written to `result_var`.
   - Execution continues at `cont_block`.

This makes `continue` behave like a function call: it "calls" the body, gets back a result, and continues.

**Example** (Qatali source):

```
handle choose_body() {
  case Choose(value) => {
    let left = continue(false)     // resume body, get result
    let right = continue(true)     // resume again (multi-shot!)
    left + right
  }
}
```

### 6.4 Unreachable

```
TUnreachable
```

Should never be reached. If executed, the runtime should panic/abort. Used after exhaustive pattern matches.

---

## 7. Binary Format

### 7.1 File Header

| Offset | Size    | Content                                   |
| ------ | ------- | ----------------------------------------- |
| 0      | 4 bytes | Magic: `0x51 0x41 0x54 0x41` ("QATA")     |
| 4      | 4 bytes | Version: `u32` big-endian (currently `2`) |
| 8      | ...     | `Program` payload (Data.Binary encoding)  |

### 7.2 Data.Binary Encoding

The payload uses Haskell's `Data.Binary`. The encoding rules are:

- **Integers**: Variable-length encoding (see `Data.Binary` docs for `Integer`).
- **Word16/Word32**: Big-endian fixed-width.
- **Bool**: 1 byte (0 = False, 1 = True).
- **Text**: Length-prefixed UTF-8 (`u64` length prefix in bytes, then UTF-8 bytes).
- **Lists**: `u64` length prefix, then elements sequentially.
- **Maybe**: Tag byte (0 = Nothing, 1 = Just), then value if Just.
- **Product types** (records): Fields sequentially in declaration order.
- **Maps**: Encoded as `[(key, value)]` lists.

### 7.3 Instruction Opcodes

`Instr` and `Terminator` use **explicit opcode tags** (1-byte, 1-based) for forward/backward compatibility. New instructions are appended with new opcode numbers; old numbers are never reused or reordered.

**Instr opcodes**:

```
0x01: ILoadConst    dst cid
0x02: ILoadNull     dst
0x03: IMove         dst src
0x04: IAddInt       dst lhs rhs
0x05: ISubInt       dst lhs rhs
0x06: IMulInt       dst lhs rhs
0x07: IDivInt       dst lhs rhs
0x08: IModInt       dst lhs rhs
0x09: INegInt       dst src
0x0A: IAddFlt       dst lhs rhs
0x0B: ISubFlt       dst lhs rhs
0x0C: IMulFlt       dst lhs rhs
0x0D: IDivFlt       dst lhs rhs
0x0E: INegFlt       dst src
0x0F: ICmpEq        dst lhs rhs
0x10: ICmpNe        dst lhs rhs
0x11: ICmpLt        dst lhs rhs
0x12: ICmpLe        dst lhs rhs
0x13: ICmpGt        dst lhs rhs
0x14: ICmpGe        dst lhs rhs
0x15: IAnd          dst lhs rhs
0x16: IOr           dst lhs rhs
0x17: INot          dst src
0x18: IConcat       dst lhs rhs
0x19: IConstruct    dst tid fields
0x1A: IGetField     dst src idx
0x1B: IGetTag       dst src
0x1C: INewArray     dst elems
0x1D: IArrGet       dst arr idx
0x1E: IArrLen       dst arr
0x1F: IArrPush      dst arr elem
0x20: IArrConcat    dst arr1 arr2
0x21: IArrSlice     dst arr from to
0x22: IMakeClosure  dst fid captures
0x23: IIntToFlt     dst src
0x24: IFltToInt     dst src
```

**Terminator opcodes**:

```
0x01: TReturn          val
0x02: TJump            target
0x03: TBranch          cond true_blk false_blk
0x04: TSwitch          scrut cases default_blk
0x05: TCall            dst func args cont
0x06: TCallDirect      dst fid args cont
0x07: TTailCall         func args
0x08: TTailCallDirect   fid args
0x09: TPerform         dst eid args cont
0x0A: THandle          handle_info
0x0B: TContinue        cont_var value_var result_var cont_block
0x0C: TUnreachable
```

**SwitchCase** (Generic-derived, 0-based tag):

```
0: CaseTag   tid
1: CaseInt   integer
2: CaseStr   string
3: CaseBool  bool
```

**Constant** (Generic-derived, 0-based tag):

```
0: CInt    integer
1: CFloat  f64
2: CString string
3: CBool   bool
4: CNull
```

---

## 8. Runtime Architecture

### 8.1 Execution Model

```
                    qatali apply
                        |
                        v
 .qtl source --> [qatali-compiler] --> IR binary --> [qatali-runtime]
                                                          |
                                                   qatali run <func>
                                                          |
                                                          v
                                                   Execute function
                                                          |
                                              +-----+----+-----+
                                              |     |          |
                                           TCall TPerform  TReturn
                                              |     |          |
                                          [persist] [handler]  [done]
```

### 8.2 Runtime State

```rust
struct Runtime {
    /// All loaded modules (applied via `qatali apply`)
    modules: HashMap<ModuleName, LoadedModule>,

    /// Global function registry: QualifiedName -> FuncId -> Function
    /// Used for hot-swap: re-applying updates this mapping
    func_registry: HashMap<QualifiedName, (FuncId, Arc<Function>)>,

    /// Type registry
    type_registry: HashMap<TypeId, NominalTypeDef>,

    /// Effect registry
    effect_registry: HashMap<EffectId, IREffectDef>,

    /// Database connection for persistence
    db: PgPool,
}

struct LoadedModule {
    name_table: NameTable,
    constants: Vec<Constant>,
    functions: Vec<Function>,
}
```

### 8.3 Execution Frame

```rust
struct Frame {
    func_id: FuncId,
    block_id: BlockId,
    ip: usize,            // instruction pointer within block
    vars: Vec<Value>,      // indexed by VarId (function-local, dense)
}

struct ExecutionState {
    call_stack: Vec<Frame>,
    handler_stack: Vec<HandlerFrame>,
}

struct HandlerFrame {
    /// Which effects this handler covers, mapped to handler closures
    handlers: HashMap<EffectId, Value>,  // Value::Closure
    /// Return handler closure (optional)
    return_handler: Option<Value>,       // Value::Closure
    /// Where to write the handle result
    result_var: VarId,
    /// Where to continue after handle completes
    cont_block: BlockId,
    /// The call stack depth when this handler was pushed
    /// (used to delimit continuation capture)
    stack_depth: usize,
}
```

### 8.4 Continuation Representation

A continuation captures everything needed to resume execution from a `TPerform` site:

```rust
struct Continuation {
    /// The call stack frames from the perform site up to (not including) the handler
    frames: Vec<Frame>,
    /// The handler stack frames that were between perform and handler
    inner_handlers: Vec<HandlerFrame>,
    /// Where to write the resume value (the perform's dst var in the innermost frame)
    resume_dst: VarId,
    /// Which block to resume at (the perform's cont block)
    resume_block: BlockId,
}
```

For **multi-shot** semantics, continuations must be **cloneable**. Each `TContinue` clones the continuation before resuming.

### 8.5 Persistence (PostgreSQL)

At every block boundary (after any terminator that has a `cont` block), the runtime **may** persist:

```sql
CREATE TABLE execution_states (
    id UUID PRIMARY KEY,
    func_name TEXT NOT NULL,        -- from NameTable
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    state JSONB NOT NULL            -- serialized ExecutionState
);
```

The `state` JSONB includes:

- `call_stack`: array of frames, each with `func_id`, `block_id`, and `vars` (array indexed by VarId, using NameTable for human-readable keys where available)
- `handler_stack`: array of handler frames
- `continuation_pool`: any live continuations

On restart, the runtime deserializes and resumes from the exact block boundary.

### 8.6 Hot-Swap (`qatali apply`)

1. Compiler produces new IR binary.
2. Runtime decodes and loads the new module.
3. For each function in the new module, the runtime checks `NameTable.ntFuncs` for the `QualifiedName`.
4. If a function with the same `QualifiedName` already exists, it is **replaced** in the registry.
5. Currently running executions continue with the old code (they hold references). New calls use the new code.

### 8.7 `qatali run <qualified_name>`

1. Look up `QualifiedName` in `func_registry`.
2. Create a new `ExecutionState` with an initial frame.
3. Execute until `TReturn` at the top-level frame.
4. Return the result value.

---

## 9. Effect System Execution Flow

### 9.1 Simple Example

```
// Source:
effect Ask(prompt: string) => string

fn main(): string => {
    handle {
        let answer = Ask("name?")
        "Hello, " ++ answer
    } {
        case Ask(prompt) => continue("World")
        return val => val ++ "!"
    }
}
```

**IR (simplified)**:

```
// body closure (func @1)
func @1() {
  block0:
    %0 = load_const c0        // "name?"
    perform %1 = eff0(%0) -> block1
  block1:
    %2 = load_const c1        // "Hello, "
    %3 = concat %2 %1
    return %3
}

// handler closure (func @2) — handles Ask
// params: [prompt_var, cont_var]
func @2(%0, %1) {
  block0:
    %2 = load_const c2        // "World"
    continue %3 = %1 %2 -> block1
  block1:
    return %3
}

// return handler closure (func @3)
// params: [body_return_value]
func @3(%0) {
  block0:
    %1 = load_const c3        // "!"
    %2 = concat %0 %1
    return %2
}

// main (func @0)
func @0() {
  block0:
    %0 = closure @1 []         // body closure
    %1 = closure @2 []         // handler closure
    %2 = closure @3 []         // return handler closure
    handle {
      body: %0
      on eff0 -> %1
      return: %2
      result: %3 -> block1
    }
  block1:
    return %3
}
```

**Execution trace**:

1. Enter `@0`, block0: create closures, execute `THandle`.
2. Push handler frame (with handler closure for eff0 and return handler closure), call body `@1`.
3. Body block0: load "name?", `TPerform eff0`.
4. Runtime finds handler for eff0 in handler frame.
5. Capture continuation = { body frame at block1 waiting for %1 }.
6. Call handler closure `@2` with args `["name?", continuation]`.
7. Handler func @2: load "World", `TContinue %1 %2 -> %3, block1`.
8. Clone continuation, resume body: write "World" to body's %1, jump to body block1.
9. Body block1: concat "Hello, " ++ "World" = "Hello, World". `TReturn "Hello, World"`.
10. Body returned normally. Return handler exists: call `@3` with `["Hello, World"]`.
11. Return handler @3: concat "Hello, World" ++ "!" = "Hello, World!". `TReturn "Hello, World!"`.
12. Effective result = "Hello, World!". This is the TContinue result -> write to @2's %3.
13. Handler @2 block1: `TReturn %3` = "Hello, World!".
14. Handler returned. Write "Hello, World!" to main's %3, pop handler, jump to block1.
15. Block1: `TReturn %3`. Done. Result = "Hello, World!".

### 9.2 Multi-shot Example

```
effect Choose() => boolean

fn all_paths(): integer => {
    handle {
        let a = if Choose() { 1 } else { 10 }
        let b = if Choose() { 100 } else { 1000 }
        a + b
    } {
        case Choose() => {
            let left = continue(true)
            let right = continue(false)
            left + right
        }
    }
}
// Result: (1+100) + (1+1000) + (10+100) + (10+1000) = 2222
```

Each `continue` calls the handler closure with its own frame, so multiple invocations of the same handler don't overwrite each other's variables. The continuation is cloned and the body runs to completion each time.

---

## 10. Appendix: Complete IR Text Format

The pretty printer output format (for debugging):

```
module ModuleName {
  type t<id>(<name>) (<n> fields: <field1>, <field2>, ...)
  effect eff<id>(<name>) (<n> args)

  constants {
    c<id>: <value>
  }

  func @<id>(<name>) (%<param1>, %<param2>, ...) {
    block<id>:
      %<dst> = <instruction>
      <terminator>
  }
}
```

Variable format: `%<id>` or `%<id>(<name>)` when the name table has an entry.
Function format: `@<id>` or `@<id>(<name>)`.
Type format: `t<id>` or `t<id>(<name>)`.
Effect format: `eff<id>` or `eff<id>(<name>)`.
Constant format: `c<id>`.

---

## 11. Changelog

### v2 (current)

- **VarId scope**: Changed from module-global to **function-local**. Each function's VarId space starts from 0. Runtime uses `Vec<Value>` per frame instead of sparse `HashMap<VarId, Value>`.
- **Handler closures**: Handler cases and return handlers are now compiled as **separate closures** (separate `Function` entries) instead of blocks within the parent function. This fixes multi-shot continuation correctness where reentrant handler invocations would overwrite shared variables.
- **`THandleRet` removed**: Handler closures use standard `TReturn` to produce results. The runtime routes the return value based on context (handler frame vs TContinue).
- **`HandleInfo` simplified**: Replaced `HandlerDef { block, args, cont }` and `ReturnDef { block, arg }` with closure VarIds: `handlers: [(EffectId, VarId)]` and `return_handler: Option<VarId>`.
- **`IArrSlice` added**: New instruction for array slicing, used in spread pattern compilation.
- **Short-circuit `&&`/`||`**: Source-level `&&` and `||` now compile to `TBranch`-based control flow instead of eager `IAnd`/`IOr`.
- **Explicit opcode tags**: `Instr` and `Terminator` use explicit 1-byte opcode tags (1-based) instead of Generic-derived constructor indices. This ensures binary compatibility when new instructions are added.
- **Array pattern compilation**: Spread patterns (`[a, ...rest, b]`) now correctly compile `spAfter` and `spSpread` elements.
- **Pattern match verification**: The last match arm now verifies the pattern defensively (jumps to `TUnreachable` on failure).
- **Unified pattern compilation**: `compilePat` and `bindPat` merged into `compileAndBindPat` to avoid duplicate `IGetField` emissions.
- **Top-level `LetPat` error**: Top-level pattern destructuring now produces a compile error instead of being silently ignored.
