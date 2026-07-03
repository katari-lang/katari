// Reactor: one module on the substrate (the bus) and the *single* place the external-event delegation /
// escalation protocol is implemented, uniformly for every reactor. The base owns the ENTIRE Layer 1 lifecycle
// (the delegation / escalation rows), derived from the events that flow through it:
//
//   - `send` (final) is the one edge on the way out: as a reactor emits an event, the base records the
//     owned-edge change it implies — a `delegate` opens the caller-owned delegation, a `terminate` moves it to
//     cancelling, an `escalate` opens the raiser-owned escalation (when user-facing). A concrete reactor just
//     emits; it never opens / transitions a row itself.
//   - `react` (final) is the one edge on the way in: it resolves the edge's endpoint (caller / callee /
//     raiser), applies the owned-edge deletion an ack implies (a `delegateAck` / `terminateAck` retires the
//     caller's delegation, an `escalateAck` retires the raiser's escalation), then dispatches to the concrete's
//     per-event hook with that resolved context. The concrete's hooks only resume their payload / manage their
//     instance lifecycle — they hold no delegation / escalation state.
//
// Ownership: a delegation is owned by its *caller* (core for a sub-call, the api root for a run); an escalation
// by its *raiser* (a core instance today). Each reactor persists only its own rows (self-selected on load by
// `from = this.name`). A row lives in memory only while live; retiring it evicts it and stages a durable delete
// (a delegation is pure live routing — its outcome lives on `runs`; an answered escalation lives in the audit).
// Reactors hold no DB — the substrate opens the turn's single transaction (see the redesign doc).

import type { DelegationState } from "../../db/tables/execution.js";
import { PANIC_REQUEST, panicArgument } from "../engine/common.js";
import { THROW_REQUEST, throwArgument } from "../engine/throw-signal.js";
import type { InstanceStatus } from "../engine/types.js";
import { isUserFacingRequest } from "../escalation-filter.js";
import { type ExternalEvent, escalateValue, type ReactorName } from "../event/types.js";
import { type DelegationId, type EscalationId, type InstanceId, newEscalationId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { BaseLoader, BaseTx, PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** A caller-owned delegation row in memory (the live source of truth). `peer` is the callee reactor (the
 *  delegation's `to`); the caller's own reactor (its `from`) is `this.name`. `state` is `running` | `cancelling`
 *  — a delegation in the map is always live; retiring it evicts the row (its outcome lives on `runs`, not here).
 *  Nothing beyond routing is kept: the target / argument ride on the (undelivered) `delegate` in the outbox,
 *  and the result flows on the `delegateAck` event, never through this row. */
interface DelegationRow {
  caller: InstanceId;
  peer: ReactorName;
  state: DelegationState;
}

/** A raiser-owned (open) escalation row in memory. `peer` is the reactor the escalate was addressed to (its
 *  `to`; `api` ⟺ the raiser is a run root, i.e. the escalation is user-facing). `delegation` is the raiser's
 *  delegation (the run, for a user-facing escalation), so the api root rebuilds its answerable list from the
 *  row alone. An escalation in the map is always open; answering it evicts the row (the Q&A lives in the audit). */
interface EscalationRow {
  raiser: InstanceId;
  peer: ReactorName;
  delegation: DelegationId;
  request: string;
  argument: Value | null;
}

/** A staged instance-envelope change for the next `persistBase`: an upsert of the generic envelope, or a
 *  cascade drop. One per instance id (last-write-wins). */
type InstanceEnvelopeChange =
  | {
      kind: "upsert";
      delegationId: DelegationId | null;
      callerReactor: ReactorName | null;
      status: InstanceStatus;
    }
  | { kind: "drop" };

/** A received (callee-side) delegation edge: the local instance handling it, and the reactor that summoned it
 *  (the reply-to). Both are the summoned instance's ambient — rebuilt on load from its envelope
 *  (`delegationId` + `callerReactor`), so this is a derived index, not an independent source of truth. */
interface HandledDelegation {
  instance: InstanceId;
  caller: ReactorName;
}

/** The caller-side context the base resolves for a reply event before dispatching to the concrete hook: the
 *  caller instance the delegation was issued by (to locate the proxy to resume), and whether the base's
 *  owned-edge retirement actually fired (`settled` — false when the delegation was already terminal, so a hook
 *  recording a parallel outcome inherits the same sticky-terminal protection). */
export interface AckContext {
  caller: InstanceId | undefined;
  settled: boolean;
}

export abstract class Reactor {
  /** This reactor's routing name — `send` stamps it as the event's `from`, and the substrate routes inbound
   *  events to `registry[event.to]`. */
  abstract readonly name: ReactorName;

  /** The shared resource pool — every reactor reowns within the same one, so a value's captured resources
   *  cross a reactor boundary (a sender releases, a receiver reowns). */
  constructor(protected readonly pool: ResourcePool) {}

  /** The follow-on events this turn produced, buffered until the substrate drains them into the outbox. */
  private readonly sendBuffer: ExternalEvent[] = [];

  /** The Layer 1 rows this reactor owns, the live in-memory source of truth, plus the per-turn dirty (upsert)
   *  and retired (delete) sets the next `persist` flushes. */
  private readonly delegations = new Map<DelegationId, DelegationRow>();
  private readonly escalations = new Map<EscalationId, EscalationRow>();
  private readonly dirtyDelegations = new Set<DelegationId>();
  private readonly dirtyEscalations = new Set<EscalationId>();
  private readonly retiredDelegations = new Set<DelegationId>();
  private readonly retiredEscalations = new Set<EscalationId>();

  /** This turn's instance-envelope changes the next `persistBase` flushes, one entry per instance: an upsert
   *  (the concrete owns each instance's live state, so the base only stages its generic row) or a drop
   *  (cascade). One map keyed by id — so an upsert and a drop of the same instance in one turn resolve by
   *  last-write-wins. The concrete registers them with `markInstance` / `markInstanceDropped`. */
  private readonly dirtyInstances = new Map<InstanceId, InstanceEnvelopeChange>();

  /** The delegations this reactor *handles* as callee — the receive-side index from a delegation to the local
   *  instance handling it AND the reactor that summoned it (the reply-to). NOT persisted here: the summoned
   *  instance's envelope (its `delegationId` + `callerReactor`) is the source of truth, re-seeded on load via
   *  `acceptDelegation`. */
  private readonly handled = new Map<DelegationId, HandledDelegation>();

  /** Snapshot what this turn touched into the transaction through this reactor's own port (`tx.<name>`): its
   *  Layer 2 (an instance's envelope + extension, or its drop). The base writes the generic half (envelopes +
   *  delegations + escalations + drops) via `persistBase`; the concrete adds its own extension. */
  abstract persist(tx: PersistenceTx): Promise<void>;

  /** The owner instance for the Layer 1 rows this turn's sends open (the delegation's caller / the escalation's
   *  raiser) and for the resources they release. The turn's core instance, the api root, or the ffi call. Only
   *  read when a send actually opens a row / releases a value. */
  abstract currentTurnOwner(): InstanceId;

  /** Strictly-post-commit side effects (durable-first): settle an in-process promise, dispatch an FFI call.
   *  Runs only after the turn is durably committed, so recovery is always possible from durable state alone. */
  afterCommit(_event: ExternalEvent): void {}

  // ─── react (final): resolve the edge, retire the owned row, dispatch to the concrete hook ────────

  /** React to one inbound external event. The base resolves the edge endpoint and applies the owned-edge
   *  deletion an ack implies (retiring the caller's delegation / the raiser's escalation), then dispatches to
   *  the concrete's hook with that context. Persists nothing (the substrate commits the turn), so a failed
   *  commit can re-run the same turn. */
  react(event: ExternalEvent): void | Promise<void> {
    switch (event.kind) {
      case "delegate":
        return this.onDelegate(event);
      case "delegateAck": {
        const caller = this.callerInstanceOf(event.delegation);
        const settled = this.retireDelegation(event.delegation);
        return this.onDelegateAck(event, { caller, settled });
      }
      case "terminate":
        return this.onTerminate(event, { callee: this.handledInstanceOf(event.delegation) });
      case "terminateAck": {
        const caller = this.callerInstanceOf(event.delegation);
        const settled = this.retireDelegation(event.delegation);
        return this.onTerminateAck(event, { caller, settled });
      }
      case "escalate":
        return this.onEscalate(event, { caller: this.callerInstanceOf(event.delegation) });
      case "escalateAck": {
        const raiser = this.handledInstanceOf(event.delegation);
        this.retireEscalation(event.escalation);
        return this.onEscalateAck(event, { raiser });
      }
    }
  }

  // ─── per-event concrete hooks (default no-op; each reactor overrides what it handles) ─────────────

  /** A `delegate` reached this reactor as callee: create the instance handling it (and `acceptDelegation`). */
  protected onDelegate(
    _event: Extract<ExternalEvent, { kind: "delegate" }>,
  ): void | Promise<void> {}

  /** A sub-call / run returned: `context.caller` is the delegation's caller (resume its proxy), `settled` is
   *  whether the base's delegation retirement fired (so a parallel outcome record is sticky-terminal safe). */
  protected onDelegateAck(
    _event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    _context: AckContext,
  ): void | Promise<void> {}

  /** A child's escalation reached this reactor as the caller of that child (`context.caller`): re-raise it
   *  inward (core), or handle / fail it (the api run root). The escalation row is raiser-owned, not touched. */
  protected onEscalate(
    _event: Extract<ExternalEvent, { kind: "escalate" }>,
    _context: { caller: InstanceId | undefined },
  ): void | Promise<void> {}

  /** The answer to an escalation this reactor raised reached it (`context.raiser` is the raiser instance): the
   *  base has already retired the escalation row; resume the raiser with the value. */
  protected onEscalateAck(
    _event: Extract<ExternalEvent, { kind: "escalateAck" }>,
    _context: { raiser: InstanceId | undefined },
  ): void | Promise<void> {}

  /** A `terminate` reached this reactor as callee (`context.callee` handles the delegation): cancel it. */
  protected onTerminate(
    _event: Extract<ExternalEvent, { kind: "terminate" }>,
    _context: { callee: InstanceId | undefined },
  ): void | Promise<void> {}

  /** A cancel cascade confirmed: the base has retired the caller's delegation (`settled`); resume the caller's
   *  proxy (`context.caller`). */
  protected onTerminateAck(
    _event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    _context: AckContext,
  ): void | Promise<void> {}

  // ─── send (final): record the owned-edge change the outgoing event implies, then buffer ──────────

  /** Emit one fully routed follow-on event (its `from` / `to` already stamped by the emitter). The base records
   *  the owned-edge change it implies — a `delegate` opens the caller's delegation, a `terminate` cancels it, a
   *  user-facing `escalate` opens the raiser's escalation — so a concrete reactor never opens / transitions a
   *  row itself. The first step of the two-step reown also rides here: a value leaving its instance UP across
   *  the boundary (a `delegateAck` result, an `escalate`'s carried value) RELEASES the resources it captures
   *  from the turn's owner to in-transit, so the receiver can reown them. */
  protected send(event: ExternalEvent): void {
    this.applySendEdge(event);
    if (event.kind === "delegateAck") this.pool.release(event.value, this.currentTurnOwner());
    else if (event.kind === "escalate") {
      const value = escalateValue(event.ask);
      if (value !== null) this.pool.release(value, this.currentTurnOwner());
    }
    this.sendBuffer.push(event);
  }

  /** Record the Layer 1 edge change the outgoing event implies on the side this reactor owns. */
  private applySendEdge(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegate":
        this.openDelegation(event.delegation, { caller: this.currentTurnOwner(), peer: event.to });
        break;
      case "terminate":
        this.toCancelling(event.delegation);
        break;
      case "escalate":
        // A durable row only for a user-facing request (one the API can list / answer). A panic / control
        // escape gets none — its raiser's suspended state (a core thread, an ffi `awaitingAnswer`) is the SoT.
        if (event.ask.kind === "request" && isUserFacingRequest(event.ask.request)) {
          this.openEscalation(event.escalation, {
            raiser: this.currentTurnOwner(),
            peer: event.to,
            delegation: event.delegation,
            request: event.ask.request,
            argument: event.ask.argument,
          });
        }
        break;
    }
  }

  /** The second step of the two-step reown: an incoming `delegateAck`'s result lands here — claim the
   *  in-transit resources it captures to `owner` (a core caller, or the api root for a run result). */
  protected reownIncoming(value: Value, owner: InstanceId): void {
    this.pool.reown(value, owner);
  }

  /** Fail a delegation with a `panic` escalation addressed to its caller (`to`). A panic is the deterministic
   *  failure channel — an unhandled one fails the run (no recovery, no retry). It carries a `{ msg }` that
   *  captures no resources and it opens no escalation row (not user-facing), so it bypasses `send`'s edge /
   *  release entirely — which also means it needs no turn owner (an unresolvable delegate has no instance). */
  protected raisePanic(delegation: DelegationId, message: string, to: ReactorName): void {
    this.sendBuffer.push({
      kind: "escalate",
      delegation,
      escalation: newEscalationId(),
      ask: { kind: "request", request: PANIC_REQUEST, argument: panicArgument(message) },
      from: this.name,
      to,
    });
  }

  /** Fail a delegation with a typed `prelude.throw` escalation addressed to its caller (`to`) — the
   *  reactor-level twin of a prim's `KatariThrow`, for failures a program anticipates and may handle (an
   *  http no-response, a bad dynamic dispatch). Like a panic it opens no escalation row (a throw answers
   *  with `never`, so it is not user-facing) and its runtime-built payload captures no resources. */
  protected raiseThrow(delegation: DelegationId, payload: Value, to: ReactorName): void {
    this.sendBuffer.push({
      kind: "escalate",
      delegation,
      escalation: newEscalationId(),
      ask: { kind: "request", request: THROW_REQUEST, argument: throwArgument(payload) },
      from: this.name,
      to,
    });
  }

  /** Take and clear this turn's buffered sends (the substrate produces them into the outbox). */
  drainSends(): ExternalEvent[] {
    const sends = [...this.sendBuffer];
    this.sendBuffer.length = 0;
    return sends;
  }

  /** Discard all warm state this reactor holds, so reactivation rebuilds it from durable rows. Used when a
   *  commit fails (the warm store advanced past the durable commit): the actor is dropped and reactivated.
   *  A concrete reactor overrides to also clear its own state, calling `super.reset()`. */
  reset(): void {
    this.sendBuffer.length = 0;
    this.delegations.clear();
    this.escalations.clear();
    this.dirtyDelegations.clear();
    this.dirtyEscalations.clear();
    this.retiredDelegations.clear();
    this.retiredEscalations.clear();
    this.dirtyInstances.clear();
    this.handled.clear();
  }

  // ─── Layer 1 edges: caller-owned delegations, raiser-owned escalations (base-internal lifecycle) ──

  /** Open a delegation this reactor issues as caller (state `running`) — from `send` on a `delegate`. */
  private openDelegation(
    delegation: DelegationId,
    row: { caller: InstanceId; peer: ReactorName },
  ): void {
    this.delegations.set(delegation, { ...row, state: "running" });
    this.dirtyDelegations.add(delegation);
  }

  /** Move a live delegation to `cancelling` (only from `running`) — from `send` on a `terminate`. A no-op when
   *  it is already gone / cancelling, so a terminate that races the delegation's retirement is harmless. */
  private toCancelling(delegation: DelegationId): void {
    const row = this.delegations.get(delegation);
    if (row === undefined || row.state !== "running") return;
    row.state = "cancelling";
    this.dirtyDelegations.add(delegation);
  }

  /** Retire a delegation this reactor owns: evict the live row and stage its durable delete. Returns whether it
   *  was live (the sticky-terminal signal) — false when already retired, so a second ack / a teardown that
   *  races the first is a no-op and never resurrects or re-records it. Called by `react` on a
   *  `delegateAck` / `terminateAck`, and by a concrete for a policy retirement (the api run root failing a run). */
  protected retireDelegation(delegation: DelegationId): boolean {
    if (!this.delegations.has(delegation)) return false;
    this.delegations.delete(delegation);
    this.dirtyDelegations.delete(delegation);
    this.retiredDelegations.add(delegation);
    return true;
  }

  /** Whether this reactor still holds `delegation` as a live row — a command guards on it (a `cancel` racing
   *  the run's completion must not act on an already-finished run). */
  protected hasLiveDelegation(delegation: DelegationId): boolean {
    return this.delegations.has(delegation);
  }

  /** The caller instance of a delegation this reactor issued — used only by `react` to resolve the caller it
   *  hands a reply's hook (`onDelegateAck` / `onTerminateAck` / `onEscalate`); a concrete never reads it. */
  private callerInstanceOf(delegation: DelegationId): InstanceId | undefined {
    return this.delegations.get(delegation)?.caller;
  }

  /** The live delegations `caller` issued, with each row's callee reactor and state — the callee-call base
   *  reads this to distribute a terminate to (and drain) the inner delegations one of its calls opened.
   *  Derived from the base-owned rows, so it needs no parallel child bookkeeping and survives reload. */
  protected issuedDelegationsOf(
    caller: InstanceId,
  ): Array<{ delegation: DelegationId; peer: ReactorName; state: DelegationState }> {
    const issued: Array<{ delegation: DelegationId; peer: ReactorName; state: DelegationState }> =
      [];
    for (const [delegation, row] of this.delegations) {
      if (row.caller === caller) {
        issued.push({ delegation, peer: row.peer, state: row.state });
      }
    }
    return issued;
  }

  /** The callee reactor of a live delegation this reactor issued — where a reply addressed to that callee
   *  (an escalation's answer descending to the raiser) routes. `undefined` once the delegation retired. */
  protected issuedPeerOf(delegation: DelegationId): ReactorName | undefined {
    return this.delegations.get(delegation)?.peer;
  }

  /** Open an escalation this reactor raised — from `send` on a user-facing `escalate` (idempotent). */
  private openEscalation(
    escalation: EscalationId,
    row: {
      raiser: InstanceId;
      peer: ReactorName;
      delegation: DelegationId;
      request: string;
      argument: Value | null;
    },
  ): void {
    if (this.escalations.has(escalation)) return;
    this.escalations.set(escalation, row);
    this.dirtyEscalations.add(escalation);
  }

  /** Retire (answer) an escalation this reactor raised: evict the open row and stage its delete. A no-op when
   *  there is no row (a caught panic answered — panics open none). Called by `react` on an `escalateAck`. */
  private retireEscalation(escalation: EscalationId): void {
    if (!this.escalations.has(escalation)) return;
    this.escalations.delete(escalation);
    this.dirtyEscalations.delete(escalation);
    this.retiredEscalations.add(escalation);
  }

  // ─── handled delegations (the callee-side receive index) ────────────────────────────────────────

  /** Record a delegation this reactor accepted as callee — a fresh delegate it is about to run, or one
   *  re-seeded on load from its surviving envelope — mapping it to the local `instance` handling it and the
   *  `caller` reactor that summoned it (the reply-to). */
  protected acceptDelegation(
    delegation: DelegationId,
    instance: InstanceId,
    caller: ReactorName,
  ): void {
    this.handled.set(delegation, { instance, caller });
  }

  /** Forget a handled delegation once its payload retired, so it is not consulted after teardown. */
  protected dropHandled(delegation: DelegationId): void {
    this.handled.delete(delegation);
  }

  /** The local instance handling `delegation` on the callee side — used to route an inbound `terminate` to the
   *  child and an inbound `escalateAck` to the raiser. */
  protected handledInstanceOf(delegation: DelegationId): InstanceId | undefined {
    return this.handled.get(delegation)?.instance;
  }

  /** The reactor that summoned a delegation this reactor handles as callee (its reply-to) — so a callee reactor
   *  routes the replies it emits (`delegateAck` / `terminateAck`) back to the summoner without a parallel map. */
  protected handledCallerOf(delegation: DelegationId): ReactorName | undefined {
    return this.handled.get(delegation)?.caller;
  }

  // ─── base-managed persist / load (the generic half, in one place) ──────────────────────────────

  /** Stage an instance-envelope upsert for the next `persistBase` — the concrete calls this when it creates or
   *  updates an instance it owns (the concrete is the live SoT; the base only persists the generic envelope). */
  protected markInstance(
    id: InstanceId,
    envelope: {
      delegationId: DelegationId | null;
      callerReactor: ReactorName | null;
      status: InstanceStatus;
    },
  ): void {
    this.dirtyInstances.set(id, { kind: "upsert", ...envelope });
  }

  /** Stage an instance drop (cascade) for the next `persistBase`. Supersedes any upsert staged for the same id
   *  this turn. Also reclaims the blobs AND scopes the dropping instance still owns (the ones it did not
   *  ascend out as a result), uniformly for a core instance and an ffi call's instance — a core teardown
   *  already freed its scopes (this is then a no-op), but an ffi call that received a closure from an inner
   *  delegation and did not return it has no other reclamation path. */
  protected markInstanceDropped(id: InstanceId): void {
    this.dirtyInstances.set(id, { kind: "drop" });
    this.pool.reclaimBlobsOwnedBy(id);
    this.pool.reclaimScopesOwnedBy(id);
  }

  /** Persist everything the base owns for this turn through `tx.base`, in FK order: the instance envelopes
   *  upserted this turn (`kind` = this reactor's own name), then the dirty delegations / escalations (upserts +
   *  deletes), then the cascade drops (last). A concrete reactor calls this and adds only its own extension via
   *  `tx.<name>`. */
  protected async persistBase(tx: BaseTx): Promise<void> {
    for (const [id, change] of this.dirtyInstances) {
      if (change.kind === "upsert")
        await tx.putInstanceEnvelope({
          id,
          kind: this.name,
          delegationId: change.delegationId,
          callerReactor: change.callerReactor,
          status: change.status,
        });
    }
    await this.flushDelegations(tx);
    await this.flushEscalations(tx);
    // Drops last, so an instance's cascade removes the rows that reference it after they are flushed.
    for (const [id, change] of this.dirtyInstances) {
      if (change.kind === "drop") await tx.dropInstance(id);
    }
    this.dirtyInstances.clear();
  }

  /** Reload everything the base owns on reactivation through `loader.base`: the live delegations this reactor
   *  issued and the open escalations it raised (both `from = this.name`). The concrete calls this once and adds
   *  only its own data. */
  protected async loadBase(loader: BaseLoader): Promise<void> {
    for (const row of await loader.delegations(this.name)) {
      this.delegations.set(row.delegation, {
        caller: row.caller,
        peer: row.toReactor,
        state: row.state,
      });
    }
    for (const open of await loader.raisedEscalations(this.name)) {
      this.escalations.set(open.escalation, {
        raiser: open.raiser,
        peer: open.toReactor,
        delegation: open.delegation,
        request: open.request,
        argument: open.argument,
      });
    }
  }

  /** Flush this turn's delegation changes: upsert the still-live dirty ones, delete the retired ones. */
  private async flushDelegations(tx: BaseTx): Promise<void> {
    for (const delegation of this.dirtyDelegations) {
      const row = this.delegations.get(delegation);
      if (row === undefined) continue;
      await tx.putDelegation({
        delegation,
        caller: row.caller,
        fromReactor: this.name,
        toReactor: row.peer,
        state: row.state,
      });
    }
    this.dirtyDelegations.clear();
    for (const delegation of this.retiredDelegations) await tx.deleteDelegation(delegation);
    this.retiredDelegations.clear();
  }

  /** Flush this turn's escalation changes: upsert the still-open dirty ones, delete the retired ones. */
  private async flushEscalations(tx: BaseTx): Promise<void> {
    for (const escalation of this.dirtyEscalations) {
      const row = this.escalations.get(escalation);
      if (row === undefined) continue;
      await tx.putEscalation({
        escalation,
        raiser: row.raiser,
        fromReactor: this.name,
        toReactor: row.peer,
        delegation: row.delegation,
        request: row.request,
        argument: row.argument,
      });
    }
    this.dirtyEscalations.clear();
    for (const escalation of this.retiredEscalations) await tx.deleteEscalation(escalation);
    this.retiredEscalations.clear();
  }
}
