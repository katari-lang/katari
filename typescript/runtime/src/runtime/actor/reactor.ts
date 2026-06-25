// Reactor: one module on the substrate (the bus) and the *single* place the external-event delegation /
// escalation protocol is implemented, uniformly for every reactor. A reactor reacts to inbound external
// events by mutating its own warm state and `send`ing follow-on events (buffered, drained by the substrate);
// it holds the Layer 1 entity rows it owns (the delegations it issued as caller, the escalations it raised)
// as the in-memory source of truth, and snapshots the ones a turn touched in `persist(tx)`. Reactors hold no
// DB — the substrate opens the turn's single transaction (see docs/2026-06-25-reactor-persist-redesign.md).
//
// Ownership: a delegation row is owned by its *caller* (core for a sub-call, the api root for a run); an
// escalation row by its *raiser* (always a core instance). Each reactor therefore tracks and persists only
// its own rows — there is no cross-reactor injection. A live row stays in memory; a terminal one is written
// once and evicted (its history lives in the DB, read by the API projection).

import type { DelegationState } from "../../db/tables/execution.js";
import { isLiveDelegationState } from "../../db/tables/execution.js";
import {
  type DelegateTarget,
  type ExternalEvent,
  type ExternalEventBody,
  escalateValue,
  type ReactorName,
} from "../event/types.js";
import type { DelegationId, EscalationId, InstanceId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** A caller-owned delegation row in memory (the live source of truth). `peer` is the callee reactor (the
 *  delegation's `to`); the issuer's own reactor (its `from`) is `this.name`. The pair lets each reactor
 *  reload its own rows on restart without any cross-reactor classification. */
interface DelegationRow {
  caller: InstanceId;
  peer: ReactorName;
  target: DelegateTarget;
  argument: Value | null;
  state: DelegationState;
  result?: Value;
  errorMessage?: string;
}

/** A raiser-owned escalation row in memory (the live source of truth). `peer` is the reactor the escalate was
 *  addressed to (its `to` — the caller of the raiser's delegation; `api` ⟺ the raiser is a run root, i.e.
 *  the escalation is user-facing); the raiser's own reactor (its `from`) is `this.name`. `delegation` is the
 *  raiser's delegation, which for a user-facing escalation is the run — so the api root can rebuild its
 *  answerable list (run + question) from the row alone. */
interface EscalationRow {
  raiser: InstanceId;
  peer: ReactorName;
  delegation: DelegationId;
  request: string;
  argument: Value | null;
  state: "open" | "answered";
  answer?: Value;
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

  /** The Layer 1 rows this reactor owns, the live in-memory source of truth, plus the per-turn dirty set the
   *  next `persist` flushes. */
  private readonly delegations = new Map<DelegationId, DelegationRow>();
  private readonly escalations = new Map<EscalationId, EscalationRow>();
  private readonly dirtyDelegations = new Set<DelegationId>();
  private readonly dirtyEscalations = new Set<EscalationId>();

  /** React to one inbound external event: mutate this reactor's warm state and `send` any follow-on events.
   *  Persists nothing (the substrate commits the turn), so the same turn can be re-run if its commit fails.
   *  May be async (the core engine awaits the IR); the api root reacts synchronously. */
  abstract react(event: ExternalEvent): void | Promise<void>;

  /** Snapshot what this turn touched into the transaction: the reactor's own Layer 2 (a core instance's
   *  persist / drop) interleaved with `flushLayer1` at the FK-correct point (instance before the rows that
   *  reference it; cascade last). The base supplies `flushLayer1`; the concrete reactor orders it. */
  abstract persist(tx: PersistenceTx): Promise<void>;

  /** The instance to stamp as the issuer on this turn's produced outbox rows (the turn's core instance, or
   *  the api root). Only read when the turn actually produced events. */
  abstract currentTurnOwner(): InstanceId;

  /** Strictly-post-commit side effects (durable-first): settle an in-process promise, dispatch an FFI call.
   *  Runs only after the turn is durably committed, so recovery is always possible from durable state alone. */
  afterCommit(_event: ExternalEvent): void {}

  // ─── send / drain (the from/to protocol) ────────────────────────────────────────────────────────

  /** Buffer one follow-on event, stamped `from: this.name`, addressed `to` the target reactor. The first
   *  step of the two-step reown rides here: a value leaving its instance UP across the boundary RELEASES the
   *  resources it captures from the turn's owner to in-transit, so the receiver can reown them. The two
   *  upward value flows are a sub-call / run result (`delegateAck`) and an escalation's carried value
   *  (`escalate`); the downward legs (`delegate` argument, `escalateAck` answer) stay owned by the still-live
   *  sender and are read in place, so nothing is released for them. */
  protected send(body: ExternalEventBody, to: ReactorName): void {
    if (body.kind === "delegateAck") this.pool.release(body.value, this.currentTurnOwner());
    else if (body.kind === "escalate") {
      const value = escalateValue(body.ask);
      if (value !== null) this.pool.release(value, this.currentTurnOwner());
    }
    this.sendBuffer.push({ ...body, from: this.name, to });
  }

  /** The second step of the two-step reown: an incoming `delegateAck`'s result lands here — claim the
   *  in-transit resources it captures to `owner` (a core caller, or the api root for a run result). */
  protected reownIncoming(value: Value, owner: InstanceId): void {
    this.pool.reown(value, owner);
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
  }

  // ─── Layer 1 entity ownership (caller-side delegations, raiser-side escalations) ────────────────

  /** Open a delegation this reactor issued as caller (state `running`). `peer` is the callee reactor. */
  protected openDelegation(
    delegation: DelegationId,
    row: { caller: InstanceId; peer: ReactorName; target: DelegateTarget; argument: Value | null },
  ): void {
    this.delegations.set(delegation, { ...row, state: "running" });
    this.dirtyDelegations.add(delegation);
  }

  /** Move one of this reactor's delegations to a new state (no-op if it is gone or already terminal — which
   *  is exactly the sticky-terminal rule: a `failed` is never overwritten by the `gone` of the teardown it
   *  triggers, because the `failed` row was already evicted). `cancelling` only takes from `running`. */
  protected transitionDelegation(
    delegation: DelegationId,
    state: DelegationState,
    extra: { result?: Value; errorMessage?: string } = {},
  ): void {
    const row = this.delegations.get(delegation);
    if (row === undefined || !isLiveDelegationState(row.state)) return;
    if (state === "cancelling" && row.state !== "running") return;
    row.state = state;
    if (extra.result !== undefined) row.result = extra.result;
    if (extra.errorMessage !== undefined) row.errorMessage = extra.errorMessage;
    this.dirtyDelegations.add(delegation);
  }

  /** Whether this reactor still holds `delegation` as a live (running / cancelling) row. Becomes false once
   *  the row reaches a terminal state and is evicted — a command guards on this so an already-finished entity
   *  is not acted on (e.g. a `cancel` racing the run's completion must not stamp a cancel reason on it). */
  protected hasLiveDelegation(delegation: DelegationId): boolean {
    const row = this.delegations.get(delegation);
    return row !== undefined && isLiveDelegationState(row.state);
  }

  /** Reload a live delegation row this reactor owns on reactivation (the in-memory SoT, not dirty). */
  protected reloadDelegation(
    delegation: DelegationId,
    row: {
      caller: InstanceId;
      peer: ReactorName;
      target: DelegateTarget;
      argument: Value | null;
      state: DelegationState;
    },
  ): void {
    this.delegations.set(delegation, row);
  }

  /** Open a request escalation this reactor raised (idempotent — a relay never reaches here with a duplicate
   *  id since each instance boundary mints a fresh escalation, but the guard keeps reload + open uniform).
   *  `peer` is the reactor the escalate was addressed to; `delegation` is the raiser's delegation. */
  protected openEscalation(
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
    this.escalations.set(escalation, { ...row, state: "open" });
    this.dirtyEscalations.add(escalation);
  }

  /** Mark one of this reactor's open escalations answered (no-op if gone or already answered). */
  protected answerEscalation(escalation: EscalationId, answer: Value): void {
    const row = this.escalations.get(escalation);
    if (row === undefined || row.state !== "open") return;
    row.state = "answered";
    row.answer = answer;
    this.dirtyEscalations.add(escalation);
  }

  /** Reload an open escalation row this reactor owns on reactivation (the in-memory SoT, not dirty). */
  protected reloadEscalation(
    escalation: EscalationId,
    row: {
      raiser: InstanceId;
      peer: ReactorName;
      delegation: DelegationId;
      request: string;
      argument: Value | null;
    },
  ): void {
    this.escalations.set(escalation, { ...row, state: "open" });
  }

  /** Flush this turn's dirty Layer 1 rows into the transaction, then evict the terminal / answered ones from
   *  the live in-memory maps (their history is durable; the maps hold only live rows). Concrete `persist`
   *  calls this at the FK-correct point — after its instance is written, before any cascade drop. */
  protected async flushLayer1(tx: PersistenceTx): Promise<void> {
    for (const delegation of this.dirtyDelegations) {
      const row = this.delegations.get(delegation);
      if (row === undefined) continue;
      await tx.putDelegation({
        delegation,
        caller: row.caller,
        fromReactor: this.name,
        toReactor: row.peer,
        target: row.target,
        argument: row.argument,
        state: row.state,
        result: row.result ?? null,
        errorMessage: row.errorMessage ?? null,
      });
    }
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
        state: row.state,
        answer: row.answer ?? null,
      });
    }
    for (const delegation of this.dirtyDelegations) {
      const row = this.delegations.get(delegation);
      if (row !== undefined && !isLiveDelegationState(row.state))
        this.delegations.delete(delegation);
    }
    for (const escalation of this.dirtyEscalations) {
      const row = this.escalations.get(escalation);
      if (row !== undefined && row.state === "answered") this.escalations.delete(escalation);
    }
    this.dirtyDelegations.clear();
    this.dirtyEscalations.clear();
  }
}
