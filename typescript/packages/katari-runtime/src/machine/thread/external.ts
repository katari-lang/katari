import type { ExternalName } from "../../ir/types.js";
import { createDelegationId, type DelegationId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Represents an FFI sidecar call.
 * Symmetric with APIThread (API → CORE).
 *
 * Lifecycle:
 * 1. Created by runner when a BlockExternal is encountered
 * 2. At creation: registers delegation, emits delegate outEvent (CORE→FFI)
 * 3. On delegateAck: handleDelegateAckFromFFI pushes done event for parent, terminates self
 */
export type ExternalThread = ThreadBase & {
  kind: "external";
  externalName: ExternalName;
  args: Map<string, Value>;
  delegationId: DelegationId;
};

export function createExternalThread(
  machine: MachineState,
  init: CreateThreadInit,
  externalName: ExternalName,
  args: Map<string, Value>,
): ExternalThread {
  const delegationId = createDelegationId();
  const thread: ExternalThread = {
    ...init,
    kind: "external",
    scopeId: init.parent.scopeId,
    children: new Map(),
    status: "running",
    externalName,
    args,
    delegationId,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallExternal(machine: MachineState, thread: ExternalThread): void {
  machine.delegations.set(thread.delegationId, thread);
  machine.outEvents.push({
    from: "CORE",
    to: "FFI",
    kind: "delegate",
    qualifiedName: `${thread.externalName.module_}.${thread.externalName.name}`,
    args: thread.args,
    delegationId: thread.delegationId,
  });
}

/**
 * Handle an inbound delegateAck event from FFI.
 * Pushes a done event for the external thread's parent.
 * Cleanup (children.delete, threads.delete) is handled by processQueue's done processing.
 */
export function handleDelegateAckFromFFI(
  state: MachineState,
  delegationId: DelegationId,
  value: Value,
): void {
  const ext = state.delegations.get(delegationId);
  if (!ext) {
    throw new Error(
      `handleDelegateAckFromFFI: delegationId ${delegationId} not found`,
    );
  }

  if (ext.status === "cancelling") {
    // Cancelling — ignore result, wait for terminateAck instead.
    return;
  }

  state.delegations.delete(delegationId);

  state.queue.push({
    kind: "done",
    parent: ext.parent!,
    callId: ext.parentCallId!,
    value,
  });
}

/**
 * Handle an inbound terminateAck event from FFI.
 * Pushes a cancelAck event for the external thread's parent.
 */
export function handleTerminateAckFromFFI(
  state: MachineState,
  delegationId: DelegationId,
): void {
  const ext = state.delegations.get(delegationId);
  if (!ext) return; // already cleaned up

  state.delegations.delete(delegationId);

  state.queue.push({
    kind: "cancelAck",
    parent: ext.parent!,
    callId: ext.parentCallId!,
  });
}
