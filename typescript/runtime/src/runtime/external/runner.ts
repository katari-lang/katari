// The FFI transport — the `ffi` reactor's private port to the real external-handler process (a subprocess
// sidecar). An external call reaches the ffi reactor as a `delegate`; the reactor `dispatch`es it here and
// suspends, and a later `FfiCompletion` (delivered to the registered sink, which feeds the ffi reactor's
// turn) becomes the call's `delegateAck` / `escalate` / `terminateAck`. Behind this interface sits the real
// process implementation, injected by the host; the ffi reactor never sees it. One transport per project
// actor (each needs its own sinks).
//
// The transport is bidirectional beyond dispatch/completion: a running handler can ask the runtime to call
// another agent (`FfiInnerDelegate`, delivered to the delegate sink and turned into an ordinary `delegate`
// event by the ffi reactor), and the runtime settles it back with `deliverDelegateResult` once that inner
// delegation resolves. Inner calls are correlated by a sidecar-minted `call` token; the outer call by its
// `delegation` id — the same id core's external proxy thread holds.
//
// `dispatch` is fire-and-forget: the result is asynchronous and arrives via the sink, so a completion always
// re-enters through the actor's serial mailbox and never races a turn in flight. The in-flight call is
// durable as the ffi reactor's `ffi_instances` row (key + argument), so recovery re-dispatches from there.

import type { Json } from "@katari-lang/types";
import type { DelegationId, ProjectId, SnapshotId } from "../ids.js";
import type { DelegateOutcome } from "./sidecar-protocol.js";

/** One external dispatch: the call's `delegation`, the handler `key`, and the argument. The argument is
 *  plain `Json` — the ffi reactor converts the engine's `Value` at this seam, so the transport and the
 *  sidecar only ever see plain values (the same wire form as the HTTP boundary). */
export interface FfiCall {
  projectId: ProjectId;
  delegation: DelegationId;
  /** The snapshot whose compiled sidecar bundle hosts this handler — the transport spawns that bundle. */
  snapshot: SnapshotId;
  /** The opaque dispatch key the handler interprets (the external block's `key`). */
  key: string;
  argument: Json | null;
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
    | { kind: "result"; value: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

/** One inner agent call a running handler asked for, fed to the ffi reactor's delegate sink. `delegation`
 *  is the in-flight parent call it originates from; `call` is the sidecar's own correlation token (echoed
 *  back on the result). `agent` is a qualified agent name (`core`) or an external key (`ffi` / `http`);
 *  `reactor` defaults to `core` when absent. */
export interface FfiInnerDelegate {
  delegation: DelegationId;
  call: string;
  agent: string;
  reactor?: string;
  argument: Json | null;
}

/** The settled outcome of one inner agent call, handed back to the transport for delivery to the sidecar. */
export interface FfiInnerResult {
  delegation: DelegationId;
  call: string;
  outcome: DelegateOutcome;
}

export interface FfiTransport {
  /** Register the sink completions are delivered to (the ffi reactor's mailbox feed). Called once. */
  onComplete(sink: (completion: FfiCompletion) => void): void;
  /** Register the sink a handler's inner agent calls are delivered to. Called once. */
  onDelegate(sink: (request: FfiInnerDelegate) => void): void;
  /** Dispatch a call. Fire-and-forget — the outcome arrives later via the sink. */
  dispatch(call: FfiCall): void;
  /** Abort an in-flight call (its proxy is being cancelled). Fire-and-forget: once the underlying process has
   *  actually stopped, report it via the sink as `cancelled` so the reactor can `terminateAck` gracefully. */
  abort(delegation: DelegationId): void;
  /** Settle one inner agent call back to the sidecar. Fire-and-forget; delivery to a process that is already
   *  gone is dropped (the crash path fails the parent call independently). */
  deliverDelegateResult(result: FfiInnerResult): void;
}

/** The seam default: no real process is configured, so dispatching one is an error. A host swaps in a
 *  subprocess-backed transport. Kept so a runtime with no FFI configured fails loudly, not silently. */
export class StubFfiTransport implements FfiTransport {
  onComplete(): void {
    // No completions are ever produced.
  }
  onDelegate(): void {
    // No handler ever runs, so no inner call is ever produced.
  }
  dispatch(call: FfiCall): void {
    throw new Error(
      `no external process configured for FFI key "${call.key}" (inject a real FfiTransport)`,
    );
  }
  abort(): void {
    // Nothing in flight.
  }
  deliverDelegateResult(): void {
    // No handler ever runs, so there is nothing to deliver to.
  }
}

/** The context an in-process FFI handler gets alongside its argument: the inner agent-call channel the real
 *  port exposes (plain `Json` in and out; `reactor` defaults to `core`). */
export interface FfiHandlerContext {
  call(agent: string, argument?: Json | null, options?: { reactor?: string }): Promise<Json>;
}

/** A handler an in-process external call runs against its (plain `Json`) argument (the test / dev injection
 *  point). The same plain-value model the real sidecar's handlers see. */
export type FfiHandler = (
  argument: Json | null,
  context: FfiHandlerContext,
) => Json | Promise<Json>;

/**
 * An in-process transport backed by a handler map — the injection seam exercised in tests and usable for a
 * pure-JS FFI without a subprocess. `dispatch` runs the handler off the current turn and delivers the
 * outcome to the sink, so completions re-enter serially exactly like the real transport. A handler's
 * `context.call` goes out through the delegate sink and suspends on an in-memory pending entry that
 * `deliverDelegateResult` settles — the same shape the real port implements over stdio.
 */
export class InProcessFfiTransport implements FfiTransport {
  private sink: ((completion: FfiCompletion) => void) | null = null;
  private delegateSink: ((request: FfiInnerDelegate) => void) | null = null;
  private readonly aborted = new Set<DelegationId>();
  /** Delegations with a handler currently running — so `abort` can tell a live call (drop its outcome) from
   *  one with no live work (a recovery abort of a call whose in-process work is gone → confirm straight away). */
  private readonly live = new Set<DelegationId>();
  /** Pending inner agent calls, keyed by their token; an abort of the parent call rejects its entries so an
   *  awaiting handler unwinds instead of hanging on an answer that will never come. */
  private readonly pendingCalls = new Map<
    string,
    { delegation: DelegationId; resolve: (value: Json) => void; reject: (error: Error) => void }
  >();

  constructor(private readonly handlers: Record<string, FfiHandler>) {}

  onComplete(sink: (completion: FfiCompletion) => void): void {
    this.sink = sink;
  }

  onDelegate(sink: (request: FfiInnerDelegate) => void): void {
    this.delegateSink = sink;
  }

  dispatch(call: FfiCall): void {
    const handler = this.handlers[call.key];
    const sink = this.sink;
    if (sink === null) {
      throw new Error("InProcessFfiTransport.dispatch called before onComplete registered a sink");
    }
    this.live.add(call.delegation);
    void (async () => {
      try {
        const value =
          handler === undefined
            ? Promise.reject(new Error(`no external handler for key "${call.key}"`))
            : handler(call.argument, this.contextFor(call.delegation));
        const resolved = await value;
        this.live.delete(call.delegation);
        if (this.aborted.delete(call.delegation)) {
          sink({ delegation: call.delegation, outcome: { kind: "cancelled" } });
          return;
        }
        sink({ delegation: call.delegation, outcome: { kind: "result", value: resolved } });
      } catch (error) {
        this.live.delete(call.delegation);
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
    // Whatever the handler still awaits from an inner call is moot: reject it so the handler unwinds (the
    // rejection races the runtime's own `cancelled` results for the terminated children — first one wins).
    this.rejectPendingCalls(delegation, new Error("the call was cancelled"));
    if (this.live.has(delegation)) {
      // In-process handlers cannot truly be interrupted, so "abort" means: drop whatever the handler returns
      // and report `cancelled` instead. The confirmation re-enters serially through the sink when it resolves.
      this.aborted.add(delegation);
      return;
    }
    // No live handler — a recovery abort of a call whose in-process work is gone. Confirm the teardown at once
    // (harmless if a real completion also lands: the reactor drops the call on the first, ignores the rest).
    this.sink?.({ delegation, outcome: { kind: "cancelled" } });
  }

  deliverDelegateResult(result: FfiInnerResult): void {
    const pending = this.pendingCalls.get(result.call);
    if (pending === undefined) return; // already settled (an abort rejection), or a stale token
    this.pendingCalls.delete(result.call);
    switch (result.outcome.kind) {
      case "result":
        pending.resolve(result.outcome.value);
        return;
      case "error":
        pending.reject(new Error(result.outcome.message));
        return;
      case "cancelled":
        pending.reject(new Error("the call was cancelled"));
        return;
    }
  }

  private contextFor(delegation: DelegationId): FfiHandlerContext {
    return {
      call: (agent, argument = null, options) => {
        const delegateSink = this.delegateSink;
        if (delegateSink === null) {
          return Promise.reject(
            new Error("InProcessFfiTransport: no delegate sink registered (onDelegate not wired)"),
          );
        }
        // Unique across transport instances (a fresh "process"), not just within one: the runtime's bridge
        // rows are durable, so a stale bridge from a previous instance still delivers under its old token —
        // a counter would collide with this instance's first calls.
        const token = crypto.randomUUID();
        return new Promise<Json>((resolve, reject) => {
          this.pendingCalls.set(token, { delegation, resolve, reject });
          delegateSink({
            delegation,
            call: token,
            agent,
            ...(options?.reactor !== undefined ? { reactor: options.reactor } : {}),
            argument,
          });
        });
      },
    };
  }

  private rejectPendingCalls(delegation: DelegationId, error: Error): void {
    for (const [token, pending] of this.pendingCalls) {
      if (pending.delegation === delegation) {
        this.pendingCalls.delete(token);
        pending.reject(error);
      }
    }
  }
}
