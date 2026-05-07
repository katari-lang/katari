import type { ExternalName } from "../../ir/types.js";
import { createDelegationId, type DelegationId, type ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Represents an FFI sidecar call.
 * Symmetric with APIThread (API → CORE).
 *
 * Lifecycle:
 *   1. Constructed by the runner factory.
 *   2. `onCall` registers the delegation and emits `delegate` (CORE → FFI).
 *   3. `delegateAck` from FFI is routed via the static `handleDelegateAckFromFFI`
 *      to push `done` (or `cancelAck` if the thread is already cancelling).
 *   4. Cancel arrives → `beginCancel` emits `terminate` to FFI; the
 *      eventual `terminateAck` triggers `cancelAck` to parent.
 */
export class ExternalThread extends ChildThread {
  readonly externalName: ExternalName;
  readonly args: Record<string, Value>;
  readonly delegationId: DelegationId;

  constructor(init: ChildThreadInit, externalName: ExternalName, args: Record<string, Value>) {
    super(init);
    this.externalName = externalName;
    this.args = args;
    this.delegationId = createDelegationId();
  }

  override onCall(machine: MachineState): void {
    machine.delegations.set(this.delegationId, this);
    machine.pendingOutEvents.push({
      from: "CORE",
      to: "FFI",
      kind: "delegate",
      qualifiedName: `${this.externalName.module_}.${this.externalName.name}`,
      args: this.args,
      delegationId: this.delegationId,
    });
  }

  /**
   * External threads have no in-process children; cancellation maps to an
   * outbound `terminate`. We do NOT ack the parent here — that happens
   * once `terminateAck` (or a late `delegateAck`) arrives from FFI.
   */
  protected override beginCancel(machine: MachineState): void {
    machine.pendingOutEvents.push({
      from: "CORE",
      to: "FFI",
      kind: "terminate",
      delegationId: this.delegationId,
    });
  }

  // ─── FFI ack handlers (called from machine.applyEvent) ──────────────────

  /**
   * Inbound `delegateAck` from FFI.
   *
   * If the thread is already cancelling, the result is dropped and the
   * event is treated as a `cancelAck`. This relaxes the FFI contract: a
   * sidecar may respond with delegateAck even after receiving terminate;
   * the runtime absorbs it. A subsequent terminateAck (if any) becomes a
   * no-op because the delegation entry has already been removed.
   *
   * **Idempotent on unknown / already-cleaned-up delegationId**: matching
   * the symmetric behavior of {@link handleTerminateAckFromFFI}. A
   * delegateAck arriving after the delegation has already been resolved
   * (e.g. by an out-of-order terminateAck → delegateAck pair, or a
   * duplicate ack the FFI side retried after a connection blip) used to
   * throw and poison the entire version. We now treat it as a no-op so a
   * single agent's transient FFI flakiness cannot take everyone else with
   * it.
   */
  static handleDelegateAckFromFFI(
    state: MachineState,
    delegationId: DelegationId,
    value: Value,
  ): void {
    const ext = state.delegations.get(delegationId);
    if (ext === undefined) {
      // Unknown / stale delegation. Silently absorb so FFI retries and
      // out-of-order delegateAck-after-terminateAck pairs don't poison
      // the version, but log so ops can spot a misbehaving sidecar.
      state.logger.log(
        "debug",
        "ExternalThread.handleDelegateAckFromFFI: unknown delegationId (already cleaned up); dropping",
        { delegationId },
      );
      return;
    }
    state.delegations.delete(delegationId);

    if (ext.statusValue === "cancelling") {
      state.queue.push({
        kind: "cancelAck",
        parent: ext.parent,
        callId: ext.parentCallId,
      });
      return;
    }

    state.queue.push({
      kind: "done",
      parent: ext.parent,
      callId: ext.parentCallId,
      value,
    });
  }

  /**
   * Inbound `terminateAck` from FFI. Maps to `cancelAck` for the parent.
   * If the delegation has already been cleaned up (e.g., delegateAck
   * arrived first) this is a silent no-op.
   */
  static handleTerminateAckFromFFI(
    state: MachineState,
    delegationId: DelegationId,
  ): void {
    const ext = state.delegations.get(delegationId);
    if (ext === undefined) return;
    state.delegations.delete(delegationId);

    state.queue.push({
      kind: "cancelAck",
      parent: ext.parent,
      callId: ext.parentCallId,
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedExternalThread {
    return {
      kind: "external",
      ...this.serializeChildCommon(),
      externalName: this.externalName,
      args: this.args,
      delegationId: this.delegationId,
    };
  }

  static restoreSkeleton(
    serialized: SerializedExternalThread,
  ): ExternalThread {
    const thread = Object.create(ExternalThread.prototype) as ExternalThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      externalName: ExternalName;
      args: Record<string, Value>;
      delegationId: DelegationId;
    };
    writable.externalName = serialized.externalName;
    writable.args = serialized.args;
    writable.delegationId = serialized.delegationId;
    return thread;
  }

  link(
    serialized: SerializedExternalThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedExternalThread = SerializedChildThreadCommon & {
  kind: "external";
  externalName: ExternalName;
  args: Record<string, Value>;
  delegationId: DelegationId;
};
