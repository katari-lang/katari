import type { CtorId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockCtor (data constructor application).
 * Completes immediately in `onCall`: constructs a tagged value from arguments.
 */
export class CtorThread extends ChildThread {
  readonly ctorId: CtorId;
  readonly args: Record<string, Value>;

  constructor(init: ChildThreadInit, ctorId: CtorId, args: Record<string, Value>) {
    super(init);
    this.ctorId = ctorId;
    this.args = args;
  }

  override onCall(machine: MachineState): void {
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value: {
        kind: "tagged",
        ctorId: this.ctorId,
        fields: { ...this.args },
      },
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedCtorThread {
    return {
      kind: "ctor",
      ...this.serializeChildCommon(),
      ctorId: this.ctorId,
      args: this.args,
    };
  }

  static restoreSkeleton(serialized: SerializedCtorThread): CtorThread {
    const thread = Object.create(CtorThread.prototype) as CtorThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      ctorId: CtorId;
      args: Record<string, Value>;
    };
    writable.ctorId = serialized.ctorId;
    writable.args = serialized.args;
    return thread;
  }

  link(
    serialized: SerializedCtorThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedCtorThread = SerializedChildThreadCommon & {
  kind: "ctor";
  ctorId: CtorId;
  args: Record<string, Value>;
};
