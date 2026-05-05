import type { BlockId } from "../../ir/types.js";
import type { DelegationId } from "../id.js";
import { createThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { createScope } from "../scope.js";
import type { Value } from "../value.js";
import type { CallId, ThreadBase } from "./types.js";

/**
 * Per-delegation root thread managing a single API → CORE delegation.
 * Symmetric with ExternalThread (CORE → FFI).
 *
 * Lifecycle:
 * 1. Created by handleDelegateFromAPI (one per inbound delegate event)
 * 2. Pushes a call event for the target agent block
 * 3. On child completion: emits delegateAck (CORE→API), terminates self
 */
export type APIThread = ThreadBase & {
  kind: "api";
  delegationId: DelegationId;
};

export function onCallAPI(_machine: MachineState, _thread: APIThread): void {
  // APIThread is never dispatched via onCall — it's created directly.
  // Kept for dispatch table exhaustiveness.
}

export function onChildDoneAPI(machine: MachineState, thread: APIThread, _callId: CallId, value: Value): void {
  // Emit delegateAck to API
  machine.outEvents.push({
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
 * Handle an inbound delegate event from API.
 * Creates a per-delegation APIThread and pushes a call event for the target block.
 */
export function handleDelegateFromAPI(
  state: MachineState,
  qualifiedName: string,
  args: Map<string, Value>,
  delegationId: DelegationId,
): void {
  const blockId = findBlockByQualifiedName(state, qualifiedName);
  if (blockId === undefined) {
    throw new Error(
      `handleDelegateFromAPI: block ${qualifiedName} not found in IR module`,
    );
  }

  // Create a per-delegation APIThread
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
    delegationId,
  };
  state.threads.set(apiThread.id, apiThread);
  state.apiDelegations.set(delegationId, apiThread);

  // Push call event — child will be the target agent
  state.queue.push({
    kind: "call",
    parent: apiThread,
    callId: 0,
    blockId,
    args,
    scopeId: apiThread.scopeId,
  });
}

function findBlockByQualifiedName(
  state: MachineState,
  qualifiedName: string,
): BlockId | undefined {
  const blockId = state.irModule.entries[qualifiedName];
  if (blockId !== undefined) return blockId;
  return undefined;
}
