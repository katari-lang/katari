import type { TupleBlock } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { CallId, CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Executes a BlockTuple (tuple construction).
 *
 * Sequential: evaluates element blocks one by one.
 * Parallel: evaluates all element blocks concurrently.
 *
 * CallId = element index (0, 1, 2, ...).
 */
export type TupleThread = ThreadBase & {
  kind: "tuple";
  block: TupleBlock;
  /** Collected results from children. */
  collected: Map<CallId, Value>;
  /** Sequential mode: next element index to dispatch. */
  nextIndex: number;
};

export function createTupleThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: TupleBlock,
): TupleThread {
  const thread: TupleThread = {
    ...init,
    kind: "tuple",
    scopeId: init.scopeId,
    children: new Map(),
    status: "running",
    collected: new Map(),
    block,
    nextIndex: 0,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallTuple(machine: MachineState, thread: TupleThread): void {
  const elements = thread.block.elements;

  if (elements.length === 0) {
    machine.queue.push({
      kind: "done",
      parent: thread.parent!,
      callId: thread.parentCallId!,
      value: { kind: "tuple", elements: [] },
    });
    return;
  }

  if (thread.block.parallel) {
    for (let i = 0; i < elements.length; i++) {
      machine.queue.push({
        kind: "call",
        parent: thread,
        callId: i,
        blockId: elements[i],
        args: new Map(),
        scopeId: thread.scopeId,
      });
    }
  } else {
    machine.queue.push({
      kind: "call",
      parent: thread,
      callId: 0,
      blockId: elements[0],
      args: new Map(),
      scopeId: thread.scopeId,
    });
  }
}

export function onChildDoneTuple(machine: MachineState, thread: TupleThread, callId: CallId, value: Value): void {
  thread.collected.set(callId, value);
  const elements = thread.block.elements;

  if (thread.block.parallel) {
    if (thread.collected.size >= elements.length) {
      const values = elements.map((_, i) => thread.collected.get(i)!);
      machine.queue.push({
        kind: "done",
        parent: thread.parent!,
        callId: thread.parentCallId!,
        value: { kind: "tuple", elements: values },
      });
    }
  } else {
    thread.nextIndex++;
    if (thread.nextIndex >= elements.length) {
      const values = elements.map((_, i) => thread.collected.get(i)!);
      machine.queue.push({
        kind: "done",
        parent: thread.parent!,
        callId: thread.parentCallId!,
        value: { kind: "tuple", elements: values },
      });
    } else {
      machine.queue.push({
        kind: "call",
        parent: thread,
        callId: thread.nextIndex,
        blockId: elements[thread.nextIndex],
        args: new Map(),
        scopeId: thread.scopeId,
      });
    }
  }
}
