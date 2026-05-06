import type { BlockId, ContKind, ForBlock, VarId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import { NULL_VALUE, type Value } from "../value.js";
import {
  ChildThread,
  type CallId,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockFor (for-loop).
 *
 * Sequential: evaluates body once per element. CallId = iteration index.
 * The optional `then` block uses CallId = -1.
 *
 * Boundary registration: ForThread is the boundary for `for_break`
 * (`exitKindForBreak`) and `for_next` (`contKindForNext`); the constructor
 * installs `this` into both slots.
 *
 * `postCancelActions` records "what to do after this child finishes
 * cancelling" for targeted cancels (currently only `for_next`-driven
 * iteration advance).
 */
export class ForThread extends ChildThread {
  readonly block: ForBlock;
  /** Next iteration index to dispatch. */
  private currentIndex: number = 0;
  private readonly postCancelActions: Map<CallId, ForPostCancelAction> = new Map();

  constructor(machine: MachineState, init: ChildThreadInit, block: ForBlock) {
    super(init);
    this.block = block;

    // Initialize state variables in the freshly-allocated scope.
    for (const [bodyVar, initVar] of block.stateInits) {
      const initValue = getValueFromScope(machine, init.scopeId, initVar);
      setValueInScope(machine, init.scopeId, bodyVar, initValue);
    }

    // Install self as the boundary for for_break / for_next.
    this.boundaries = {
      ...this.boundaries,
      exitKindForBreak: this,
      contKindForNext: this,
    };
  }

  override onCall(machine: MachineState): void {
    const iterables = resolveIterables(machine, this);
    const length = getIterableLength(iterables);

    if (length === 0) {
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
    const iterables = resolveIterables(machine, this);
    const length = getIterableLength(iterables);

    if (this.currentIndex >= length) {
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
        const iterables = resolveIterables(machine, this);
        const length = getIterableLength(iterables);
        if (this.currentIndex >= length) {
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
      block: this.block,
      currentIndex: this.currentIndex,
      postCancelActions: [...this.postCancelActions.entries()],
    };
  }

  static restoreSkeleton(serialized: SerializedForThread): ForThread {
    const thread = Object.create(ForThread.prototype) as ForThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      block: ForBlock;
      currentIndex: number;
      postCancelActions: Map<CallId, ForPostCancelAction>;
    };
    writable.block = serialized.block;
    writable.currentIndex = serialized.currentIndex;
    writable.postCancelActions = new Map(serialized.postCancelActions);
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
  block: ForBlock;
  currentIndex: number;
  postCancelActions: [CallId, ForPostCancelAction][];
};

export type ForPostCancelAction = { kind: "advance" };

// ─── Module-level helpers ────────────────────────────────────────────────────

function resolveIterables(machine: MachineState, thread: ForThread): Value[] {
  return thread.block.iters.map(([_elemVar, sourceVar]) =>
    getValueFromScope(machine, thread.scopeId, sourceVar),
  );
}

function getIterableLength(iterables: Value[]): number {
  if (iterables.length === 0) return 0;
  const first = iterables[0];
  if (first === undefined || first.kind !== "array") {
    throw new Error("ForThread: iter source is not an array");
  }
  return first.elements.length;
}

function bindElementVars(
  machine: MachineState,
  thread: ForThread,
  iterables: Value[],
  index: number,
): void {
  for (let i = 0; i < thread.block.iters.length; i++) {
    const iter = thread.block.iters[i];
    const array = iterables[i];
    if (iter === undefined || array === undefined || array.kind !== "array") {
      throw new Error("ForThread: iter source is not an array");
    }
    const elem = array.elements[index];
    if (elem === undefined) {
      throw new Error(`ForThread: element at index ${index} missing`);
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
