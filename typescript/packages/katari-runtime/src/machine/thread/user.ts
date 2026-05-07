import type { Block, BlockId, CallData, IRModule, UserBlock, VarId } from "../../ir/types.js";
import type { ScopeId, ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { tryMatch } from "../pattern.js";
import { RecoverableEngineError } from "../../runtime/errors.js";
import { getScope, getValueFromScope, setValueInScope } from "../scope.js";
import { literalToValue, NULL_VALUE, type Value } from "../value.js";
import {
  ChildThread,
  extendBoundaries,
  resolveBlockPayload,
  type CallId,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockUser (agent or inline).
 * Processes statements sequentially via a program counter.
 *
 * CallId = pc value at the time the call was issued.
 *
 * If the underlying block is `blockKindAgent`, this thread is the boundary
 * for `return`, so we install ourselves into `boundaries.exitKindReturn`
 * during construction.
 */
export class UserThread extends ChildThread {
  readonly block: UserBlock;
  /**
   * IR id of the block backing this thread. Persisted in snapshots in
   * place of the full block payload — `restoreSkeleton` re-resolves the
   * payload from the IR module on load. This dropped per-thread snapshot
   * size from O(IR-block size) to O(1).
   */
  readonly blockId: BlockId;
  /** Index of the next statement to execute. */
  private pc: number = 0;

  constructor(
    machine: MachineState,
    init: ChildThreadInit,
    block: UserBlock,
    blockId: BlockId,
    args: Record<string, Value>,
  ) {
    super(init);
    this.block = block;
    this.blockId = blockId;

    // Bind parameters into the freshly-allocated scope (allocated by the runner).
    //
    // Each `param` has the IR var `param.var` allocated by the compiler's
    // `bindParam` helper. We populate that slot from the incoming `args` here.
    // Any non-trivial destructuring (tuple / constructor patterns, or even a
    // plain `PatternVariable` whose user-facing name differs from `param.var`)
    // is *not* performed here: the compiler always emits a
    // `StatementBindPattern { source = param.var, pattern = ... }` as the
    // body's prelude. UserThread's `runStatements` runs the prelude and
    // expands the pattern into the user-visible local bindings via
    // `tryMatch` from `../pattern.ts`.
    const scope = getScope(machine, init.scopeId);
    for (const param of block.parameters) {
      const argValue = args[param.label];
      if (argValue !== undefined) {
        scope.values.set(param.var, argValue);
      }
    }

    // Agent body installs itself as the `return` boundary.
    if (block.kind === "blockKindAgent") {
      this.boundaries = extendBoundaries(this.boundaries, {
        exitKindReturn: this,
      });
    }
  }

  override onCall(machine: MachineState): void {
    this.runStatements(machine);
  }

  protected override onChildDone(machine: MachineState, callId: CallId, value: Value): void {
    // callId = statement index (pc at call time)
    const stmt = this.block.statements[callId];
    if (stmt === undefined) {
      throw new Error(`UserThread.onChildDone: no statement at callId ${callId}`);
    }
    if (stmt.kind === "statementCall" && stmt.body.output !== undefined) {
      setValueInScope(machine, this.scopeId, stmt.body.output, value);
    }
    this.runStatements(machine);
  }

  /** Process statements from current pc until call or end. */
  private runStatements(machine: MachineState): void {
    const { statements, trailing } = this.block;

    while (this.pc < statements.length) {
      const stmt = statements[this.pc];
      if (stmt === undefined) {
        throw new Error(`UserThread.runStatements: no statement at pc ${this.pc}`);
      }

      switch (stmt.kind) {
        case "statementCall": {
          const callId = this.pc;
          this.pc++;
          const args = resolveArgs(machine, this.scopeId, stmt.body);
          this.pushCallEvent(machine, callId, stmt.body, args);
          return; // wait for child completion
        }

        case "statementLoadLiteral": {
          const { output, value } = stmt.body;
          setValueInScope(machine, this.scopeId, output, literalToValue(value));
          this.pc++;
          continue;
        }

        case "statementMakeClosure": {
          const { output, block } = stmt.body;
          setValueInScope(machine, this.scopeId, output, {
            kind: "closure",
            blockId: block,
            scopeId: this.scopeId,
          });
          this.pc++;
          continue;
        }

        case "statementBindPattern": {
          // Lowering emits a `StatementBindPattern` for every irrefutable
          // bind site: function parameters (after the param's incoming arg
          // is written into `param.var`), `let pat = expr` with structural
          // patterns, `then(p) { ... }` clauses, and for-loop element
          // patterns. The pattern is irrefutable (Maranget exhaustiveness,
          // K0291), so a null result here indicates a compiler bug.
          const { source, pattern } = stmt.body;
          const incoming = getValueFromScope(machine, this.scopeId, source);
          const bindings = tryMatch(pattern, incoming);
          if (bindings === null) {
            throw new Error(
              `statementBindPattern: refutable pattern reached runtime (compiler bug — Maranget K0291 should have rejected this)`,
            );
          }
          for (const [varId, value] of bindings) {
            setValueInScope(machine, this.scopeId, varId, value);
          }
          this.pc++;
          continue;
        }

        case "statementExit": {
          const exitValue = getValueFromScope(machine, this.scopeId, stmt.body.value);
          const exitKind = stmt.body.exitKind;
          // Direct delivery to the registered boundary. The boundary cancels
          // its remaining children and emits done with `exitValue`. Bypasses
          // any intermediate `then` blocks.
          const target = this.boundaries[exitKind];
          if (target === null) {
            throw new Error(
              `statementExit: no boundary registered for ${exitKind}`,
            );
          }
          machine.queue.push({
            kind: "return",
            target,
            value: exitValue,
            exitKind,
          });
          return; // Thread stays alive; will be cancelled by the boundary's cascade.
        }

        case "statementCont": {
          // `next` (handler resume) / `for_next` (loop continuation).
          // Direct delivery to the boundary thread; bypasses any
          // intermediate `then` blocks. Modifiers are pre-evaluated here
          // (Option A) so the boundary doesn't need to read the source's
          // scope to apply them.
          const { contKind, value, modifiers } = stmt.body;
          const target = this.boundaries[contKind];
          if (target === null) {
            throw new Error(
              `statementCont: no boundary registered for ${contKind}`,
            );
          }
          const valueResolved: Value =
            value !== undefined
              ? getValueFromScope(machine, this.scopeId, value)
              : NULL_VALUE;
          const modifiersResolved = new Map<VarId, Value>();
          for (const [targetVar, newValueVar] of modifiers) {
            modifiersResolved.set(
              targetVar,
              getValueFromScope(machine, this.scopeId, newValueVar),
            );
          }
          // `boundaries` is now slot-narrowed: contKindForNext is ForThread,
          // contKindNext is HandleThread, so `target` already has the right
          // union type without an explicit cast.
          machine.queue.push({
            kind: "cont",
            target,
            source: this,
            contKind,
            value: valueResolved,
            modifiers: modifiersResolved,
          });
          return; // Thread stays alive; will be cancelled by the boundary's cascade.
        }
      }
    }

    // All statements executed — return trailing value
    const value = trailing !== undefined
      ? getValueFromScope(machine, this.scopeId, trailing)
      : NULL_VALUE;
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value,
    });
  }

  /**
   * Dispatch a statementCall to the appropriate call queue variant.
   *
   * - `callTargetValue` (closure) → callValue (new scope under captured scope).
   * - `callTargetBlock` to a BlockUser/blockKindAgent → callBlock (new
   *   isolated scope; agent encapsulation).
   * - `callTargetBlock` to a structural block (BlockHandle / BlockFor /
   *   BlockMatch / BlockTuple / BlockArray) → callInline (new scope under
   *   caller's scope so the block can read its `stateInits` / `subject` /
   *   `iters` etc. from the caller's scope).
   * - `callTargetBlock` to a non-user callable (BlockPrim / BlockCtor /
   *   BlockExternal / BlockRequest) → callBlock (these don't read scope;
   *   isolated keeps things tidy). Handlers are still inherited from
   *   parent — both call kinds copy them.
   */
  private pushCallEvent(
    machine: MachineState,
    callId: CallId,
    call: CallData,
    args: Record<string, Value>,
  ): void {
    switch (call.target.kind) {
      case "callTargetBlock": {
        const block = machine.irModule.blocks[call.target.block];
        if (block === undefined) {
          throw new Error(
            `UserThread.pushCallEvent: blockId ${call.target.block} not found in IR`,
          );
        }
        if (isStructuralBlock(block.kind)) {
          machine.queue.push({
            kind: "callInline",
            parent: this,
            callId,
            blockId: call.target.block,
            args,
            scopeId: this.scopeId,
          });
        } else {
          machine.queue.push({
            kind: "callBlock",
            parent: this,
            callId,
            blockId: call.target.block,
            args,
          });
        }
        return;
      }
      case "callTargetValue": {
        const value = getValueFromScope(machine, this.scopeId, call.target.var);
        if (value.kind !== "closure") {
          // Compiler-checked invariant under normal operation; reaching this
          // means an IR-level type mismatch (closure expected, something
          // else encountered). Single-agent issue → Recoverable.
          throw new RecoverableEngineError(
            `UserThread.pushCallEvent: expected closure, got ${value.kind}`,
          );
        }
        machine.queue.push({
          kind: "callValue",
          parent: this,
          callId,
          blockId: value.blockId,
          args,
          capturedScopeId: value.scopeId,
        });
        return;
      }
    }
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedUserThread {
    return {
      kind: "user",
      ...this.serializeChildCommon(),
      blockId: this.blockId,
      pc: this.pc,
    };
  }

  static restoreSkeleton(
    serialized: SerializedUserThread,
    irModule: IRModule,
  ): UserThread {
    const thread = Object.create(UserThread.prototype) as UserThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      block: UserBlock;
      blockId: BlockId;
      pc: number;
    };
    const block = resolveBlockPayload(irModule, serialized.blockId, "blockUser");
    writable.block = block.body;
    writable.blockId = serialized.blockId;
    writable.pc = serialized.pc;
    return thread;
  }

  link(
    serialized: SerializedUserThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedUserThread = SerializedChildThreadCommon & {
  kind: "user";
  blockId: BlockId;
  pc: number;
};

/**
 * "Structural" blocks read VarIds from the caller's scope (state inits,
 * subject, iter sources, ...). They must be invoked via callInline so
 * those VarIds are reachable through the new scope's parent chain.
 */
function isStructuralBlock(kind: Block["kind"]): boolean {
  switch (kind) {
    case "blockHandle":
    case "blockFor":
    case "blockMatch":
    case "blockTuple":
    case "blockArray":
      return true;
    default:
      return false;
  }
}

function resolveArgs(machine: MachineState, scopeId: ScopeId, call: CallData): Record<string, Value> {
  const args: Record<string, Value> = {};
  for (const arg of call.arguments) {
    args[arg.label] = getValueFromScope(machine, scopeId, arg.var);
  }
  return args;
}
