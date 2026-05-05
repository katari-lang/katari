import type { ArrayBlock, BlockId } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { CallId, ChildThreadBase, CreateThreadInit } from "./types.js";

/**
 * Executes a BlockArray (array construction).
 *
 * Sequential: evaluates element blocks one by one.
 * Parallel: evaluates all element blocks concurrently.
 *
 * CallId = element index (0, 1, 2, ...).
 */
export type ArrayThread = ChildThreadBase & {
  kind: "array";
  block: ArrayBlock;
  /** Collected results from children. */
  collected: Map<CallId, Value>;
  /** Sequential mode: next element index to dispatch. */
  nextIndex: number;
};

export function createArrayThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: ArrayBlock,
): ArrayThread {
  const thread: ArrayThread = {
    ...init,
    kind: "array",
    children: new Map(),
    status: "running",
    collected: new Map(),
    block,
    nextIndex: 0,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallArray(machine: MachineState, thread: ArrayThread): void {
  const elements = thread.block.elements;

  if (elements.length === 0) {
    machine.queue.push({
      kind: "done",
      parent: thread.parent,
      callId: thread.parentCallId,
      value: { kind: "array", elements: [] },
    });
    return;
  }

  if (thread.block.parallel) {
    for (let i = 0; i < elements.length; i++) {
      pushElementCall(machine, thread, i, elementAt(elements, i));
    }
  } else {
    pushElementCall(machine, thread, 0, elementAt(elements, 0));
  }
}

export function onChildDoneArray(machine: MachineState, thread: ArrayThread, callId: CallId, value: Value): void {
  thread.collected.set(callId, value);
  const elements = thread.block.elements;

  if (thread.block.parallel) {
    if (thread.collected.size >= elements.length) {
      emitDone(machine, thread, elements);
    }
  } else {
    thread.nextIndex++;
    if (thread.nextIndex >= elements.length) {
      emitDone(machine, thread, elements);
    } else {
      pushElementCall(machine, thread, thread.nextIndex, elementAt(elements, thread.nextIndex));
    }
  }
}

function pushElementCall(
  machine: MachineState,
  thread: ArrayThread,
  index: number,
  blockId: BlockId,
): void {
  machine.queue.push({
    kind: "callInline",
    parent: thread,
    callId: index,
    blockId,
    args: new Map(),
    scopeId: thread.scopeId,
  });
}

function emitDone(machine: MachineState, thread: ArrayThread, elements: BlockId[]): void {
  const values = elements.map((_, i) => {
    const v = thread.collected.get(i);
    if (v === undefined) {
      throw new Error(`ArrayThread.emitDone: missing element ${i}`);
    }
    return v;
  });
  machine.queue.push({
    kind: "done",
    parent: thread.parent,
    callId: thread.parentCallId,
    value: { kind: "array", elements: values },
  });
}

function elementAt(elements: BlockId[], index: number): BlockId {
  const blockId = elements[index];
  if (blockId === undefined) {
    throw new Error(`ArrayThread: element ${index} out of bounds`);
  }
  return blockId;
}
