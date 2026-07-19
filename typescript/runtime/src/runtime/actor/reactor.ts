// Reactor: one module on the substrate (the bus) and the *single* place the external-event delegation /
// escalation protocol is implemented, uniformly for every reactor. The base owns the ENTIRE Layer 1 lifecycle
// (the delegation / escalation rows), derived from the events that flow through it:
//
//   - `send` (final) is the one edge on the way out: as a reactor emits an event, the base records the
//     owned-edge change it implies — a `delegate` opens the caller-owned delegation, a `terminate` moves it to
//     cancelling, an `escalate` opens the raiser-owned escalation. An escalation is UNIFORM: a failure
//     (panic / throw), a control escape, and a user-facing request all open a row on this one path, and the
//     base draws no distinction between them (the classification lives only at the leaf that raises and the
//     handler that resolves — a user `handle`, or the api reactor's read filter). A concrete reactor just
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
import {
  askRequestName,
  type ExternalEvent,
  escalateValue,
  type ReactorName,
} from "../event/types.js";
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
 *  `to`). `delegation` is the raiser's delegation and `run` the run it belongs to (the event's trace
 *  context), so a reader rebuilds the answer's routing (delegation) AND its run attribution from the row
 *  alone. Every escalate opens one — a failure and a user-facing request alike — so `peer = api` no longer
 *  means "user-facing"; the api read filters its answerable set by `request` (see the escalation filter). An
 *  escalation in the map is always open; resolving it — an answer, or the api retiring a failure it resolved —
 *  evicts the row (an answered Q&A lives in the audit). */
interface EscalationRow {
  raiser: InstanceId;
  peer: ReactorName;
  delegation: DelegationId;
  run: InstanceId;
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
      runId: InstanceId | null;
      status: InstanceStatus;
    }
  | { kind: "drop" };

/** A received (callee-side) delegation edge: the local instance handling it, the reactor that summoned it
 *  (the reply-to), the run it belongs to (the summoning event's trace context), and the caller INSTANCE that
 *  issued it (the hoist target — where this instance's blobs climb on an upward event). The first three are
 *  the summoned instance's ambient — rebuilt on load from its envelope (`delegationId` + `callerReactor` +
 *  `runId`). The caller instance rides on the summoning `delegate` (not persisted here): after a restart it
 *  is `undefined` for a callee whose reactor cannot re-derive it, which only suppresses the hoist for a
 *  reloaded external call — whose produced blobs were in-memory and are gone anyway (at-most-once recovery
 *  fails such a call). The core reactor re-derives it from the delegation row it owns (see its `load`). */
interface HandledDelegation {
  instance: InstanceId;
  caller: ReactorName;
  run: InstanceId;
  callerInstance: InstanceId | undefined;
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

  /** A reverse index over the caller-owned `delegations`: each issuing instance to the set of live
   *  delegations it opened — its children in the delegation tree. Maintained alongside `delegations` (opened
   *  on `openDelegation`, dropped on `retireDelegation`, rebuilt on load), so `issuedDelegationsOf` /
   *  `hasIssuedDelegations` — read on every terminate + settle cascade — are O(children of one instance),
   *  not a scan of the whole map. This is the base's record of "which instance summoned which child": with
   *  the receive-side `handled` index (delegation → the instance handling it), a parent delegation's children
   *  are `issuedDelegationsOf(handledInstanceOf(parent))`, the general delegation-tree wiring. */
  private readonly issuedByCaller = new Map<InstanceId, Set<DelegationId>>();

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
        this.deleteEscalation(event.escalation);
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

  /** Emit one fully routed follow-on event (its `from` / `to` already stamped by the emitter), issued by
   *  `issuer` — the instance whose turn produced it. The base records the Layer 1 edge the event implies (a
   *  `delegate` opens the caller's delegation, a `terminate` cancels it, an `escalate` opens the raiser's
   *  escalation — every escalate, uniformly) and performs the first step of the two-step reown (a value
   *  crossing UP — a `delegateAck` result, an `escalate`'s carried value — RELEASES the resources it captures
   *  from `issuer` to in-transit, so the receiver can reown them). So a concrete reactor only emits; it never
   *  opens / transitions a row itself, and passes the issuing instance rather than the base reaching for an
   *  ambient. `issuer` is required for exactly the events that open a row or release a value (delegate /
   *  escalate / delegateAck); it is omitted for a reply that owns nothing (a stray `terminateAck` for an
   *  already-gone delegation, an `escalateAck`, a plain `terminate`). */
  protected send(event: ExternalEvent, issuer?: InstanceId): void {
    switch (event.kind) {
      case "delegate": {
        const caller = this.requireIssuer(issuer, event);
        this.openDelegation(event.delegation, { caller, peer: event.to });
        // Stamp the issuing instance onto the event so the callee can record it as the hoist target for the
        // upward events it later emits. Only the base knows this authoritatively (it owns the caller-side
        // row), so it stamps here rather than trusting each emit site to.
        event.caller = caller;
        break;
      }
      case "terminate":
        this.toCancelling(event.delegation);
        break;
      case "escalate": {
        const raiser = this.requireIssuer(issuer, event);
        // Every escalate opens a durable raiser-owned row — a failure (panic / throw), a control escape, and
        // a user-facing request all flow this one uniform path; the base draws no distinction (that lives at
        // the leaf that raises and the handler that resolves — the api read filter). The row's `request`
        // column stores the ask's qualified name (or a control ask's bare kind), so a reader can classify
        // from the row without the base ever having.
        this.openEscalation(event.escalation, {
          raiser,
          peer: event.to,
          delegation: event.delegation,
          run: event.run,
          request: askRequestName(event.ask),
          argument: escalateValue(event.ask),
        });
        const carried = escalateValue(event.ask);
        // The carried ask's captured SCOPES ascend value-driven (release → the receiver reowns). An escalate
        // is an observable upward event, so it also HOISTS the raiser's remaining blobs one step up — a
        // relayed child ask, a user-facing request the raiser waits on: whatever id its text carries survives
        // even if the raiser is later cancelled (test: the hoisted blob is not pruned by the cancel).
        if (carried !== null) this.pool.release(carried, raiser);
        this.hoistOwnedBlobs(event.delegation, raiser);
        break;
      }
      case "delegateAck": {
        const issuerInstance = this.requireIssuer(issuer, event);
        // The result's captured scopes ascend value-driven (release → the caller reowns); the returning
        // instance's remaining blobs — the ones the result carried only as an id in some text plane, not as a
        // ref — hoist onto the caller, since the completing instance's teardown would otherwise reclaim them
        // in this same commit.
        this.pool.release(event.value, issuerInstance);
        this.hoistOwnedBlobs(event.delegation, issuerInstance);
        break;
      }
    }
    this.sendBuffer.push(event);
  }

  /** Hoist every blob `issuer` still owns one delegation step up, onto the caller instance that summoned it —
   *  the ownership half of an observable upward event (a `delegateAck` result, an `escalate`'s carried ask).
   *  Runs on the SEND side, in the sending instance's own commit: a blob row cascade-deletes with its owner
   *  instance (`blobs.owner_instance_id ON DELETE CASCADE`), so a completing instance's teardown would drop
   *  its still-owned blobs in the very commit that emits its final `delegateAck` — before the caller ever
   *  reacts. Reassigning here, before teardown, is the only point where the blobs still exist AND their target
   *  is knowable; a receive-side reassign would always observe an already-cascaded blob. The value-carried
   *  ones the `release` just moved to in-transit are no longer owned by `issuer`, so this catches exactly the
   *  ones text carried but the value did not.
   *
   *  Skipped at the run→api boundary (`caller = api`): the run instance is permanent, so hoisting every blob
   *  onto it would pin them for the run's whole life — that boundary stays purely value-driven (the carried
   *  ones reown onto the run, the rest reclaim at the run root's teardown). Also skipped when the caller
   *  instance is unknown (a reloaded external call, whose in-memory produced blobs are gone regardless). */
  private hoistOwnedBlobs(delegation: DelegationId, issuer: InstanceId): void {
    if (this.handledCallerOf(delegation) === "api") return;
    const caller = this.handledCallerInstanceOf(delegation);
    if (caller === undefined) return;
    this.pool.reassignOwnedBlobs(issuer, caller);
  }

  /** The issuer for a send that needs one (it opens a row or releases a value). A missing issuer there is an
   *  engine bug — the concrete failed to pass the instance whose turn produced the event. */
  private requireIssuer(issuer: InstanceId | undefined, event: ExternalEvent): InstanceId {
    if (issuer === undefined) {
      throw new Error(`${this.name}.send(${event.kind}) needs an issuer instance (engine bug)`);
    }
    return issuer;
  }

  /** The second step of the two-step reown: an incoming `delegateAck`'s result lands here — claim the
   *  in-transit resources it captures to `owner` (a core caller, or the api root for a run result). */
  protected reownIncoming(value: Value, owner: InstanceId): void {
    this.pool.reown(value, owner);
  }

  /** Fail a delegation with a `panic` escalation addressed to its caller (`to`), raised by `raiser` — the
   *  delegate's issuer instance (a pre-instance failure has no callee yet, so the issuer OWNS the row). A
   *  panic is the deterministic failure channel — an unhandled one fails the run (no recovery, no retry) —
   *  but it is an escalation like any other, so it flows through the ONE `send` path: the same durable
   *  raiser-owned row, the same value release, and the same blob hoist onto the caller every other escalate
   *  gets. It is synthesised here only because there is no engine outbound to route; it is NOT a `send`
   *  variant with the release / hoist cut out (that ad-hoc left a hoisted blob behind — see `raiseThrow`).
   *  A panic's `{ message }` captures no resources, so the release is a no-op; the hoist is skipped naturally
   *  for a pre-instance failure (the failed delegation has no received edge yet) and at the run→api boundary.
   *  `run` is the failing delegation's trace context, taken from the event failed. */
  protected raisePanic(
    delegation: DelegationId,
    message: string,
    to: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    this.send(
      {
        kind: "escalate",
        delegation,
        escalation: newEscalationId(),
        ask: { kind: "request", request: PANIC_REQUEST, argument: panicArgument(message) },
        from: this.name,
        to,
        run,
      },
      raiser,
    );
  }

  /** Fail a delegation with a typed `prelude.throw` escalation addressed to its caller (`to`), raised by
   *  `raiser` (the callee's external-call instance) — the reactor-level twin of a prim's `KatariThrow`, for
   *  failures a program anticipates and may handle (an http no-response, a sidecar's typed throw). It flows
   *  through the ONE `send` path like a panic, which is LOAD-BEARING here: a typed throw's payload can carry
   *  a REAL blob ref (the callee's unconditional wire decode reconstructs one), so the `send` releases that
   *  ref to in-transit for a catching handler to reown AND hoists the raiser's remaining blobs onto the
   *  caller — without which the payload's blob would stay owned by the (soon torn-down) call instance and the
   *  catcher's ref would dangle (`file.gone`). A caught throw's row is retired on its `escalateAck`, an
   *  uncaught one's on the raiser's teardown. */
  protected raiseThrow(
    delegation: DelegationId,
    payload: Value,
    to: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    this.send(
      {
        kind: "escalate",
        delegation,
        escalation: newEscalationId(),
        ask: { kind: "request", request: THROW_REQUEST, argument: throwArgument(payload) },
        from: this.name,
        to,
        run,
      },
      raiser,
    );
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
    this.issuedByCaller.clear();
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
    this.indexIssued(row.caller, delegation);
  }

  /** Add a delegation to its caller's issued-set (creating the set on first child). */
  private indexIssued(caller: InstanceId, delegation: DelegationId): void {
    const set = this.issuedByCaller.get(caller);
    if (set === undefined) this.issuedByCaller.set(caller, new Set([delegation]));
    else set.add(delegation);
  }

  /** Remove a delegation from its caller's issued-set, evicting the set once its last child retires. */
  private unindexIssued(caller: InstanceId, delegation: DelegationId): void {
    const set = this.issuedByCaller.get(caller);
    if (set === undefined) return;
    set.delete(delegation);
    if (set.size === 0) this.issuedByCaller.delete(caller);
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
    const row = this.delegations.get(delegation);
    if (row === undefined) return false;
    this.delegations.delete(delegation);
    this.dirtyDelegations.delete(delegation);
    this.retiredDelegations.add(delegation);
    this.unindexIssued(row.caller, delegation);
    return true;
  }

  /** Whether this reactor still holds `delegation` as a live row — a command guards on it (a `cancel` racing
   *  the run's completion must not act on an already-finished run). */
  protected hasLiveDelegation(delegation: DelegationId): boolean {
    return this.delegations.has(delegation);
  }

  /** The caller instance of a delegation this reactor issued — used by `react` to resolve the caller it hands
   *  a reply's hook (`onDelegateAck` / `onTerminateAck` / `onEscalate`), and by core to attribute a
   *  pre-instance failure to the delegate's issuer. For a sub-call this reactor owns the row, so the issuer is
   *  present (a mortal core instance). A run delegate is owned by the api (absent here), but it is validated
   *  at the run-start boundary and so never reaches core's pre-instance failure — core throws loudly rather
   *  than attribute a row to the permanent run instance (never resurrecting the old `?? event.run` leak). */
  protected callerInstanceOf(delegation: DelegationId): InstanceId | undefined {
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
    const children = this.issuedByCaller.get(caller);
    if (children === undefined) return issued;
    for (const delegation of children) {
      const row = this.delegations.get(delegation);
      if (row !== undefined) issued.push({ delegation, peer: row.peer, state: row.state });
    }
    return issued;
  }

  /** Whether `caller` still has any live issued delegation — the O(1) drain-barrier check `maybeSettle`
   *  needs, instead of materialising the full `issuedDelegationsOf` array only to read its length. */
  protected hasIssuedDelegations(caller: InstanceId): boolean {
    return (this.issuedByCaller.get(caller)?.size ?? 0) > 0;
  }

  /** The callee reactor + state of one live delegation this reactor issued, by its id — an O(1) read where
   *  `issuedDelegationsOf(...).find(...)` would rebuild and scan the whole issued array to inspect one known
   *  child (the callee-call base cancelling a single failing inner delegation). `undefined` once retired. */
  protected issuedRowOf(
    delegation: DelegationId,
  ): { peer: ReactorName; state: DelegationState } | undefined {
    const row = this.delegations.get(delegation);
    return row === undefined ? undefined : { peer: row.peer, state: row.state };
  }

  /** The callee reactor of a live delegation this reactor issued — where a reply addressed to that callee
   *  (an escalation's answer descending to the raiser) routes. `undefined` once the delegation retired. */
  protected issuedPeerOf(delegation: DelegationId): ReactorName | undefined {
    return this.delegations.get(delegation)?.peer;
  }

  /** Open an escalation this reactor raised — from `send` on any `escalate` (a user-facing request, a
   *  control escape, or a synthesised panic / throw, which all reach `send` uniformly). Idempotent: a fresh
   *  id opens once, a repeat is a no-op. */
  private openEscalation(
    escalation: EscalationId,
    row: {
      raiser: InstanceId;
      peer: ReactorName;
      delegation: DelegationId;
      run: InstanceId;
      request: string;
      argument: Value | null;
    },
  ): void {
    if (this.escalations.has(escalation)) return;
    this.escalations.set(escalation, row);
    this.dirtyEscalations.add(escalation);
  }

  /** Retire the escalation a raiser is closing: evict its open row and stage the durable delete. Called by
   *  `react` on an `escalateAck` — the raiser reactor owns the row (a user-facing answer, or a CAUGHT
   *  panic / throw whose row now exists too), so the answer retires it. Idempotent (a no-op / harmless
   *  stray delete when there is no row). A FAILURE that reaches the run root is NOT retired this way — it
   *  is never answered; its row cascades when the run teardown drops its mortal raiser. */
  protected deleteEscalation(escalation: EscalationId): void {
    this.escalations.delete(escalation);
    this.dirtyEscalations.delete(escalation);
    this.retiredEscalations.add(escalation);
  }

  /** The open escalation this reactor raised for `request` under `delegation`, if one exists. The row set is
   *  reloaded by `loadBase`, so this is how a concrete reactor recognises durable ask-and-wait state after a
   *  restart — the mcp reactor rebuilds a parked authorize from exactly this (the open row IS the park state).
   *  A linear scan is fine: the map holds only this reactor's own open rows, read once per reloaded call. */
  protected openRaisedEscalationOf(
    delegation: DelegationId,
    request: string,
  ): EscalationId | undefined {
    for (const [escalation, row] of this.escalations) {
      if (row.delegation === delegation && row.request === request) return escalation;
    }
    return undefined;
  }

  // ─── handled delegations (the callee-side receive index) ────────────────────────────────────────

  /** Record a delegation this reactor accepted as callee — a fresh delegate it is about to run, or one
   *  re-seeded on load from its surviving envelope — mapping it to the local `instance` handling it, the
   *  `caller` reactor that summoned it (the reply-to), the `run` it belongs to (the trace context the replies
   *  this reactor emits for it are stamped with), and the caller `callerInstance` (the hoist target — the
   *  `delegate.caller` for a fresh accept; `undefined` when a reload cannot re-derive it). */
  protected acceptDelegation(
    delegation: DelegationId,
    instance: InstanceId,
    caller: ReactorName,
    run: InstanceId,
    callerInstance: InstanceId | undefined,
  ): void {
    this.handled.set(delegation, { instance, caller, run, callerInstance });
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

  /** The caller INSTANCE that summoned a delegation this reactor handles as callee — the hoist target for an
   *  upward event this reactor emits under that delegation (`send` reassigns the sending instance's blobs onto
   *  it). `undefined` when unknown (a reload that could not re-derive it, or a hand-built delegate carrying no
   *  `caller`), which the hoist reads as "nothing to climb onto". */
  protected handledCallerInstanceOf(delegation: DelegationId): InstanceId | undefined {
    return this.handled.get(delegation)?.callerInstance;
  }

  /** The run of a delegation this reactor handles as callee — the trace context the events it emits under
   *  that delegation are stamped with. */
  protected handledRunOf(delegation: DelegationId): InstanceId | undefined {
    return this.handled.get(delegation)?.run;
  }

  // ─── base-managed persist / load (the generic half, in one place) ──────────────────────────────

  /** Stage an instance-envelope upsert for the next `persistBase` — the concrete calls this when it creates or
   *  updates an instance it owns (the concrete is the live SoT; the base only persists the generic envelope). */
  protected markInstance(
    id: InstanceId,
    envelope: {
      delegationId: DelegationId | null;
      callerReactor: ReactorName | null;
      runId: InstanceId | null;
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
          runId: change.runId,
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
      this.indexIssued(row.caller, row.delegation);
    }
    for (const open of await loader.raisedEscalations(this.name)) {
      this.escalations.set(open.escalation, {
        raiser: open.raiser,
        peer: open.toReactor,
        delegation: open.delegation,
        run: open.run,
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
      // Skip a row whose raiser instance is dropped THIS batch: it nets to no durable row, so writing it is
      // both wrong and unnecessary. A born-and-dropped raiser (a caught throw's raiser subtree, an unhandled
      // failure's whole subtree) never has its envelope persisted — `markInstanceDropped` supersedes the birth
      // upsert in `dirtyInstances` (last-write-wins), so the envelope is never inserted — yet the raiser-owned
      // escalation still carries the (immediate, non-deferrable) `raiser_instance_id` FK; inserting it would
      // dangle that FK and the whole atomic batch would roll back. And even a previously-committed raiser
      // dropped this batch would have the row cascaded away by that same drop. Either way the open+drop is
      // invisible outside the batch, so we simply do not write the row. This lives in the shared base, so the
      // DB backend and its in-memory twin net to the identical zero rows.
      if (this.dirtyInstances.get(row.raiser)?.kind === "drop") continue;
      await tx.putEscalation({
        escalation,
        raiser: row.raiser,
        fromReactor: this.name,
        toReactor: row.peer,
        delegation: row.delegation,
        run: row.run,
        request: row.request,
        argument: row.argument,
      });
    }
    this.dirtyEscalations.clear();
    for (const escalation of this.retiredEscalations) await tx.deleteEscalation(escalation);
    this.retiredEscalations.clear();
  }
}
