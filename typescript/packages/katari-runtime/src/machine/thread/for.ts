import type { ForBlock } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import { createScope, getValueFromScope, setValueInScope } from "../scope.js";
import { NULL_VALUE, type Value } from "../value.js";
import type { CallId, CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Executes a BlockFor (for-loop).
 *
 * Sequential: evaluates body once per element.
 * CallId = iteration index (0, 1, ...).
 * Then block CallId = -1.
 */
export type ForThread = ThreadBase & {
  kind: "for";
  block: ForBlock;
  /** Next iteration index to dispatch. */
  currentIndex: number;
};

export function createForThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: ForBlock,
): ForThread {
  // Create a new scope for the for-loop (state vars + element vars)
  const forScope = createScope(machine, init.scopeId);

  // Initialize state variables from parent scope
  for (const [bodyVar, initVar] of block.stateInits) {
    const initValue = getValueFromScope(machine, init.scopeId, initVar);
    forScope.values.set(bodyVar, initValue);
  }

  const thread: ForThread = {
    ...init,
    kind: "for",
    scopeId: forScope.id,
    children: new Map(),
    status: "running",
    block,
    currentIndex: 0,
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
  machine.queue.push({
    kind: "call",
    parent: thread,
    callId: 0,
    blockId: thread.block.bodyBlock,
    args: new Map(),
    scopeId: thread.scopeId,
  });
}

export function onChildDoneFor(machine: MachineState, thread: ForThread, callId: CallId, value: Value): void {
  if (callId === -1) {
    // then block completed
    machine.queue.push({
      kind: "done",
      parent: thread.parent!,
      callId: thread.parentCallId!,
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
  machine.queue.push({
    kind: "call",
    parent: thread,
    callId: thread.currentIndex,
    blockId: thread.block.bodyBlock,
    args: new Map(),
    scopeId: thread.scopeId,
  });
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function emitForDone(machine: MachineState, thread: ForThread): void {
  if (thread.block.thenBlock !== undefined) {
    machine.queue.push({
      kind: "call",
      parent: thread,
      callId: -1,
      blockId: thread.block.thenBlock,
      args: new Map(),
      scopeId: thread.scopeId,
    });
  } else {
    machine.queue.push({
      kind: "done",
      parent: thread.parent!,
      callId: thread.parentCallId!,
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
  if (first.kind !== "array") throw new Error("ForThread: iter source is not an array");
  return first.elements.length;
}

function bindElementVars(machine: MachineState, thread: ForThread, iterables: Value[], index: number): void {
  for (let i = 0; i < thread.block.iters.length; i++) {
    const [elemVar] = thread.block.iters[i];
    const array = iterables[i];
    if (array.kind !== "array") throw new Error("ForThread: iter source is not an array");
    setValueInScope(machine, thread.scopeId, elemVar, array.elements[index]);
  }
}
