// ExternalCallReactor: the shared base for the reactors that own external *callee* calls over a transport —
// `ffi` (the sidecar) and `http` (the built-in client). Both receive a call as a `delegate` routed from
// core's `ExternalThread` proxy, dispatch it through their transport, and turn the transport's completion
// into the call's `delegateAck` (result), an `escalate` (a no-result error → a panic), or a `terminateAck`
// (an abort confirmed). The whole per-delegation callee-instance lifecycle — the call map, the caller it
// replies to, the running / cancelling / awaitingAnswer state machine, the envelope + ext persistence, and
// the at-most-once-shaped recovery — lives here once; a concrete reactor supplies only its transport-specific
// bits (how to dispatch / abort, and how to read / write its ext row) plus a per-call payload.
//
// A call's lifecycle: running (transport in flight) → result / error / cancel. On an error the call does not
// finish — like a panicking sub-call it escalates the panic and waits (`awaitingAnswer`) for either an
// `escalateAck` (a handler caught it — the answer becomes the result) or a `terminate` (unhandled — the run
// is failing). The process/request has stopped, so that wait needs no transport.

import type { Json } from "@katari-lang/types";
import type { DelegateTarget, ExternalEvent, ReactorName } from "../event/types.js";
import { type DelegationId, type InstanceId, newInstanceId } from "../ids.js";
import { jsonToValue } from "../value/codec.js";
import type { Value } from "../value/types.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { Reactor } from "./reactor.js";

/** The `external` delegate target (the only kind that routes to a call reactor) — the shape `openPayload`
 *  reads a fresh call's transport parameters from. */
export type ExternalTarget = Extract<DelegateTarget, { kind: "external" }>;

/** The lifecycle state of an in-flight call: `running` (transport in flight), `cancelling` (aborting, awaiting
 *  the transport's stop), or `awaitingAnswer` (transport errored, panic escalated, awaiting a caught-panic
 *  answer or the run's terminate). */
export type CallStatus = "running" | "cancelling" | "awaitingAnswer";

/** A completion fed back from a transport (the ffi / http completion shape, structurally shared): a `result`
 *  (→ delegateAck), an `error` (no result → a panic the reactor escalates), or a `cancelled` confirmation
 *  (→ terminateAck, after an `abort`). A late completion for a resolved call is harmless (guarded). */
export interface ExternalCompletion {
  delegation: DelegationId;
  outcome:
    | { kind: "result"; value: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

/** One in-flight call — a per-delegation callee instance (the transport analogue of a core child instance).
 *  `instance` is its own id (the issuer stamped on the replies it produces); `caller` is the reactor that
 *  issued the delegate (its reply routes back there). `payload` is the concrete reactor's transport data. */
interface Call<Payload> {
  instance: InstanceId;
  caller: ReactorName;
  status: CallStatus;
  payload: Payload;
}

/** One reloaded call a concrete reactor's `loadCallRows` yields (envelope ⋈ its ext row). */
export interface LoadedCall<Payload> {
  delegation: DelegationId;
  instance: InstanceId;
  caller: ReactorName;
  status: CallStatus;
  payload: Payload;
}

/** The fields a concrete reactor persists for one call (its ext row), supplied by the base so the caller /
 *  status bookkeeping is written the same way for every call reactor. */
export interface CallRow<Payload> {
  instance: InstanceId;
  delegation: DelegationId;
  caller: ReactorName;
  status: CallStatus;
  payload: Payload;
}

export abstract class ExternalCallReactor<Payload> extends Reactor {
  /** In-flight calls (warm SoT) keyed by their delegation, plus the per-turn dirty set `persist` upserts and
   *  the instance ids of calls resolved this turn (their envelopes are dropped, cascading the ext row). */
  private readonly calls = new Map<DelegationId, Call<Payload>>();
  private readonly dirty = new Set<DelegationId>();
  private droppedInstances: InstanceId[] = [];
  /** The call whose turn this is — its instance is the issuer stamped on the replies it produces. */
  private turnInstance: InstanceId | undefined;

  currentTurnOwner(): InstanceId {
    if (this.turnInstance === undefined) {
      throw new Error(`${this.name}.currentTurnOwner read with no call instance (engine bug)`);
    }
    return this.turnInstance;
  }

  // ─── concrete-reactor hooks (the only transport-specific surface) ────────────────────────────────

  /** Build the per-call payload (the transport data recovery re-dispatches from) for a fresh delegate. */
  protected abstract openPayload(target: ExternalTarget, argument: Value | null): Payload;

  /** Dispatch a call to the transport. `redispatch` marks a recovery re-dispatch of a still-running call —
   *  ffi re-runs its handler (deduping on the flag); http reports an error (at-most-once, never re-sending). */
  protected abstract dispatch(
    delegation: DelegationId,
    payload: Payload,
    redispatch: boolean,
  ): void;

  /** Abort an in-flight call — a post-commit `terminate`, or a `cancelling` call recovered after a crash. The
   *  transport confirms with a `cancelled` completion (synthesising one when the request is already gone). */
  protected abstract abort(delegation: DelegationId): void;

  /** Persist one call's ext row through its own `tx` port (the base has already staged the envelope). */
  protected abstract persistCallRow(tx: PersistenceTx, row: CallRow<Payload>): Promise<void>;

  /** Read this reactor's in-flight calls (envelope ⋈ ext row) on reactivation. */
  protected abstract loadCallRows(loader: Loader): Promise<Array<LoadedCall<Payload>>>;

  /** The instance handling `delegation`, or `undefined` — for a concrete reactor that owns per-call resources
   *  (an ffi call's produced blob) to attribute them to the right instance. */
  protected callInstance(delegation: DelegationId): InstanceId | undefined {
    return this.calls.get(delegation)?.instance;
  }

  // ─── the shared lifecycle ────────────────────────────────────────────────────────────────────────

  /** React to one event a delegation routes here: a `delegate` opens a call, a `terminate` aborts one, an
   *  `escalateAck` is a caught panic's answer (→ the call's result). It never receives a `delegateAck` /
   *  `escalate` / `terminateAck` (those are the replies it sends). The transport dispatch / abort is a
   *  strictly-post-commit side effect (`afterCommit`). */
  react(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegate": {
        if (event.target.kind !== "external") return; // only external targets route here
        this.put(event.delegation, {
          instance: newInstanceId(),
          caller: event.from,
          status: "running",
          payload: this.openPayload(event.target, event.argument),
        });
        break;
      }
      case "terminate": {
        const call = this.calls.get(event.delegation);
        if (call === undefined) return;
        if (call.status === "awaitingAnswer") {
          // The request already stopped (it errored); confirm the abort straight away.
          this.turnInstance = call.instance;
          this.send({
            kind: "terminateAck",
            delegation: event.delegation,
            from: this.name,
            to: call.caller,
          });
          this.drop(event.delegation);
        } else if (call.status === "running") {
          call.status = "cancelling";
          this.dirty.add(event.delegation);
        }
        break;
      }
      case "escalateAck": {
        // A handler caught the error's panic and answered: the answer becomes the call's result.
        const call = this.calls.get(event.delegation);
        if (call === undefined || call.status !== "awaitingAnswer") return;
        this.turnInstance = call.instance;
        this.send({
          kind: "delegateAck",
          delegation: event.delegation,
          value: event.value,
          from: this.name,
          to: call.caller,
        });
        this.drop(event.delegation);
        break;
      }
    }
  }

  /** A transport completion for one call (the reactor's ephemeral inbound, fed through the substrate). For a
   *  cancelling call any completion confirms the abort; otherwise a result acks it (lifted to a Value through
   *  the shared codec), and an error escalates a panic and waits for the answer / the run's terminate. */
  complete(completion: ExternalCompletion): void {
    const call = this.calls.get(completion.delegation);
    if (call === undefined) return; // a late completion for a call already resolved
    this.turnInstance = call.instance;
    if (call.status === "cancelling") {
      this.send({
        kind: "terminateAck",
        delegation: completion.delegation,
        from: this.name,
        to: call.caller,
      });
      this.drop(completion.delegation);
      return;
    }
    switch (completion.outcome.kind) {
      case "result":
        this.send({
          kind: "delegateAck",
          delegation: completion.delegation,
          value: jsonToValue(completion.outcome.value),
          from: this.name,
          to: call.caller,
        });
        this.drop(completion.delegation);
        return;
      case "cancelled":
        this.send({
          kind: "terminateAck",
          delegation: completion.delegation,
          from: this.name,
          to: call.caller,
        });
        this.drop(completion.delegation);
        return;
      case "error":
        // A no-result error is a panic: escalate it to the caller. Unhandled, it fails the run; if a handler
        // catches it, the escalateAck becomes this call's result (so the call waits, awaitingAnswer).
        this.raisePanic(completion.delegation, completion.outcome.message, call.caller);
        call.status = "awaitingAnswer";
        this.dirty.add(completion.delegation);
        return;
    }
  }

  /** Dispatch / abort the transport strictly after the turn commits (durable-first): a freshly opened call is
   *  dispatched, a now-cancelling one is aborted. A call resolved this turn (dropped) does neither. */
  afterCommit(event: ExternalEvent): void {
    if (event.kind === "delegate" && event.target.kind === "external") {
      const call = this.calls.get(event.delegation);
      if (call !== undefined) this.dispatch(event.delegation, call.payload, false);
    } else if (event.kind === "terminate") {
      if (this.calls.get(event.delegation)?.status === "cancelling") this.abort(event.delegation);
    }
  }

  /** Write the calls this turn touched as own-kind instances (envelope + ext), dropping resolved ones (their
   *  envelope drop cascades the ext). A call reactor owns no delegations / escalations, so the base flushes
   *  none. The envelope status collapses `awaitingAnswer` to the `running` instance lifecycle (alive, waiting);
   *  the ext row carries the precise status. */
  async persist(tx: PersistenceTx): Promise<void> {
    const live = [...this.dirty].flatMap((delegation) => {
      const call = this.calls.get(delegation);
      return call === undefined ? [] : [{ delegation, call }];
    });
    for (const { delegation, call } of live)
      this.markInstance(call.instance, {
        delegationId: delegation,
        status: call.status === "cancelling" ? "cancelling" : "running",
      });
    for (const instanceId of this.droppedInstances) this.markInstanceDropped(instanceId);
    await this.persistBase(tx.base);
    for (const { delegation, call } of live)
      await this.persistCallRow(tx, {
        instance: call.instance,
        delegation,
        caller: call.caller,
        status: call.status,
        payload: call.payload,
      });
    this.dirty.clear();
    this.droppedInstances = [];
  }

  /** Reload the in-flight calls on reactivation and resume the transport uniformly: a `running` call
   *  re-dispatches (ffi re-runs its handler; http fails at-most-once), a `cancelling` call re-aborts (the
   *  transport confirms with a synthesised `cancelled` — the request is gone), an `awaitingAnswer` call just
   *  waits (its request already stopped; the core side drives the escalation's resolution). */
  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
    for (const row of await this.loadCallRows(loader)) {
      this.calls.set(row.delegation, {
        instance: row.instance,
        caller: row.caller,
        status: row.status,
        payload: row.payload,
      });
      if (row.status === "running") this.dispatch(row.delegation, row.payload, true);
      else if (row.status === "cancelling") this.abort(row.delegation);
    }
  }

  reset(): void {
    super.reset();
    this.calls.clear();
    this.dirty.clear();
    this.droppedInstances = [];
    this.turnInstance = undefined;
  }

  private put(delegation: DelegationId, call: Call<Payload>): void {
    this.calls.set(delegation, call);
    this.dirty.add(delegation);
  }

  private drop(delegation: DelegationId): void {
    const call = this.calls.get(delegation);
    if (call !== undefined) this.droppedInstances.push(call.instance);
    this.calls.delete(delegation);
    this.dirty.delete(delegation);
  }
}
