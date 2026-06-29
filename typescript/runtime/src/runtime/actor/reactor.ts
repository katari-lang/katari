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
import { PANIC_REQUEST, panicArgument } from "../engine/common.js";
import type { InstanceStatus } from "../engine/types.js";
import {
  type DelegateTarget,
  type ExternalEvent,
  escalateValue,
  type ReactorName,
} from "../event/types.js";
import { type DelegationId, type EscalationId, type InstanceId, newEscalationId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { BaseLoader, BaseTx, PersistenceTx } from "./persistence.js";
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

/** A staged instance-envelope change for the next `persistBase`: an upsert of the generic envelope, or a
 *  cascade drop. One per instance id (last-write-wins). */
type InstanceEnvelopeChange =
  | { kind: "upsert"; delegationId: DelegationId | null; status: InstanceStatus }
  | { kind: "drop" };

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

  /** This turn's instance-envelope changes the next `persistBase` flushes, one entry per instance: an upsert
   *  (the concrete owns each instance's live state, so the base only stages its generic row) or a drop
   *  (cascade). One map keyed by id — so an upsert and a drop of the same instance in one turn resolve by
   *  last-write-wins, with no mutual-exclusion invariant to maintain. The concrete registers them with
   *  `markInstance` / `markInstanceDropped`; the base persists them so `persistBase` needs no arguments. */
  private readonly dirtyInstances = new Map<InstanceId, InstanceEnvelopeChange>();

  /** The delegations this reactor *handles* as callee — a receive-side index from a delegation to the local
   *  instance handling it, so an inbound `terminate` / `escalateAck` finds its target. NOT persisted here: the
   *  concrete reactor's payload (a core instance) is the source of truth, re-seeded on load via
   *  `acceptDelegation`. Routing of outbound events is NOT done here — each event carries its `to`, stamped at
   *  the engine edge where the callee / summoner is known. */
  private readonly handled = new Map<DelegationId, InstanceId>();

  /** React to one inbound external event: mutate this reactor's warm state and `send` any follow-on events.
   *  Persists nothing (the substrate commits the turn), so the same turn can be re-run if its commit fails.
   *  May be async (the core engine awaits the IR); the api root reacts synchronously. */
  abstract react(event: ExternalEvent): void | Promise<void>;

  /** Snapshot what this turn touched into the transaction through this reactor's own port (`tx.<name>`): its
   *  Layer 2 (an instance's envelope + extension, or its drop) interleaved with `flushDelegations` /
   *  `flushEscalations` at the FK-correct point (envelope before the rows that reference it; cascade last).
   *  The base supplies the flush + envelope helpers; the concrete reactor orders them. */
  abstract persist(tx: PersistenceTx): Promise<void>;

  /** The instance to stamp as the issuer on this turn's produced outbox rows (the turn's core instance, or
   *  the api root). Only read when the turn actually produced events. */
  abstract currentTurnOwner(): InstanceId;

  /** Strictly-post-commit side effects (durable-first): settle an in-process promise, dispatch an FFI call.
   *  Runs only after the turn is durably committed, so recovery is always possible from durable state alone. */
  afterCommit(_event: ExternalEvent): void {}

  // ─── send / drain (the from/to protocol) ────────────────────────────────────────────────────────

  /** Buffer one fully routed follow-on event (its `from` / `to` already stamped by the emitter — the engine
   *  edge for a core turn, the concrete reactor for an api / ffi emit), so this never picks a destination. The
   *  first step of the two-step reown rides here: a value leaving its instance UP across the boundary RELEASES
   *  the resources it captures from the turn's owner to in-transit, so the receiver can reown them. The two
   *  upward value flows are a sub-call / run result (`delegateAck`) and an escalation's carried value
   *  (`escalate`); the downward legs (`delegate` argument, `escalateAck` answer) stay owned by the still-live
   *  sender and are read in place, so nothing is released for them. */
  protected send(event: ExternalEvent): void {
    if (event.kind === "delegateAck") this.pool.release(event.value, this.currentTurnOwner());
    else if (event.kind === "escalate") {
      const value = escalateValue(event.ask);
      if (value !== null) this.pool.release(value, this.currentTurnOwner());
    }
    this.sendBuffer.push(event);
  }

  /** The second step of the two-step reown: an incoming `delegateAck`'s result lands here — claim the
   *  in-transit resources it captures to `owner` (a core caller, or the api root for a run result). */
  protected reownIncoming(value: Value, owner: InstanceId): void {
    this.pool.reown(value, owner);
  }

  /** Fail a delegation with a `panic` escalation addressed to its caller (`to`). A panic is the deterministic
   *  failure channel — an unhandled one fails the run (no recovery, no retry); it never rides the substrate's
   *  poison/replay path. Used when a delegate cannot be fulfilled (an unresolvable target, an FFI error). The
   *  `{ msg }` it carries captures no resources, so unlike `send` it needs no owner / release. */
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
    this.dirtyInstances.clear();
    this.handled.clear();
  }

  // ─── Layer 1 entity ownership (caller-side delegations, raiser-side escalations) ────────────────

  /** Insert / replace a delegation row, marking it dirty only when this turn changed it. The single seam
   *  both `openDelegation` (a fresh `running` row — dirty) and `reloadDelegation` (a recovered live row —
   *  already durable, not dirty) flow through, so the in-memory set and the dirty set never drift. */
  private putDelegationRow(delegation: DelegationId, row: DelegationRow, dirty: boolean): void {
    this.delegations.set(delegation, row);
    if (dirty) this.dirtyDelegations.add(delegation);
  }

  /** Open a delegation this reactor issued as caller (state `running`). `peer` is the callee reactor. */
  protected openDelegation(
    delegation: DelegationId,
    row: { caller: InstanceId; peer: ReactorName; target: DelegateTarget; argument: Value | null },
  ): void {
    this.putDelegationRow(delegation, { ...row, state: "running" }, true);
  }

  /** The callee reactor of one of this reactor's delegations (its `to`), or `undefined` if not held. Used to
   *  route a request leg this reactor emits *to* the callee — a `terminate` (cancel the child) or an
   *  `escalateAck` (answer the child's escalation) — to the right reactor (a core sub-call → `core`, an ffi
   *  call → `ffi`). */
  protected peerOf(delegation: DelegationId): ReactorName | undefined {
    return this.delegations.get(delegation)?.peer;
  }

  /** The caller instance of a delegation this reactor *issued* (the issued row's `caller`) — used to locate
   *  the proxy thread to resume on the delegation's ack. Reads the same row `flushDelegations` persists, so a
   *  concrete reactor never keeps a parallel caller map. */
  protected callerInstanceOf(delegation: DelegationId): InstanceId | undefined {
    return this.delegations.get(delegation)?.caller;
  }

  // ─── handled delegations (the callee-side receive index) ────────────────────────────────────────

  /** Record a delegation this reactor accepted as callee — a fresh delegate it is about to run, or one
   *  re-seeded on load from its surviving payload — mapping it to the local `instance` handling it. */
  protected acceptDelegation(delegation: DelegationId, instance: InstanceId): void {
    this.handled.set(delegation, instance);
  }

  /** Forget a handled delegation once its payload retired, so it is not consulted after teardown. */
  protected dropHandled(delegation: DelegationId): void {
    this.handled.delete(delegation);
  }

  /** The local instance handling `delegation` on the callee side — used to route an inbound `terminate` to the
   *  child and an inbound `escalateAck` to the raiser. */
  protected handledInstanceOf(delegation: DelegationId): InstanceId | undefined {
    return this.handled.get(delegation);
  }

  // ─── base-managed persist / load (the generic half, in one place) ──────────────────────────────

  /** Stage an instance-envelope upsert for the next `persistBase` — the concrete calls this when it creates or
   *  updates an instance it owns (the concrete is the live SoT; the base only persists the generic envelope).
   *  A later `markInstanceDropped` for the same id supersedes it (last-write-wins on the single map). */
  protected markInstance(
    id: InstanceId,
    envelope: { delegationId: DelegationId | null; status: InstanceStatus },
  ): void {
    this.dirtyInstances.set(id, { kind: "upsert", ...envelope });
  }

  /** Stage an instance drop (cascade) for the next `persistBase` — the concrete calls this when it tears an
   *  instance down. Supersedes any upsert staged for the same id this turn. Also reclaims the blobs the
   *  dropping instance still owns (the ones it did not ascend out as a result): a pure resource the pool owns,
   *  reclaimed here uniformly for a core instance and an ffi call's instance, while its scopes are reclaimed by
   *  the engine's own teardown. */
  protected markInstanceDropped(id: InstanceId): void {
    this.dirtyInstances.set(id, { kind: "drop" });
    this.pool.reclaimBlobsOwnedBy(id);
  }

  /** Persist everything the base owns for this turn through `tx.base`, in FK order: the instance envelopes
   *  upserted this turn (`kind` stamped with this reactor's own name — instance kind ≡ reactor name), then the
   *  dirty delegations, then the dirty escalations, then the cascade drops (last). A concrete reactor calls
   *  this with no arguments and adds only its own extension via `tx.<name>` — so the generic half is written
   *  in one place, uniformly (a reactor that owns no delegations stages none, and gets the capability free). */
  protected async persistBase(tx: BaseTx): Promise<void> {
    for (const [id, change] of this.dirtyInstances) {
      if (change.kind === "upsert")
        await tx.putInstanceEnvelope({
          id,
          kind: this.name,
          delegationId: change.delegationId,
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

  /** Reload everything the base owns on reactivation through `loader.base`: the delegations this reactor
   *  issued and the escalations it raised (both `from = this.name`). The concrete reactor calls this once and
   *  adds only its own data. Uniform across reactors — a reactor that owns none gets empty sets. */
  protected async loadBase(loader: BaseLoader): Promise<void> {
    for (const row of await loader.delegations(this.name)) {
      this.reloadDelegation(row.delegation, {
        caller: row.caller,
        peer: row.toReactor,
        target: row.target,
        argument: row.argument,
        state: row.state,
      });
    }
    for (const open of await loader.raisedEscalations(this.name)) {
      this.reloadEscalation(open.escalation, {
        raiser: open.raiser,
        peer: open.toReactor,
        delegation: open.delegation,
        request: open.request,
        argument: open.argument,
      });
    }
  }

  /** Move one of this reactor's delegations to a new state, returning whether the transition actually applied.
   *  A no-op (returns `false`) when it is gone or already terminal — which is exactly the sticky-terminal rule:
   *  a `failed` is never overwritten by the `gone` of the teardown it triggers, because the `failed` row was
   *  already evicted. `cancelling` only takes from `running`. The boolean lets a caller record a parallel
   *  durable outcome (the `runs` row) only when the transition fired, so that outcome inherits the same
   *  sticky-terminal protection the delegation row has. */
  protected transitionDelegation(
    delegation: DelegationId,
    state: DelegationState,
    extra: { result?: Value; errorMessage?: string } = {},
  ): boolean {
    const row = this.delegations.get(delegation);
    if (row === undefined || !isLiveDelegationState(row.state)) return false;
    if (state === "cancelling" && row.state !== "running") return false;
    row.state = state;
    if (extra.result !== undefined) row.result = extra.result;
    if (extra.errorMessage !== undefined) row.errorMessage = extra.errorMessage;
    this.dirtyDelegations.add(delegation);
    return true;
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
    this.putDelegationRow(delegation, row, false);
  }

  /** Insert / replace an open escalation row, marking it dirty only when this turn raised it (the seam for
   *  `openEscalation` and `reloadEscalation`, symmetric to `putDelegationRow`). */
  private putEscalationRow(escalation: EscalationId, row: EscalationRow, dirty: boolean): void {
    this.escalations.set(escalation, row);
    if (dirty) this.dirtyEscalations.add(escalation);
  }

  /** Open a request escalation this reactor raised (idempotent — a relay never reaches here with a duplicate
   *  id since each instance boundary mints a fresh escalation, but the guard makes a re-raise a safe no-op).
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
    this.putEscalationRow(escalation, { ...row, state: "open" }, true);
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
    this.putEscalationRow(escalation, { ...row, state: "open" }, false);
  }

  /** Flush this turn's dirty delegation rows (the caller-owned edges): upsert the still-live ones, and for the
   *  terminal ones delete the durable row *and* evict it from the live map (a delegation is pure live routing —
   *  its outcome lives on `runs`, not here). Called by `persistBase`. */
  private async flushDelegations(tx: BaseTx): Promise<void> {
    for (const delegation of this.dirtyDelegations) {
      const row = this.delegations.get(delegation);
      if (row === undefined) continue;
      if (isLiveDelegationState(row.state)) {
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
      } else {
        await tx.deleteDelegation(delegation);
        this.delegations.delete(delegation);
      }
    }
    this.dirtyDelegations.clear();
  }

  /** Flush this turn's dirty escalation rows (the raiser-owned edges — only `core` raises today): upsert the
   *  open ones, and for the answered ones delete the durable row *and* evict it (the answered Q&A lives in the
   *  escalations audit). Symmetric to `flushDelegations`; called by `persistBase`. */
  private async flushEscalations(tx: BaseTx): Promise<void> {
    for (const escalation of this.dirtyEscalations) {
      const row = this.escalations.get(escalation);
      if (row === undefined) continue;
      if (row.state === "open") {
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
      } else {
        await tx.deleteEscalation(escalation);
        this.escalations.delete(escalation);
      }
    }
    this.dirtyEscalations.clear();
  }
}
