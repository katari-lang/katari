import type { BlockId, ReqId } from "../../ir/types.js";
import type { DelegationId, ScopeId, ThreadId } from "../id.js";
import { createThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { createScope } from "../scope.js";
import type { Value } from "../value.js";
import {
  EMPTY_BOUNDARIES,
  Thread,
  type CallId,
  type SerializedThreadCommon,
  type ThreadInit,
} from "./types.js";

/**
 * Per-delegation root thread managing a single API → CORE delegation.
 * Symmetric with ExternalThread (CORE → FFI).
 *
 * Lifecycle:
 *   1. Created by `handleDelegateFromAPI` (one per inbound delegate event).
 *   2. `onCall` (run by the runner the first time the queue is processed)
 *      pushes a `callBlock` for the target agent block.
 *   3. On child completion: emits `delegateAck` (CORE→API), terminates self.
 *   4. On API termination: marks `cancelling` and cancels children. The
 *      eventual finishCancelling emits `terminateAck`.
 *
 * Root cancellation has its own path (`beginTerminate`) rather than the
 * generic `cancel` event flow because:
 *   - APIThread is never the target of a `cancel` queue event.
 *   - The bookkeeping (`apiDelegations.delete`, terminateAck emission) is
 *     specific to APIThread and is contained in `finishCancelling`.
 */
export class APIThread extends Thread {
  override readonly parent = null;
  override readonly parentCallId = null;

  readonly delegationId: DelegationId;
  /** Block to call on first onCall. */
  private readonly entryBlockId: number;
  private readonly entryArgs: Record<string, Value>;

  private constructor(
    init: APIThreadInit,
    delegationId: DelegationId,
    entryBlockId: number,
    entryArgs: Record<string, Value>,
  ) {
    super(init);
    this.delegationId = delegationId;
    this.entryBlockId = entryBlockId;
    this.entryArgs = entryArgs;
  }

  override onCall(machine: MachineState): void {
    machine.queue.push({
      kind: "callBlock",
      parent: this,
      callId: 0,
      blockId: this.entryBlockId,
      args: this.entryArgs,
    });
  }

  protected override onChildDone(machine: MachineState, _callId: CallId, value: Value): void {
    machine.pendingOutEvents.push({
      from: "CORE",
      to: "API",
      kind: "delegateAck",
      delegationId: this.delegationId,
      value,
    });
    machine.apiDelegations.delete(this.delegationId);
    machine.threads.delete(this.id);
  }

  /** Final cleanup for a cancelled APIThread root: emit terminateAck. */
  override finishCancelling(machine: MachineState): void {
    machine.pendingOutEvents.push({
      from: "CORE",
      to: "API",
      kind: "terminateAck",
      delegationId: this.delegationId,
    });
    machine.apiDelegations.delete(this.delegationId);
    machine.threads.delete(this.id);
  }

  /**
   * APIThread is the root and is never the target of an in-process
   * `cancel` event. Termination from outside (the API endpoint) goes
   * through `beginTerminate` which sets `status` and cascades cancels.
   */
  override onCancelReceived(_machine: MachineState): void {
    throw new Error(
      "APIThread cannot be cancelled by a cancel event (use handleTerminateFromAPI)",
    );
  }

  /** Triggered by `handleTerminateFromAPI`: API requested termination. */
  beginTerminate(machine: MachineState): void {
    if (this.statusValue === "cancelling") return;
    this.status = "cancelling";
    if (this.children.size === 0) {
      this.finishCancelling(machine);
      return;
    }
    for (const child of this.children.values()) {
      machine.queue.push({ kind: "cancel", target: child });
    }
  }

  // ─── Static entry points (called from machine.applyEvent) ───────────────

  /**
   * Handle an inbound delegate event from API. Creates a per-delegation
   * APIThread and pushes a `callBlock` event for the target agent.
   */
  static handleDelegateFromAPI(
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
    // scopeId for uniformity (every Thread has one).
    const apiScope = createScope(state, null);
    const apiThread = new APIThread(
      {
        id: createThreadId(),
        scopeId: apiScope.id,
        handlers: new Map<ReqId, Thread>(),
        boundaries: EMPTY_BOUNDARIES,
      },
      delegationId,
      blockId,
      args,
    );
    state.threads.set(apiThread.id, apiThread);
    state.apiDelegations.set(delegationId, apiThread);

    apiThread.onCall(state);
  }

  /**
   * Handle an inbound terminate event from API. Marks the APIThread
   * "cancelling" and cancels its children; the eventual finishCancelling
   * emits `terminateAck`.
   */
  static handleTerminateFromAPI(state: MachineState, delegationId: DelegationId): void {
    const apiThread = state.apiDelegations.get(delegationId);
    if (apiThread === undefined) return;
    apiThread.beginTerminate(state);
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedAPIThread {
    return {
      kind: "api",
      ...this.serializeCommon(),
      delegationId: this.delegationId,
      entryBlockId: this.entryBlockId,
      entryArgs: this.entryArgs,
    };
  }

  static restoreSkeleton(serialized: SerializedAPIThread): APIThread {
    const thread = Object.create(APIThread.prototype) as APIThread;
    thread.applySnapshotCommon(serialized);
    const writable = thread as unknown as {
      delegationId: DelegationId;
      entryBlockId: BlockId;
      entryArgs: Record<string, Value>;
    };
    writable.delegationId = serialized.delegationId;
    writable.entryBlockId = serialized.entryBlockId;
    writable.entryArgs = serialized.entryArgs;
    return thread;
  }

  link(
    serialized: SerializedAPIThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkCommon(serialized, threadsById);
  }
}

export type SerializedAPIThread = SerializedThreadCommon & {
  kind: "api";
  delegationId: DelegationId;
  entryBlockId: BlockId;
  entryArgs: Record<string, Value>;
};

type APIThreadInit = ThreadInit & {
  id: ThreadId;
  scopeId: ScopeId;
};
