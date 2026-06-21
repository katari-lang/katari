// The FFI abstraction — one layer. An external (FFI) leaf is a child instance whose body is an
// `ExternalThread`; that thread dispatches its call straight through this interface and suspends, and a
// later completion (delivered to the registered sink, which feeds the owning actor's mailbox) resumes
// it. Behind the interface sits the real process implementation (a subprocess sidecar), injected by the
// host; the engine never sees it. This deliberately collapses main's ffi-mux / ffi-module /
// sidecar-manager / sidecar stack into the single seam the external thread owns.
//
// `dispatch` is fire-and-forget: the result is asynchronous and arrives via the sink, so a completion
// always re-enters through the actor's serial mailbox and never races a turn in flight. The in-flight
// call is durable as its `ExternalThread` row (kind = external, externalState = open), so recovery
// re-dispatches from there; no separate table.

import type { FfiResult } from "../event/types.js";
import type { InstanceId, ProjectId, ThreadId } from "../ids.js";
import type { Value } from "../value/types.js";

/** One external dispatch: the addressed external thread, the handler `key`, and the call argument. */
export interface ExternalCall {
  projectId: ProjectId;
  instance: InstanceId;
  thread: ThreadId;
  /** The opaque dispatch key the handler interprets (the external block's `key`). */
  key: string;
  argument: Value | null;
}

export interface ExternalRunner {
  /** Register the sink completions are delivered to (the owning actor's mailbox feed). Called once. */
  onResult(sink: (result: FfiResult) => void): void;
  /** Dispatch a call. Fire-and-forget — the result arrives later via the sink as an `FfiResult`. */
  dispatch(call: ExternalCall): void;
  /** Cancel an in-flight call (its thread is being cancelled / its instance terminated). Best-effort. */
  cancel(instance: InstanceId, thread: ThreadId): void;
}

/** The seam default: no real process is configured, so dispatching one is an error. A host swaps in a
 *  subprocess-backed runner. Kept so a runtime with no FFI configured fails loudly, not silently. */
export class StubExternalRunner implements ExternalRunner {
  onResult(): void {
    // No completions are ever produced.
  }
  dispatch(call: ExternalCall): void {
    throw new Error(
      `no external process configured for FFI key "${call.key}" (inject a real ExternalRunner)`,
    );
  }
  cancel(): void {
    // Nothing in flight.
  }
}

/** A handler an in-process external call runs against its argument (the test / dev injection point). */
export type ExternalHandler = (argument: Value | null) => Value | Promise<Value>;

/**
 * An in-process runner backed by a handler map — the injection seam exercised in tests and usable for a
 * pure-JS FFI without a subprocess. `dispatch` runs the handler off the current turn and delivers the
 * result (or error) to the sink, so completions re-enter serially exactly like the real transport.
 */
export class InProcessExternalRunner implements ExternalRunner {
  private sink: ((result: FfiResult) => void) | null = null;
  private readonly cancelled = new Set<string>();

  constructor(private readonly handlers: Record<string, ExternalHandler>) {}

  onResult(sink: (result: FfiResult) => void): void {
    this.sink = sink;
  }

  dispatch(call: ExternalCall): void {
    const handler = this.handlers[call.key];
    const sink = this.sink;
    if (sink === null) {
      throw new Error("InProcessExternalRunner.dispatch called before onResult registered a sink");
    }
    const token = this.token(call.instance, call.thread);
    void (async () => {
      try {
        const value =
          handler === undefined
            ? Promise.reject(new Error(`no external handler for key "${call.key}"`))
            : handler(call.argument);
        const resolved = await value;
        if (this.cancelled.delete(token)) return;
        sink({ kind: "ffiResult", instance: call.instance, thread: call.thread, value: resolved });
      } catch (error) {
        if (this.cancelled.delete(token)) return;
        sink({
          kind: "ffiError",
          instance: call.instance,
          thread: call.thread,
          message: error instanceof Error ? error.message : String(error),
        });
      }
    })();
  }

  cancel(instance: InstanceId, thread: ThreadId): void {
    this.cancelled.add(this.token(instance, thread));
  }

  private token(instance: InstanceId, thread: ThreadId): string {
    return `${instance}/${thread}`;
  }
}
