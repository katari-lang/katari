import type { CtorId } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Executes a BlockCtor (data constructor application).
 * Completes immediately in onCall: constructs a tagged value from arguments.
 */
export type CtorThread = ThreadBase & {
  kind: "ctor";
  ctorId: CtorId;
  args: Map<string, Value>;
};

export function createCtorThread(
  machine: MachineState,
  init: CreateThreadInit,
  ctorId: CtorId,
  args: Map<string, Value>,
): CtorThread {
  const thread: CtorThread = {
    ...init,
    kind: "ctor",
    scopeId: init.parent.scopeId,
    children: new Map(),
    status: "running",
    ctorId,
    args,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallCtor(machine: MachineState, thread: CtorThread): void {
  machine.queue.push({
    kind: "done",
    parent: thread.parent!,
    callId: thread.parentCallId!,
    value: {
      kind: "tagged",
      ctorId: thread.ctorId,
      fields: Object.fromEntries(thread.args),
    },
  });
}
