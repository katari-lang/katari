// ExternalCallReactor: the shared base for the reactors that own external *callee* calls over a transport —
// `ffi` (the sidecar) and `http` (the built-in client). Both receive a call as a `delegate` routed from
// core's `ExternalThread` proxy, dispatch it through their transport, and turn the transport's completion
// into the call's `delegateAck` (result), an `escalate` (a no-result error → a panic), or a `terminateAck`
// (an abort confirmed). The whole per-delegation callee-instance lifecycle — the call map, the caller it
// replies to, the running / cancelling / awaitingAnswer state machine, the envelope + ext persistence, and
// the at-most-once-shaped recovery — lives here once; a concrete reactor supplies only its transport-specific
// bits (how to dispatch / abort / settle an inner call, and how to read / write its ext row) plus a per-call
// payload.
//
// A call is also a *caller*: its handler can ask the runtime to call another agent (an inner delegation —
// the generic agent-call channel). The base owns that whole protocol too, symmetric to a core instance's
// sub-calls:
//   - `openInnerDelegation` issues an ordinary `delegate` (caller = the call's instance; the base reactor
//     opens the caller-owned row), correlated to the transport's `call` token in the durable `innerCalls`
//     bridge so a settled result still finds its consumer after a warm reset.
//   - a child's `delegateAck` / `terminateAck` retires the row (base), re-owns the result's resources onto
//     the call's instance, and stages a post-commit delivery through the concrete's `deliverInnerOutcome`.
//   - a child's `escalate` is proxied UP under the call's own delegation with a fresh escalation id (the
//     `relays` bridge, durable on the call row), and the answering `escalateAck` is proxied back DOWN —
//     the transport never sees escalations, so a sidecar handler needs no escalation protocol of its own.
//   - a `terminate` from above is distributed to the call's live children, and the upward `terminateAck`
//     waits until the transport confirmed AND every child drained (the graceful-cancel barrier, exactly
//     like a core instance's cancel cascade).
//
// A call's lifecycle: running (transport in flight) → result / error / cancel. A completion that lands while
// the callee still has live children is HELD (in memory — it is reproducible via a recovery re-dispatch) and
// the children are cancelled first, so a resolved call never leaves in-transit resources behind. On an error
// the call does not finish — like a panicking sub-call it escalates the panic and waits (`awaitingAnswer`)
// for either an `escalateAck` (a handler caught it — the answer becomes the result) or a `terminate`
// (unhandled — the run is failing). The process/request has stopped, so that wait needs no transport.

import type { Json } from "@katari-lang/types";
import { PANIC_REQUEST } from "../engine/common.js";
import type { DelegateTarget, ExternalEvent, ReactorName } from "../event/types.js";
import {
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  newEscalationId,
  newInstanceId,
} from "../ids.js";
import { jsonToValue } from "../value/codec.js";
import type { Value } from "../value/types.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { Reactor } from "./reactor.js";

/** The `external` delegate target (the only kind that routes to a call reactor) — the shape `openPayload`
 *  reads a fresh call's transport parameters from. */
export type ExternalTarget = Extract<DelegateTarget, { kind: "external" }>;

/** The lifecycle state of an in-flight call: `running` (transport in flight), `cancelling` (aborting, awaiting
 *  the transport's stop and the children's drain), or `awaitingAnswer` (transport errored, panic escalated,
 *  awaiting a caught-panic answer or the run's terminate). */
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

/** One escalation this reactor is proxying upward for a call: the outer id it re-raised the ask under (the
 *  row key), and the child leg its answer descends to. Durable on the call's ext row, so an in-flight
 *  answer still routes down after a restart. */
export interface EscalationRelayRow {
  escalation: EscalationId;
  child: DelegationId;
  childEscalation: EscalationId;
}

/** One inner delegation's transport correlation: the delegation the base opened, and the transport's own
 *  `call` token its settled outcome is delivered under. Durable on the call's ext row, so a result landing
 *  after a warm reset still reaches its consumer (only a transport-process death makes it stale — then the
 *  delivery is dropped and the re-dispatched handler issues fresh calls). */
export interface InnerCallRow {
  delegation: DelegationId;
  call: string;
}

/** A settled inner delegation on its way to the transport: the parent call's `delegation`, the transport's
 *  `call` token, and the outcome (a result still as an engine `Value` — the concrete lowers it at its own
 *  boundary, e.g. revealing secrets to the FFI sidecar). */
export interface InnerDelivery {
  delegation: DelegationId;
  call: string;
  outcome:
    | { kind: "result"; value: Value }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

/** One in-flight call's state, keyed by its delegation. Its instance id (the issuer of its replies) and its
 *  caller (the reply-to) are NOT here — they are the received-delegation edge, held once in the base
 *  `handled` index (added / dropped alongside this entry). `relays` is durable (the ext row); the two
 *  hold-state fields are in-memory only — both are reproducible (`transportSettled` by re-aborting on
 *  recovery, `pendingOutcome` by re-dispatching the handler). */
interface Call<Payload> {
  status: CallStatus;
  payload: Payload;
  relays: Map<EscalationId, { child: DelegationId; escalation: EscalationId }>;
  /** While cancelling: whether the transport confirmed the abort (the other half of the ack barrier). */
  transportSettled: boolean;
  /** A completion that landed while children were still live — applied once they drain. */
  pendingOutcome: ExternalCompletion["outcome"] | undefined;
}

/** One reloaded call a concrete reactor's `loadCallRows` yields (envelope ⋈ its ext row). */
export interface LoadedCall<Payload> {
  delegation: DelegationId;
  instance: InstanceId;
  caller: ReactorName;
  status: CallStatus;
  payload: Payload;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

/** The fields a concrete reactor persists for one call (its ext row), supplied by the base. The caller
 *  (reply-to) is NOT here — it is the instance's ambient on the generic envelope; the ext row is the
 *  transport payload + status plus the two inner-delegation bridges. */
export interface CallRow<Payload> {
  instance: InstanceId;
  delegation: DelegationId;
  status: CallStatus;
  payload: Payload;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

export abstract class ExternalCallReactor<Payload> extends Reactor {
  /** In-flight calls (warm SoT) keyed by their delegation, plus the per-turn dirty set `persist` upserts and
   *  the instance ids of calls resolved this turn (their envelopes are dropped, cascading the ext row). */
  private readonly calls = new Map<DelegationId, Call<Payload>>();
  /** The reverse of the base received edge: a call's instance back to its delegation — how an inner
   *  delegation's reply (whose base-resolved context names the caller *instance*) finds its parent call. */
  private readonly callByInstance = new Map<InstanceId, DelegationId>();
  /** The durable inner-call bridge: an inner delegation to the transport token its outcome settles. */
  private readonly innerCalls = new Map<DelegationId, { parent: DelegationId; call: string }>();
  /** Outcomes settled this turn, delivered to the transport strictly post-commit (durable-first). */
  private pendingDeliveries: InnerDelivery[] = [];
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

  /** Deliver one settled inner delegation to the transport (strictly post-commit). Default no-op: a reactor
   *  whose transport never opens inner delegations (http) never has one staged. */
  protected deliverInnerOutcome(_delivery: InnerDelivery): void {}

  /** The instance handling `delegation`, or `undefined` — for a concrete reactor that owns per-call resources
   *  (an ffi call's produced blob) to attribute them to the right instance. Reads the base received edge. */
  protected callInstance(delegation: DelegationId): InstanceId | undefined {
    return this.handledInstanceOf(delegation);
  }

  /** The transport payload of a live call — a concrete reactor reads a fresh inner delegation's ambient
   *  (e.g. the snapshot the parent call was dispatched against) from it. */
  protected payloadOf(delegation: DelegationId): Payload | undefined {
    return this.calls.get(delegation)?.payload;
  }

  /** The instance + caller (reply-to) of a live call, read from the base received-delegation edge. Present for
   *  any delegation this reactor still holds a `calls` entry for — the edge and the entry are added (delegate)
   *  and dropped (resolve) together, so a missing edge here is a bug, surfaced loudly rather than papered over. */
  private routeOf(delegation: DelegationId): { instance: InstanceId; caller: ReactorName } {
    const instance = this.handledInstanceOf(delegation);
    const caller = this.handledCallerOf(delegation);
    if (instance === undefined || caller === undefined) {
      throw new Error(`${this.name} holds a call for ${delegation} with no received edge (bug)`);
    }
    return { instance, caller };
  }

  // ─── inner delegations (the callee calling other agents) ────────────────────────────────────────

  /** Open an inner delegation from a live call: issue an ordinary `delegate` with the call's instance as its
   *  caller (the base opens the caller-owned row) and bridge it to the transport's `call` token. Returns the
   *  delegation id, or `null` when the call cannot accept new work (gone, cancelling, or already settled) —
   *  the concrete then fails the token back to the transport directly. */
  protected openInnerDelegation(
    parent: DelegationId,
    target: DelegateTarget,
    to: ReactorName,
    argument: Value | null,
    call: string,
  ): DelegationId | null {
    const parentCall = this.calls.get(parent);
    if (
      parentCall === undefined ||
      parentCall.status !== "running" ||
      parentCall.pendingOutcome !== undefined
    ) {
      return null;
    }
    const { instance } = this.routeOf(parent);
    this.turnInstance = instance;
    const delegation = newDelegationId();
    this.innerCalls.set(delegation, { parent, call });
    this.dirty.add(parent);
    this.send({ kind: "delegate", delegation, target, argument, from: this.name, to });
    return delegation;
  }

  /** An inner delegation returned: the base has retired the caller-owned row; re-own the result's resources
   *  onto the call's instance (they are reclaimed at its drop unless its own result ascends them), stage the
   *  post-commit delivery, and settle the call if this was the last thing it waited on. */
  protected onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const parent =
      context.caller === undefined ? undefined : this.callByInstance.get(context.caller);
    if (parent === undefined || context.caller === undefined) return; // the call is gone — an undeliverable result
    this.turnInstance = context.caller;
    this.reownIncoming(event.value, context.caller);
    this.stageInnerDelivery(parent, event.delegation, { kind: "result", value: event.value });
    this.maybeSettle(parent);
  }

  /** An inner delegation's cancel confirmed (the terminate this reactor distributed): the base has retired
   *  the row; tell the transport (so an awaiting handler unwinds) and settle the call if fully drained. */
  protected onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const parent =
      context.caller === undefined ? undefined : this.callByInstance.get(context.caller);
    if (parent === undefined || context.caller === undefined) return;
    this.turnInstance = context.caller;
    this.stageInnerDelivery(parent, event.delegation, { kind: "cancelled" });
    this.maybeSettle(parent);
  }

  /** An inner delegation escalated. A PANIC is the inner call *failing*: the callee's handler — the call's
   *  immediate caller — handles it with its own try/catch (core's `handle … with panic` analog), so it
   *  settles the inner call as an error and the dead callee is cancelled (caught panics never resume, like
   *  a handle that catches-and-breaks); an uncaught error then re-raises through the handler's own failure.
   *  Any other ask (a user-facing request, a control escape) is beyond the handler — it is proxied UP under
   *  the call's own delegation with a fresh escalation id, bridged in `relays` so the answer descends the
   *  same path; the transport never sees it. A cancelling call drops the ask (its children are being torn
   *  down anyway). */
  protected onEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const parent =
      context.caller === undefined ? undefined : this.callByInstance.get(context.caller);
    if (parent === undefined) return; // the raiser's call is gone; the child is being torn down independently
    const call = this.calls.get(parent);
    if (call === undefined || call.status === "cancelling") return;
    const { instance, caller } = this.routeOf(parent);
    this.turnInstance = instance;
    if (event.ask.kind === "request" && event.ask.request === PANIC_REQUEST) {
      this.stageInnerDelivery(parent, event.delegation, {
        kind: "error",
        message: panicMessageOf(event.ask.argument),
      });
      // Cancel the panicking callee (its delegation row is still live — an acceptance-surface panic never
      // acks, a raised one suspends awaiting an answer that will never come). One already cancelling (or
      // already retired) needs no second terminate.
      const child = this.issuedDelegationsOf(instance).find(
        (row) => row.delegation === event.delegation,
      );
      if (child !== undefined && child.state === "running") {
        this.send({
          kind: "terminate",
          delegation: event.delegation,
          from: this.name,
          to: child.peer,
        });
      }
      return;
    }
    const outer = newEscalationId();
    call.relays.set(outer, { child: event.delegation, escalation: event.escalation });
    this.dirty.add(parent);
    this.send({
      kind: "escalate",
      delegation: parent,
      escalation: outer,
      ask: event.ask,
      from: this.name,
      to: caller,
    });
  }

  // ─── the shared callee lifecycle ─────────────────────────────────────────────────────────────────

  /** A `delegate` opened a call: record the received-delegation edge (instance + summoner) in the base, then
   *  hold only the transport status + payload locally. The transport dispatch is a post-commit side effect. */
  protected onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): void {
    if (event.target.kind !== "external") return; // only external targets route here
    const instance = newInstanceId();
    this.acceptDelegation(event.delegation, instance, event.from);
    this.callByInstance.set(instance, event.delegation);
    this.put(event.delegation, {
      status: "running",
      payload: this.openPayload(event.target, event.argument),
      relays: new Map(),
      transportSettled: false,
      pendingOutcome: undefined,
    });
  }

  /** A `terminate` reached the call: move it to `cancelling` (the transport abort runs post-commit; a call
   *  whose transport already stopped — `awaitingAnswer` — counts as settled at once), distribute the cancel
   *  to its live children, and ack upward only once the transport AND every child confirmed. */
  protected onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): void {
    const call = this.calls.get(event.delegation);
    if (call === undefined) {
      // No such call — it resolved concurrently (its ack is in flight). Confirm anyway so the caller's
      // cancel cascade completes; a caller whose proxy has meanwhile resolved ignores a stray ack.
      this.send({
        kind: "terminateAck",
        delegation: event.delegation,
        from: this.name,
        to: event.from,
      });
      return;
    }
    if (call.status === "cancelling") return;
    const { instance } = this.routeOf(event.delegation);
    this.turnInstance = instance;
    // An errored call (`awaitingAnswer`) has no transport work left to confirm; a held completion is moot.
    call.transportSettled = call.status === "awaitingAnswer";
    call.pendingOutcome = undefined;
    call.status = "cancelling";
    this.dirty.add(event.delegation);
    this.terminateChildren(instance);
    this.maybeSettle(event.delegation);
  }

  /** The answer to an escalation under this call arrived. A relayed one (a child's ask this reactor proxied
   *  up) descends to that child; otherwise it is the answer to the call's own error panic — a handler caught
   *  it, and the answer becomes the call's result. */
  protected onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
    _context: { raiser: InstanceId | undefined },
  ): void {
    const call = this.calls.get(event.delegation);
    if (call === undefined) return;
    const relay = call.relays.get(event.escalation);
    if (relay !== undefined) {
      call.relays.delete(event.escalation);
      this.dirty.add(event.delegation);
      const to = this.issuedPeerOf(relay.child);
      if (to === undefined) return; // the child retired while the ask was open (cancelled) — the answer is moot
      const { instance } = this.routeOf(event.delegation);
      this.turnInstance = instance;
      this.send({
        kind: "escalateAck",
        delegation: relay.child,
        escalation: relay.escalation,
        value: event.value,
        from: this.name,
        to,
      });
      return;
    }
    if (call.status !== "awaitingAnswer") return;
    const { instance, caller } = this.routeOf(event.delegation);
    this.turnInstance = instance;
    this.send({
      kind: "delegateAck",
      delegation: event.delegation,
      value: event.value,
      from: this.name,
      to: caller,
    });
    this.drop(event.delegation);
  }

  /** A transport completion for one call (the reactor's ephemeral inbound, fed through the substrate). For a
   *  cancelling call any completion confirms the transport's half of the abort. Otherwise the outcome is
   *  held; children the callee left running are cancelled (their results can no longer be observed), and the
   *  call settles once drained — immediately when it has none. */
  complete(completion: ExternalCompletion): void {
    const call = this.calls.get(completion.delegation);
    if (call === undefined) return; // a late completion for a call already resolved
    const { instance } = this.routeOf(completion.delegation);
    this.turnInstance = instance;
    if (call.status === "cancelling") {
      call.transportSettled = true;
      this.maybeSettle(completion.delegation);
      return;
    }
    call.pendingOutcome = completion.outcome;
    this.terminateChildren(instance);
    this.maybeSettle(completion.delegation);
  }

  /** Cancel every still-running inner delegation of `instance` (one already cancelling has its terminate in
   *  flight — from the turn that moved it, replayed from the outbox after a crash). */
  private terminateChildren(instance: InstanceId): void {
    for (const child of this.issuedDelegationsOf(instance)) {
      if (child.state !== "running") continue;
      this.send({
        kind: "terminate",
        delegation: child.delegation,
        from: this.name,
        to: child.peer,
      });
    }
  }

  /** Settle `delegation` if nothing is outstanding: all children drained, and — when cancelling — the
   *  transport confirmed. Applies the held outcome (result → delegateAck, error → the panic escalation +
   *  `awaitingAnswer`, cancelled → terminateAck) or completes the cancel barrier. Idempotent per trigger:
   *  each child ack / transport confirmation re-checks. */
  private maybeSettle(delegation: DelegationId): void {
    const call = this.calls.get(delegation);
    if (call === undefined) return;
    const { instance, caller } = this.routeOf(delegation);
    if (this.issuedDelegationsOf(instance).length > 0) return; // children still winding down
    if (call.status === "cancelling") {
      if (!call.transportSettled) return;
      this.send({ kind: "terminateAck", delegation, from: this.name, to: caller });
      this.drop(delegation);
      return;
    }
    const outcome = call.pendingOutcome;
    if (outcome === undefined) return;
    call.pendingOutcome = undefined;
    switch (outcome.kind) {
      case "result":
        this.send({
          kind: "delegateAck",
          delegation,
          value: jsonToValue(outcome.value),
          from: this.name,
          to: caller,
        });
        this.drop(delegation);
        return;
      case "cancelled":
        this.send({ kind: "terminateAck", delegation, from: this.name, to: caller });
        this.drop(delegation);
        return;
      case "error":
        // A no-result error is a panic: escalate it to the caller. Unhandled, it fails the run; if a handler
        // catches it, the escalateAck becomes this call's result (so the call waits, awaitingAnswer).
        this.raisePanic(delegation, outcome.message, caller);
        call.status = "awaitingAnswer";
        this.dirty.add(delegation);
        return;
    }
  }

  /** Bridge a settled inner delegation to its transport token and stage the post-commit delivery. A missing
   *  bridge is an orphan — an inner delegation whose transport process died (the bridge outlived its
   *  consumer); its outcome is dropped, and its resources were already re-owned onto the call. */
  private stageInnerDelivery(
    parent: DelegationId,
    child: DelegationId,
    outcome: InnerDelivery["outcome"],
  ): void {
    const bridge = this.innerCalls.get(child);
    if (bridge === undefined) return;
    this.innerCalls.delete(child);
    this.dirty.add(parent);
    this.pendingDeliveries.push({ delegation: parent, call: bridge.call, outcome });
  }

  /** Dispatch / abort the transport and deliver settled inner calls strictly after the turn commits
   *  (durable-first): a freshly opened call is dispatched, a now-cancelling one is aborted, and the
   *  deliveries this turn staged go out. A call resolved this turn (dropped) does neither. */
  afterCommit(event: ExternalEvent): void {
    if (event.kind === "delegate" && event.target.kind === "external") {
      const call = this.calls.get(event.delegation);
      if (call !== undefined) this.dispatch(event.delegation, call.payload, false);
    } else if (event.kind === "terminate") {
      if (this.calls.get(event.delegation)?.status === "cancelling") this.abort(event.delegation);
    }
    const deliveries = this.pendingDeliveries;
    this.pendingDeliveries = [];
    for (const delivery of deliveries) this.deliverInnerOutcome(delivery);
  }

  /** Write the calls this turn touched as own-kind instances (envelope + ext), dropping resolved ones (their
   *  envelope drop cascades the ext). The base additionally flushes the caller-owned rows of the calls'
   *  inner delegations. The envelope status collapses `awaitingAnswer` to the `running` instance lifecycle
   *  (alive, waiting); the ext row carries the precise status plus the two inner-delegation bridges. */
  async persist(tx: PersistenceTx): Promise<void> {
    const live = [...this.dirty].flatMap((delegation) => {
      const call = this.calls.get(delegation);
      // Instance + caller come from the base received edge (present alongside a live call).
      return call === undefined ? [] : [{ delegation, call, route: this.routeOf(delegation) }];
    });
    for (const { delegation, call, route } of live)
      this.markInstance(route.instance, {
        delegationId: delegation,
        // The caller (reply-to) is the instance's ambient, written on the generic envelope here — not
        // repeated in the concrete ext row.
        callerReactor: route.caller,
        status: call.status === "cancelling" ? "cancelling" : "running",
      });
    for (const instanceId of this.droppedInstances) this.markInstanceDropped(instanceId);
    await this.persistBase(tx.base);
    for (const { delegation, call, route } of live)
      await this.persistCallRow(tx, {
        instance: route.instance,
        delegation,
        status: call.status,
        payload: call.payload,
        relays: [...call.relays].map(([escalation, relay]) => ({
          escalation,
          child: relay.child,
          childEscalation: relay.escalation,
        })),
        innerCalls: this.innerCallRowsOf(delegation),
      });
    this.dirty.clear();
    this.droppedInstances = [];
  }

  /** Reload the in-flight calls on reactivation and resume the transport uniformly: a `running` call
   *  re-dispatches (ffi re-runs its handler; http fails at-most-once), a `cancelling` call re-aborts (the
   *  transport confirms with a synthesised `cancelled` — the request is gone; its children's terminates
   *  replay from the outbox), an `awaitingAnswer` call just waits (its request already stopped; the core
   *  side drives the escalation's resolution). The inner-delegation bridges reload with each call. */
  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
    for (const row of await this.loadCallRows(loader)) {
      // Re-seed the base received edge (instance + summoner) and the local transport status + payload.
      this.acceptDelegation(row.delegation, row.instance, row.caller);
      this.callByInstance.set(row.instance, row.delegation);
      this.calls.set(row.delegation, {
        status: row.status,
        payload: row.payload,
        relays: new Map(
          row.relays.map((relay) => [
            relay.escalation,
            { child: relay.child, escalation: relay.childEscalation },
          ]),
        ),
        transportSettled: false,
        pendingOutcome: undefined,
      });
      for (const inner of row.innerCalls) {
        this.innerCalls.set(inner.delegation, { parent: row.delegation, call: inner.call });
      }
      if (row.status === "running") this.dispatch(row.delegation, row.payload, true);
      else if (row.status === "cancelling") this.abort(row.delegation);
    }
  }

  reset(): void {
    super.reset();
    this.calls.clear();
    this.callByInstance.clear();
    this.innerCalls.clear();
    this.pendingDeliveries = [];
    this.dirty.clear();
    this.droppedInstances = [];
    this.turnInstance = undefined;
  }

  private innerCallRowsOf(parent: DelegationId): InnerCallRow[] {
    const rows: InnerCallRow[] = [];
    for (const [delegation, bridge] of this.innerCalls) {
      if (bridge.parent === parent) rows.push({ delegation, call: bridge.call });
    }
    return rows;
  }

  private put(delegation: DelegationId, call: Call<Payload>): void {
    this.calls.set(delegation, call);
    this.dirty.add(delegation);
  }

  private drop(delegation: DelegationId): void {
    const instance = this.handledInstanceOf(delegation);
    if (instance !== undefined) {
      this.droppedInstances.push(instance);
      this.callByInstance.delete(instance);
    }
    // Stale inner-call bridges (an orphan child still running as its parent resolves) die with the call.
    for (const [child, bridge] of this.innerCalls) {
      if (bridge.parent === delegation) this.innerCalls.delete(child);
    }
    this.calls.delete(delegation);
    this.dropHandled(delegation);
    this.dirty.delete(delegation);
  }
}

/** The `{ msg }` a panic escalation carries, as the inner call's error message. */
function panicMessageOf(argument: Value | null): string {
  if (argument !== null && argument.kind === "record") {
    const message = argument.fields.msg;
    if (message !== undefined && message.kind === "string") return message.value;
  }
  return "the callee panicked";
}
