import type { DelegationId } from "../id.js";
import { createThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { createScope } from "../scope.js";
import type { Value } from "../value.js";
import { EMPTY_BOUNDARIES, type CallId, type RootThreadBase } from "./types.js";

/**
 * Per-delegation root thread managing a single API → CORE delegation.
 * Symmetric with ExternalThread (CORE → FFI).
 *
 * Lifecycle:
 * 1. Created by handleDelegateFromAPI (one per inbound delegate event)
 * 2. Pushes a call event for the target agent block
 * 3. On child completion: emits delegateAck (CORE→API), terminates self
 *
 * Root cancellation is handled here (handleTerminateFromAPI +
 * finishCancellingAPI) rather than in the runner's generic
 * finishCancelling, since the api-specific cleanup (terminateAck,
 * apiDelegations.delete) is unique to APIThread.
 */
export type APIThread = RootThreadBase & {
  kind: "api";
  delegationId: DelegationId;
};

export function onChildDoneAPI(machine: MachineState, thread: APIThread, _callId: CallId, value: Value): void {
  // Emit delegateAck to API
  machine.pendingOutEvents.push({
    from: "CORE",
    to: "API",
    kind: "delegateAck",
    delegationId: thread.delegationId,
    value,
  });

  // Clean up self
  machine.apiDelegations.delete(thread.delegationId);
  machine.threads.delete(thread.id);
}

/**
 * Final cleanup for a cancelled APIThread root: emit terminateAck and
 * remove from machine state. Called by the runner when all children
 * have cancelAck'd (status="cancelling" + children.size === 0), and by
 * handleTerminateFromAPI for the no-children case.
 */
export function finishCancellingAPI(machine: MachineState, thread: APIThread): void {
  machine.pendingOutEvents.push({
    from: "CORE",
    to: "API",
    kind: "terminateAck",
    delegationId: thread.delegationId,
  });
  machine.apiDelegations.delete(thread.delegationId);
  machine.threads.delete(thread.id);
}

/**
 * Handle an inbound delegate event from API.
 * Creates a per-delegation APIThread and pushes a callBlock event for the target agent.
 */
export function handleDelegateFromAPI(
  state: MachineState,
  qualifiedName: string,
  args: Record<string, Value>,
  delegationId: DelegationId,
): void {
  const blockId = state.irModule.entries[qualifiedName];
  if (blockId === undefined) {
    throw new Error(
      `handleDelegateFromAPI: block ${qualifiedName} not found in IR module`,
    );
  }

  // APIThread is the root and never reads variables; it still carries a
  // scopeId for uniformity (RootThreadBase requires one).
  const apiScope = createScope(state, null);
  const apiThread: APIThread = {
    id: createThreadId(),
    kind: "api",
    scopeId: apiScope.id,
    parent: null,
    parentCallId: null,
    handlers: new Map(),
    children: new Map(),
    status: "running",
    boundaries: EMPTY_BOUNDARIES,
    delegationId,
  };
  state.threads.set(apiThread.id, apiThread);
  state.apiDelegations.set(delegationId, apiThread);

  // Top-level agent call — runner allocates a fresh isolated scope.
  state.queue.push({
    kind: "callBlock",
    parent: apiThread,
    callId: 0,
    blockId,
    args,
  });
}

/**
 * Handle an inbound terminate event from API.
 * Cancels the APIThread's children and emits terminateAck when done.
 */
export function handleTerminateFromAPI(
  state: MachineState,
  delegationId: DelegationId,
): void {
  const apiThread = state.apiDelegations.get(delegationId);
  if (!apiThread || apiThread.status === "cancelling") return;

  apiThread.status = "cancelling";
  if (apiThread.children.size === 0) {
    finishCancellingAPI(state, apiThread);
  } else {
    for (const child of apiThread.children.values()) {
      state.queue.push({ kind: "cancel", target: child });
    }
  }
}
