import type { ReqId } from "../../ir/types.js";
import type { AskId, ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockRequest. Issues a single `ask` to the registered
 * handler-owning thread (looked up via `handlers[reqId]`), then waits
 * for the matching `askComplete` to come back.
 *
 * RequestThread has no statements of its own and never spawns children.
 *
 * Lifecycle:
 *   onCall      → emit `ask` to handlers[reqId], record pendingAskId
 *   askComplete → emit `done` with the resume value
 */
export class RequestThread extends ChildThread {
  readonly reqId: ReqId;
  readonly args: Record<string, Value>;
  /** Allocated by `onCall`; matches the `askComplete` reply. */
  private pendingAskId?: AskId;

  constructor(init: ChildThreadInit, reqId: ReqId, args: Record<string, Value>) {
    super(init);
    this.reqId = reqId;
    this.args = args;
  }

  /**
   * RequestThread asks at most once in its entire lifetime, so its AskId
   * is always 0. The (asker, askId) pair is unique because `asker` (this
   * thread) is unique. Other asker kinds (future external agents) that
   * may issue multiple asks will keep their own per-asker counter.
   */
  static readonly REQUEST_ASK_ID = 0 as AskId;

  override onCall(machine: MachineState): void {
    // `handlers` is now typed as `ReadonlyMap<ReqId, HandleThread>`
    // (HandleThread is the only construct that installs entries into a
    // child's handler map), so no `as HandleThread` cast is needed at the
    // ask dispatch site below.
    const handler = this.handlers.get(this.reqId);
    if (handler === undefined) {
      throw new Error(
        `RequestThread.onCall: no handler registered for reqId ${this.reqId}`,
      );
    }
    this.pendingAskId = RequestThread.REQUEST_ASK_ID;
    machine.queue.push({
      kind: "ask",
      target: handler,
      asker: this,
      askId: RequestThread.REQUEST_ASK_ID,
      reqId: this.reqId,
      args: this.args,
    });
  }

  override onAskComplete(machine: MachineState, askId: AskId, value: Value): void {
    if (this.pendingAskId === undefined) {
      // Reachable only via a snapshot taken before this thread's onCall ran.
      // The current synchronous applyEvent model never persists such a state
      // (onCall fires from adoptChild within the same processQueue pass), but
      // the deserializer re-triggers onCall for these threads as a defensive
      // measure (see snapshot.ts deserializeMachine pass 3). If we still see
      // this here, something bypassed that pass — fail loudly so the bug is
      // visible.
      throw new Error(
        `RequestThread.onAskComplete: pendingAskId is undefined — onCall was never invoked (snapshot inconsistency)`,
      );
    }
    if (this.pendingAskId !== askId) {
      throw new Error(
        `RequestThread.onAskComplete: askId mismatch (expected ${this.pendingAskId}, got ${askId})`,
      );
    }
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value,
    });
  }

  /** Snapshot inspector used by the deserializer's pass-3 re-trigger. */
  get hasIssuedAsk(): boolean {
    return this.pendingAskId !== undefined;
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedRequestThread {
    return {
      kind: "request",
      ...this.serializeChildCommon(),
      reqId: this.reqId,
      args: this.args,
      pendingAskId: this.pendingAskId,
    };
  }

  static restoreSkeleton(serialized: SerializedRequestThread): RequestThread {
    const thread = Object.create(RequestThread.prototype) as RequestThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      reqId: ReqId;
      args: Record<string, Value>;
      pendingAskId: AskId | undefined;
    };
    writable.reqId = serialized.reqId;
    writable.args = serialized.args;
    writable.pendingAskId = serialized.pendingAskId;
    return thread;
  }

  link(
    serialized: SerializedRequestThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedRequestThread = SerializedChildThreadCommon & {
  kind: "request";
  reqId: ReqId;
  args: Record<string, Value>;
  pendingAskId?: AskId;
};
