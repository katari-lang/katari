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
// re-enters through the actor's serial mailbox and never races a turn in flight.
//
// Execution is AT-MOST-ONCE: the runtime never re-runs a handler. A `recovery` dispatch (reload of a call
// that was in flight) must not start fresh work — the transport leaves a handler it still has running alone
// (a warm reset: the process survived, the completion will come), and fails one whose process is gone with
// an `error` completion (→ a panic). Retrying is a katari-level decision (`handle … with panic`), never the
// runtime's; the transport can tell the two apart because its own lifetime IS the process's lifetime.

import type { Json } from "@katari-lang/types";
import type { DelegationId, ProjectId, SnapshotId } from "../ids.js";
import type { DelegateCallee, DelegateOutcome } from "./sidecar-protocol.js";

/** The `error` a recovery dispatch fails with when the handler's process is gone — the at-most-once refusal
 *  (never a silent re-run). Surfaces as a catchable panic, so katari code decides whether to retry. */
export const INTERRUPTED_MESSAGE =
  "the external call was interrupted by a runtime restart (at-most-once: it is not re-run)";

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
}

/** The outcome of one dispatched call, fed back to the ffi reactor: a `result` (→ delegateAck), a `throw`
 *  (a typed `prelude.throw` the reactor escalates with `error` as its payload — caught by a katari-side
 *  handler), an `error` (→ a panic the reactor escalates), or a `cancelled` confirmation (→ terminateAck,
 *  after an `abort`). A late real completion for an aborted call is harmless — the reactor treats any
 *  completion of a cancelling call as its abort. */
export interface FfiCompletion {
  delegation: DelegationId;
  outcome:
    | { kind: "result"; value: Json }
    | { kind: "throw"; error: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

/** One inner agent call a running handler asked for, fed to the ffi reactor's delegate sink. `delegation`
 *  is the in-flight parent call it originates from; `call` is the sidecar's own correlation token (echoed
 *  back on the result). `callee` is either a static agent NAME (routed by reactor) or a first-class
 *  callable VALUE the handler received (resolved to a target on `core`). */
export interface FfiInnerDelegate {
  delegation: DelegationId;
  call: string;
  callee: DelegateCallee;
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
  /** Dispatch a call — always means "run it". Fire-and-forget — the outcome arrives later via the sink. */
  dispatch(call: FfiCall): void;
  /** Reconcile a reloaded in-flight call (at-most-once; never starts work): a handler this transport still
   *  has running is left alone — its completion will come (a warm reset); one whose process is gone fails
   *  with an `error` completion (`INTERRUPTED_MESSAGE`), so the caller decides whether to retry. */
  recover(delegation: DelegationId): void;
  /** Abort an in-flight call (its proxy is being cancelled). Fire-and-forget: once the underlying process has
   *  actually stopped, report it via the sink as `cancelled` so the reactor can `terminateAck` gracefully. */
  abort(delegation: DelegationId): void;
  /** Settle one inner agent call back to the sidecar. Fire-and-forget; delivery to a process that is already
   *  gone is dropped (the crash path fails the parent call independently). */
  deliverDelegateResult(result: FfiInnerResult): void;
  /** Tear the transport down (host cleanup on actor disposal — the project was deleted): kill any sidecar
   *  process and drop in-flight work. Nothing is delivered after close. */
  close(): void;
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
  recover(delegation: DelegationId): void {
    // A durable in-flight call exists but no FFI is configured — a wiring error, surfaced loudly.
    throw new Error(
      `no external process configured to recover FFI call ${delegation} (inject a real FfiTransport)`,
    );
  }
  abort(): void {
    // Nothing in flight.
  }
  deliverDelegateResult(): void {
    // No handler ever runs, so there is nothing to deliver to.
  }
  close(): void {
    // No process to kill.
  }
}

/** Thrown by an in-process FFI handler to fail ITS OWN call as a typed `prelude.throw` with `error` (plain
 *  wire `Json`) as the payload — the in-process analogue of the real port's `katari.throw`. Only for the
 *  handler's own outward throw: an inner `context.call` whose callee throws no longer rejects with this — the
 *  callee's throw proxies UP the delegation to be caught in katari, never surfacing as a JS rejection here. */
export class FfiThrow extends Error {
  constructor(readonly error: Json) {
    super(`katari throw: ${JSON.stringify(error)}`);
    this.name = "FfiThrow";
  }
}

/** The context an in-process FFI handler gets alongside its argument: the inner agent-call channel the real
 *  port exposes (plain `Json` in and out). */
export interface FfiHandlerContext {
  /** Call an agent by NAME; `reactor` defaults to `core` (`ffi` / `http` for a call reactor). */
  call(agent: string, argument?: Json | null, options?: { reactor?: string }): Promise<Json>;
  /** Call a first-class callable VALUE the handler received (its `$agent` / `$closure` / `$tool` wire
   *  JSON) — the in-process analogue of the port's `KatariAgent.call`. The runtime resolves it to a
   *  target and dispatches on `core`. */
  callValue(callable: Json, argument?: Json | null): Promise<Json>;
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
    if (this.sink === null) {
      throw new Error("InProcessFfiTransport.dispatch called before onComplete registered a sink");
    }
    const handler = this.handlers[call.key];
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
          this.emit({ delegation: call.delegation, outcome: { kind: "cancelled" } });
          return;
        }
        this.emit({ delegation: call.delegation, outcome: { kind: "result", value: resolved } });
      } catch (error) {
        this.live.delete(call.delegation);
        if (this.aborted.delete(call.delegation)) {
          this.emit({ delegation: call.delegation, outcome: { kind: "cancelled" } });
          return;
        }
        this.emit({
          delegation: call.delegation,
          outcome:
            error instanceof FfiThrow
              ? { kind: "throw", error: error.error }
              : {
                  kind: "error",
                  message: error instanceof Error ? error.message : String(error),
                },
        });
      }
    })();
  }

  recover(delegation: DelegationId): void {
    // At-most-once: never re-run. A handler this transport still has live survived a warm reset — leave it
    // alone, its completion will come. One that is gone (a fresh transport = a fresh "process") failed.
    if (!this.live.has(delegation)) {
      this.emit({ delegation, outcome: { kind: "error", message: INTERRUPTED_MESSAGE } });
    }
  }

  /** Deliver to the CURRENT sink (read at delivery time, like the real transport's reply routing): a warm
   *  reset re-registers the sink, and a completion from work that outlived the reset must reach the new one. */
  private emit(completion: FfiCompletion): void {
    this.sink?.(completion);
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
    // The inner channel settles only result / error / cancelled: a callee's OWN failure (a panic or a typed
    // `prelude.throw`) no longer settles this call — it proxies UP the delegation to be caught by a katari
    // handler above or to fail the run. So `context.call` never rejects on a callee failure; the only
    // rejections are a LOCAL bad dispatch (`error`, see `resolveInnerCall`) and a cancellation. The wire's
    // `throw` outcome is never produced here.
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
      default:
        // The inner channel never produces a `throw` (a callee's throw proxies up). A stray one is protocol
        // drift — reject loudly rather than leave the awaiting handler hanging forever.
        pending.reject(
          new Error(`unexpected inner delegateResult outcome "${result.outcome.kind}"`),
        );
        return;
    }
  }

  private contextFor(delegation: DelegationId): FfiHandlerContext {
    const sendDelegate = (callee: DelegateCallee, argument: Json | null): Promise<Json> => {
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
        delegateSink({ delegation, call: token, callee, argument });
      });
    };
    return {
      call: (agent, argument = null, options) =>
        sendDelegate(
          {
            kind: "named",
            agent,
            ...(options?.reactor !== undefined ? { reactor: options.reactor } : {}),
          },
          argument,
        ),
      callValue: (callable, argument = null) => sendDelegate({ kind: "value", callable }, argument),
    };
  }

  close(): void {
    // The in-process analogue of killing the sidecar: unwind every handler awaiting an inner call, drop the
    // live/aborted tracking, and unhook the sinks so work that outlives the close delivers nowhere.
    for (const [token, pending] of this.pendingCalls) {
      this.pendingCalls.delete(token);
      pending.reject(new Error("the transport was closed"));
    }
    this.live.clear();
    this.aborted.clear();
    this.sink = null;
    this.delegateSink = null;
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
