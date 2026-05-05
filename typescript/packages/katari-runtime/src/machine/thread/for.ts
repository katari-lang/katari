import type { BlockId, ContKind, ForBlock, VarId } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import { NULL_VALUE, type Value } from "../value.js";
import type { CallId, ChildThreadBase, CreateThreadInit, Thread } from "./types.js";

/**
 * Executes a BlockFor (for-loop).
 *
 * Sequential: evaluates body once per element.
 * CallId = iteration index (0, 1, ...).
 * Then block CallId = -1.
 *
 * `postCancelActions` records "what to do after this child finishes
 * cancelling" for targeted cancels (currently only `for_next`-driven
 * iteration advance).
 */
export type ForThread = ChildThreadBase & {
  kind: "for";
  block: ForBlock;
  /** Next iteration index to dispatch. */
  currentIndex: number;
  postCancelActions: Map<CallId, ForPostCancelAction>;
};

export type ForPostCancelAction = { kind: "advance" };

export function createForThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: ForBlock,
): ForThread {
  // Initialize state variables in the freshly-allocated scope.
  // The scope is provided by the runner with the caller's scope as parent.
  for (const [bodyVar, initVar] of block.stateInits) {
    const initValue = getValueFromScope(machine, init.scopeId, initVar);
    setValueInScope(machine, init.scopeId, bodyVar, initValue);
  }

  const thread: ForThread = {
    ...init,
    kind: "for",
    children: new Map(),
    status: "running",
    block,
    currentIndex: 0,
    postCancelActions: new Map(),
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallFor(machine: MachineState, thread: ForThread): void {
  const iterables = resolveIterables(machine, thread);
  const length = getIterableLength(iterables);

  if (length === 0) {
    emitForDone(machine, thread);
    return;
  }

  bindElementVars(machine, thread, iterables, 0);
  pushBodyCall(machine, thread, 0);
}

export function onChildDoneFor(machine: MachineState, thread: ForThread, callId: CallId, value: Value): void {
  if (callId === -1) {
    // then block completed
    machine.queue.push({
      kind: "done",
      parent: thread.parent,
      callId: thread.parentCallId,
      value,
    });
    return;
  }

  thread.currentIndex++;
  const iterables = resolveIterables(machine, thread);
  const length = getIterableLength(iterables);

  if (thread.currentIndex >= length) {
    emitForDone(machine, thread);
    return;
  }

  bindElementVars(machine, thread, iterables, thread.currentIndex);
  pushBodyCall(machine, thread, thread.currentIndex);
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function pushBodyCall(machine: MachineState, thread: ForThread, index: number): void {
  pushInlineCall(machine, thread, index, thread.block.bodyBlock);
}

function pushInlineCall(
  machine: MachineState,
  thread: ForThread,
  callId: CallId,
  blockId: BlockId,
): void {
  machine.queue.push({
    kind: "callInline",
    parent: thread,
    callId,
    blockId,
    args: {},
    scopeId: thread.scopeId,
  });
}

function emitForDone(machine: MachineState, thread: ForThread): void {
  if (thread.block.thenBlock !== undefined) {
    pushInlineCall(machine, thread, -1, thread.block.thenBlock);
  } else {
    machine.queue.push({
      kind: "done",
      parent: thread.parent,
      callId: thread.parentCallId,
      value: NULL_VALUE,
    });
  }
}

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

function bindElementVars(machine: MachineState, thread: ForThread, iterables: Value[], index: number): void {
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

// ─── for_next (cont) ────────────────────────────────────────────────────────

/**
 * Handle a `cont` event with contKind === "contKindForNext".
 *
 * Apply modifiers to the for-thread's state vars, then cancel the body
 * thread of the current iteration so we can advance. The advance itself
 * runs in `onChildCancelAckFor` once the cancelled body has acked.
 *
 * `source` is the thread inside the body that emitted the cont; it might
 * be a deep descendant. We use it to find which iteration body (the
 * immediate child of `thread`) to cancel.
 */
export function onContFor(
  machine: MachineState,
  thread: ForThread,
  source: Thread,
  contKind: ContKind,
  modifiers: Map<VarId, Value>,
): void {
  if (contKind !== "contKindForNext") {
    throw new Error(
      `onContFor: expected contKindForNext, got ${contKind}`,
    );
  }
  // Apply modifiers to state vars.
  for (const [targetVar, newValue] of modifiers) {
    setValueInScope(machine, thread.scopeId, targetVar, newValue);
  }
  // Find the body child to cancel.
  const childCallId = findImmediateChildCallId(thread, source);
  thread.postCancelActions.set(childCallId, { kind: "advance" });
  const childThread = thread.children.get(childCallId);
  if (childThread === undefined) {
    throw new Error(`onContFor: no live child at callId ${childCallId}`);
  }
  machine.queue.push({ kind: "cancel", target: childThread });
}

export function onChildCancelAckFor(
  machine: MachineState,
  thread: ForThread,
  callId: CallId,
): void {
  const action = thread.postCancelActions.get(callId);
  if (action === undefined) {
    throw new Error(
      `onChildCancelAckFor: no postCancelAction for callId ${callId}`,
    );
  }
  thread.postCancelActions.delete(callId);
  switch (action.kind) {
    case "advance":
      thread.currentIndex++;
      const iterables = resolveIterables(machine, thread);
      const length = getIterableLength(iterables);
      if (thread.currentIndex >= length) {
        emitForDone(machine, thread);
        return;
      }
      bindElementVars(machine, thread, iterables, thread.currentIndex);
      pushBodyCall(machine, thread, thread.currentIndex);
      return;
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
