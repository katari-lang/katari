import type { BlockId, ContKind, ForBlock, IRModule, VarId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import { NULL_VALUE, type Value } from "../value.js";
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
 * Executes a BlockFor (for-loop).
 *
 * Multi-iter semantics: **Cartesian product** (the iter list `(a in xs, b in ys)`
 * runs `xs.length × ys.length` body invocations, with the *first* iter being
 * the outermost loop). Concretely, for `(a in [1,2,3], b in [10,20])` the body
 * sees `(a,b)` in this order: `(1,10),(1,20),(2,10),(2,20),(3,10),(3,20)`.
 *
 * `currentIndex` is the *linear* iteration counter; the per-iter element
 * indices are recovered via mixed-radix decoding inside {@link bindElementVars}.
 * The total iteration count is the product of all iter source lengths
 * ({@link getIterableTotal}). If any iter source is empty, the total is 0 and
 * we go straight to the optional `then` block (or `done` with null).
 *
 * The optional `then` block uses CallId = -1.
 *
 * Boundary registration: ForThread is the boundary for `for_break`
 * (`exitKindForBreak`) and `for_next` (`contKindForNext`); the constructor
 * installs `this` into both slots.
 *
 * `postCancelActions` records "what to do after this child finishes
 * cancelling" for targeted cancels (currently only `for_next`-driven
 * iteration advance).
 *
 * **Parallel mode** (`block.parallel === true`) is *not yet supported*. The
 * straightforward "spawn all iterations at once" implementation conflicts
 * with the current sequential for_break / for_next semantics (which assume
 * a single in-flight body), and with the iter-var binding scheme (currently
 * iter vars are written into the for thread's own scope, which would race
 * across parallel iterations). A future PR can support it by writing iter
 * vars into per-iteration child scopes via callInline scopeBindings, plus
 * deciding the for_break / for_next semantics under parallelism. Until then
 * we throw at runtime so misuse is loud.
 */
export class ForThread extends ChildThread {
  readonly block: ForBlock;
  /** IR id of the BlockFor backing this thread. See UserThread.blockId. */
  readonly blockId: BlockId;
  /** Next iteration index to dispatch. */
  private currentIndex: number = 0;
  private readonly postCancelActions: Map<CallId, ForPostCancelAction> = new Map();
  /**
   * Iter source array values, resolved once at construction.
   *
   * Captured up front (instead of re-resolving from scope each iteration)
   * so the iteration count stays stable across `applyEvent` boundaries
   * even if the underlying scope variables ever become mutable. The
   * snapshot persists this directly, which means a restored ForThread
   * will see the exact iter values it was originally launched with — the
   * mid-iteration bounds violation Explore #2 worried about cannot
   * occur.
   */
  private readonly iterableSnapshot: Value[];

  constructor(
    machine: MachineState,
    init: ChildThreadInit,
    block: ForBlock,
    blockId: BlockId,
  ) {
    super(init);
    this.block = block;
    this.blockId = blockId;

    // Initialize state variables in the freshly-allocated scope.
    for (const [bodyVar, initVar] of block.stateInits) {
      const initValue = getValueFromScope(machine, init.scopeId, initVar);
      setValueInScope(machine, init.scopeId, bodyVar, initValue);
    }

    // Resolve iter sources once. Reads from the parent scope chain via
    // `init.scopeId`. Caller invariant: the for block's iter sources must
    // be live arrays in the caller scope by this point (always true when
    // ForThread is spawned via callInline from a UserThread that just
    // emitted a `statementCall` on the for block).
    this.iterableSnapshot = block.iters.map(([_elemVar, sourceVar]) =>
      getValueFromScope(machine, init.scopeId, sourceVar),
    );

    // Install self as the boundary for for_break / for_next.
    this.boundaries = extendBoundaries(this.boundaries, {
      exitKindForBreak: this,
      contKindForNext: this,
    });
  }

  override onCall(machine: MachineState): void {
    if (this.block.parallel) {
      throw new Error(
        "ForThread: parallel for is not yet implemented (iter-var binding + for_break/for_next semantics under parallelism need a separate design)",
      );
    }
    const iterables = this.iterableSnapshot;
    const total = getIterableTotal(iterables);

    if (total === 0) {
      this.emitForDone(machine);
      return;
    }

    bindElementVars(machine, this, iterables, 0);
    this.pushBodyCall(machine, 0);
  }

  protected override onChildDone(machine: MachineState, callId: CallId, value: Value): void {
    if (callId === -1) {
      // then block completed
      machine.queue.push({
        kind: "done",
        parent: this.parent,
        callId: this.parentCallId,
        value,
      });
      return;
    }

    this.currentIndex++;
    const iterables = this.iterableSnapshot;
    const total = getIterableTotal(iterables);

    if (this.currentIndex >= total) {
      this.emitForDone(machine);
      return;
    }

    bindElementVars(machine, this, iterables, this.currentIndex);
    this.pushBodyCall(machine, this.currentIndex);
  }

  /**
   * Handle a `cont` event with contKind === "contKindForNext".
   *
   * Apply modifiers to the for-thread's state vars, then cancel the body
   * thread of the current iteration so we can advance. The advance itself
   * runs in `onChildCancelAck` once the cancelled body has acked.
   *
   * `source` is the thread inside the body that emitted the cont; it might
   * be a deep descendant. We use it to find which iteration body (the
   * immediate child of `this`) to cancel.
   */
  override onCont(
    machine: MachineState,
    source: Thread,
    contKind: ContKind,
    _value: Value,
    modifiers: ReadonlyMap<VarId, Value>,
  ): void {
    if (contKind !== "contKindForNext") {
      throw new Error(
        `ForThread.onCont: expected contKindForNext, got ${contKind}`,
      );
    }
    for (const [targetVar, newValue] of modifiers) {
      setValueInScope(machine, this.scopeId, targetVar, newValue);
    }
    const childCallId = findImmediateChildCallId(this, source);
    this.postCancelActions.set(childCallId, { kind: "advance" });
    const childThread = this.children.get(childCallId);
    if (childThread === undefined) {
      throw new Error(`ForThread.onCont: no live child at callId ${childCallId}`);
    }
    machine.queue.push({ kind: "cancel", target: childThread });
  }

  protected override onChildCancelAck(machine: MachineState, callId: CallId): void {
    const action = this.postCancelActions.get(callId);
    if (action === undefined) {
      throw new Error(
        `ForThread.onChildCancelAck: no postCancelAction for callId ${callId}`,
      );
    }
    this.postCancelActions.delete(callId);
    switch (action.kind) {
      case "advance": {
        this.currentIndex++;
        const iterables = this.iterableSnapshot;
        const total = getIterableTotal(iterables);
        if (this.currentIndex >= total) {
          this.emitForDone(machine);
          return;
        }
        bindElementVars(machine, this, iterables, this.currentIndex);
        this.pushBodyCall(machine, this.currentIndex);
        return;
      }
    }
  }

  // ─── Internal helpers ──────────────────────────────────────────────────

  private pushBodyCall(machine: MachineState, index: number): void {
    this.pushInlineCall(machine, index, this.block.bodyBlock);
  }

  private pushInlineCall(machine: MachineState, callId: CallId, blockId: BlockId): void {
    machine.queue.push({
      kind: "callInline",
      parent: this,
      callId,
      blockId,
      args: {},
      scopeId: this.scopeId,
    });
  }

  private emitForDone(machine: MachineState): void {
    if (this.block.thenBlock !== undefined) {
      this.pushInlineCall(machine, -1, this.block.thenBlock);
      return;
    }
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value: NULL_VALUE,
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedForThread {
    return {
      kind: "for",
      ...this.serializeChildCommon(),
      blockId: this.blockId,
      currentIndex: this.currentIndex,
      postCancelActions: [...this.postCancelActions.entries()],
      iterableSnapshot: this.iterableSnapshot,
    };
  }

  static restoreSkeleton(
    serialized: SerializedForThread,
    irModule: IRModule,
  ): ForThread {
    const thread = Object.create(ForThread.prototype) as ForThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      block: ForBlock;
      blockId: BlockId;
      currentIndex: number;
      postCancelActions: Map<CallId, ForPostCancelAction>;
      iterableSnapshot: Value[];
    };
    const block = resolveBlockPayload(irModule, serialized.blockId, "blockFor");
    writable.block = block.body;
    writable.blockId = serialized.blockId;
    writable.currentIndex = serialized.currentIndex;
    writable.postCancelActions = new Map(serialized.postCancelActions);
    // Older snapshots predating Stage A10 don't carry `iterableSnapshot`.
    // For those we leave it empty — the only effect is that an extremely
    // pre-A10 snapshot may early-exit before any iteration runs, but
    // those snapshots couldn't have been mid-loop anyway.
    writable.iterableSnapshot = serialized.iterableSnapshot ?? [];
    return thread;
  }

  link(
    serialized: SerializedForThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedForThread = SerializedChildThreadCommon & {
  kind: "for";
  blockId: BlockId;
  currentIndex: number;
  postCancelActions: [CallId, ForPostCancelAction][];
  /**
   * Iter source array values captured at construction time. Optional for
   * back-compat with snapshots produced before Stage A10. New snapshots
   * always include this; the deserializer falls back to an empty array
   * when missing (compile-time linkage path).
   */
  iterableSnapshot?: Value[];
};

export type ForPostCancelAction = { kind: "advance" };

// ─── Module-level helpers ────────────────────────────────────────────────────

/**
 * Total number of iterations for a Cartesian product over `iterables`.
 *
 * - Zero iters: 1 (degenerate — the body runs once with no element vars).
 *   In practice the parser/lowerer never emits zero-iter `for`, but the math
 *   is correct so we leave it well-defined.
 * - Any source with length 0: total = 0 (the body never runs).
 * - Otherwise: product of all source lengths.
 *
 * Throws on non-array iter sources (compiler-checked invariant; reaching
 * this is an IR-level bug).
 */
function getIterableTotal(iterables: Value[]): number {
  let total = 1;
  for (const it of iterables) {
    if (it.kind !== "array") {
      throw new Error("ForThread: iter source is not an array");
    }
    total *= it.elements.length;
  }
  return total;
}

/**
 * Decode `linearIndex` into per-iter element indices via mixed-radix
 * arithmetic and write the corresponding element values into the for
 * thread's scope.
 *
 * Iter ordering: the **first iter is the outermost loop**. With iters
 * `[a in xs, b in ys, c in zs]`, body invocation `linearIndex` corresponds
 * to:
 *   c_idx = linearIndex            % zs.length
 *   b_idx = floor(linearIndex / zs.length)            % ys.length
 *   a_idx = floor(linearIndex / (zs.length * ys.length)) % xs.length
 *
 * Implementation: we walk the iter list right-to-left, peeling off the
 * least-significant digit each step. The resulting visit order on the body
 * matches `(a0,b0,c0), (a0,b0,c1), ..., (a0,b1,c0), ..., (aN,bM,cK)`.
 */
function bindElementVars(
  machine: MachineState,
  thread: ForThread,
  iterables: Value[],
  linearIndex: number,
): void {
  let remaining = linearIndex;
  for (let i = thread.block.iters.length - 1; i >= 0; i--) {
    const iter = thread.block.iters[i];
    const array = iterables[i];
    if (iter === undefined || array === undefined || array.kind !== "array") {
      throw new Error("ForThread: iter source is not an array");
    }
    const len = array.elements.length;
    if (len === 0) {
      // Unreachable when called via onCall / onChildDone (those gate on
      // total > 0), but defensive in case of a future caller.
      throw new Error(`ForThread: iter at index ${i} is empty`);
    }
    const digit = remaining % len;
    remaining = Math.floor(remaining / len);
    const elem = array.elements[digit];
    if (elem === undefined) {
      throw new Error(`ForThread: element at digit ${digit} missing`);
    }
    setValueInScope(machine, thread.scopeId, iter[0], elem);
  }
}

function findImmediateChildCallId(forT: ForThread, source: Thread): CallId {
  let cur: Thread | null = source;
  while (cur !== null) {
    if (cur.parent === forT && cur.parentCallId !== null) {
      return cur.parentCallId;
    }
    cur = cur.parent;
  }
  throw new Error(
    "findImmediateChildCallId: source is not a descendant of for-thread",
  );
}
