// The FFI transport — the `ffi` reactor's private port to the real external-handler process (a subprocess
// sidecar). An external call reaches the ffi reactor as a `delegate`; the reactor `dispatch`es it here and
// suspends, and a later `FfiCompletion` (delivered to the registered sink, which feeds the ffi reactor's
// turn) becomes the call's `delegateAck` / `escalate` / `terminateAck`. Behind this interface sits the real
// process implementation, injected by the host; the ffi reactor never sees it. One transport per project
// actor (each needs its own completion sink).
//
// `dispatch` is fire-and-forget: the result is asynchronous and arrives via the sink, so a completion always
// re-enters through the actor's serial mailbox and never races a turn in flight. The in-flight call is
// durable as the ffi reactor's `ffi_calls` row (key + argument), so recovery re-dispatches from there.
// Calls are correlated by their `delegation` id — the same id core's external proxy thread holds.

import type { DelegationId, ProjectId } from "../ids.js";
import type { Value } from "../value/types.js";

/** One external dispatch: the call's `delegation`, the handler `key`, and the argument. */
export interface FfiCall {
  projectId: ProjectId;
  delegation: DelegationId;
  /** The opaque dispatch key the handler interprets (the external block's `key`). */
  key: string;
  argument: Value | null;
  /** True when this is a recovery re-dispatch of a still-in-flight call (the process went down with the call
   *  pending). A handler can treat it as a retry — e.g. dedupe a non-idempotent side effect. */
  redispatch?: boolean;
}

/** The outcome of one dispatched call, fed back to the ffi reactor: a `result` (→ delegateAck), an `error`
 *  (→ a panic the reactor escalates), or a `cancelled` confirmation (→ terminateAck, after an `abort`). A
 *  late real result / error for an aborted call is harmless — the reactor treats any completion of a
 *  cancelling call as its abort. */
export interface FfiCompletion {
  delegation: DelegationId;
  outcome:
    | { kind: "result"; value: Value }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

export interface FfiTransport {
  /** Register the sink completions are delivered to (the ffi reactor's mailbox feed). Called once. */
  onComplete(sink: (completion: FfiCompletion) => void): void;
  /** Dispatch a call. Fire-and-forget — the outcome arrives later via the sink. */
  dispatch(call: FfiCall): void;
  /** Abort an in-flight call (its proxy is being cancelled). Fire-and-forget: once the underlying process has
   *  actually stopped, report it via the sink as `cancelled` so the reactor can `terminateAck` gracefully. */
  abort(delegation: DelegationId): void;
}

/** The seam default: no real process is configured, so dispatching one is an error. A host swaps in a
 *  subprocess-backed transport. Kept so a runtime with no FFI configured fails loudly, not silently. */
export class StubFfiTransport implements FfiTransport {
  onComplete(): void {
    // No completions are ever produced.
  }
  dispatch(call: FfiCall): void {
    throw new Error(
      `no external process configured for FFI key "${call.key}" (inject a real FfiTransport)`,
    );
  }
  abort(): void {
    // Nothing in flight.
  }
}

/** A handler an in-process external call runs against its argument (the test / dev injection point). */
export type FfiHandler = (argument: Value | null) => Value | Promise<Value>;

/**
 * An in-process transport backed by a handler map — the injection seam exercised in tests and usable for a
 * pure-JS FFI without a subprocess. `dispatch` runs the handler off the current turn and delivers the
 * outcome to the sink, so completions re-enter serially exactly like the real transport.
 */
export class InProcessFfiTransport implements FfiTransport {
  private sink: ((completion: FfiCompletion) => void) | null = null;
  private readonly aborted = new Set<DelegationId>();

  constructor(private readonly handlers: Record<string, FfiHandler>) {}

  onComplete(sink: (completion: FfiCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: FfiCall): void {
    const handler = this.handlers[call.key];
    const sink = this.sink;
    if (sink === null) {
      throw new Error("InProcessFfiTransport.dispatch called before onComplete registered a sink");
    }
    void (async () => {
      try {
        const value =
          handler === undefined
            ? Promise.reject(new Error(`no external handler for key "${call.key}"`))
            : handler(call.argument);
        const resolved = await value;
        if (this.aborted.delete(call.delegation)) {
          sink({ delegation: call.delegation, outcome: { kind: "cancelled" } });
          return;
        }
        sink({ delegation: call.delegation, outcome: { kind: "result", value: resolved } });
      } catch (error) {
        if (this.aborted.delete(call.delegation)) {
          sink({ delegation: call.delegation, outcome: { kind: "cancelled" } });
          return;
        }
        sink({
          delegation: call.delegation,
          outcome: {
            kind: "error",
            message: error instanceof Error ? error.message : String(error),
          },
        });
      }
    })();
  }

  abort(delegation: DelegationId): void {
    // In-process handlers cannot truly be interrupted, so "abort" means: drop whatever the handler returns
    // and report `cancelled` instead. The confirmation re-enters serially through the sink.
    this.aborted.add(delegation);
  }
}
