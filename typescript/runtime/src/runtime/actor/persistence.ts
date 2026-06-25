// The persistence boundary. One turn = one atomic `transaction`: the reacting reactor writes its own warm
// state through the `PersistenceTx` write surface (its Layer 2 engine continuation — a core instance's
// threads + owned scopes, or its drop — together with the Layer 1 entity rows it owns: caller-side
// delegations, raiser-side escalations), and the substrate writes the transactional outbox (consume the
// inbound row, produce the turn's sends) in the same tx. Writing both in one transaction is what closes the
// gap a `DelegateThread` would otherwise open — referencing a delegation whose durable row had not been
// written yet — and keeps the reactor at the level of "describe what changed", not "own the DB".
//
// In-memory is the source of truth for the live entities (instances, scopes, delegations, escalations); a
// `transaction` is a time-slice snapshot of what one turn touched, for recovery. v0.1.0 ships three
// implementations: an in-memory no-op (`InMemoryPersistence` — the warm store is the truth), an in-memory
// *storing* twin (`StoringPersistence`, for recovery tests), and a drizzle-backed one (`DbPersistence`).

import type { DelegationState, EscalationState } from "../../db/tables/execution.js";
import type { ProjectStore } from "../engine/types.js";
import type { DelegateTarget, ExternalEvent } from "../event/types.js";
import type {
  DelegationId,
  EscalationId,
  InstanceId,
  OutboxSeq,
  ProjectId,
  ScopeId,
  SnapshotId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type { PersistedScope, SerializedInstance } from "./persistence-codec.js";

/** A caller-owned delegation row at one instant (the `delegations` table shape). The caller reactor (core
 *  for a sub-call, the api root for a run) is the source of truth and writes this each time the row's state
 *  changes — `running → done` (result set) / `cancelling → gone` / `failed` (errorMessage set). */
export interface PersistedDelegation {
  delegation: DelegationId;
  caller: InstanceId;
  target: DelegateTarget;
  argument: Value | null;
  state: DelegationState;
  result: Value | null;
  errorMessage: string | null;
}

/** A raiser-owned escalation row at one instant (the `escalations` table shape). The raiser is always a
 *  `core` instance; the row moves `open → answered` (answer set) when the raiser receives the `escalateAck`. */
export interface PersistedEscalation {
  escalation: EscalationId;
  raiser: InstanceId;
  request: string;
  argument: Value | null;
  state: EscalationState;
  answer: Value | null;
}

/** One produced external event awaiting delivery — a durable outbox row. `issuer` is the instance that
 *  produced it (the api root for an api operation), kept only to satisfy the row's non-null column; routing
 *  is recovered from the engine threads, not from this. */
export interface OutboxMessage {
  seq: OutboxSeq;
  issuer: InstanceId;
  event: ExternalEvent;
}

/** A run's API metadata sidecar (`runs` row), written by the api root atomically with the run's `delegate`
 *  so a run is never visible without its launch metadata (and vice versa). The run's *outcome* is its
 *  delegation row, not this; this holds only what the delegation does not — the human label + launch
 *  metadata. `run` is the run delegation id (the join key). */
export interface PersistedRun {
  run: DelegationId;
  name: string;
  qualifiedName: string;
  snapshotId: SnapshotId;
  argument: Value | null;
}

/** One answered user-facing escalation, recorded for the run's history (`run_escalations_audit`) when the
 *  api root relays the answer back — live escalations are open-only and raiser-owned, so the answered ones
 *  live as this projection. */
export interface PersistedRunEscalationAudit {
  run: DelegationId;
  escalation: EscalationId;
  question: Value | null;
  answer: Value;
}

/** The per-turn write surface a reactor + the substrate use to commit one turn atomically. Method-call order
 *  is the FK order the caller is responsible for: a reactor writes its instance (`putInstance`) before the
 *  Layer 1 rows that reference it, and `dropInstance` (which cascades the rows the instance owns) comes last.
 *  Every method is a no-op-safe write — the in-memory twin mutates its maps, the DB issues one statement. */
export interface PersistenceTx {
  /** Upsert a caller-owned delegation row (its current state). */
  putDelegation(row: PersistedDelegation): Promise<void>;
  /** Upsert a raiser-owned escalation row (its current state). */
  putEscalation(row: PersistedEscalation): Promise<void>;
  /** Upsert a still-running core instance's Layer 2 (its instance row + thread tree, replaced wholesale).
   *  Scopes are NOT here — they persist independently through `putScope`. */
  putInstance(serialized: SerializedInstance): Promise<void>;
  /** Upsert one scope (the `ResourcePool`'s unit). `owner` may be `null` (in transit between owners). */
  putScope(scope: PersistedScope): Promise<void>;
  /** Delete one scope the intra-instance GC reclaimed (it is owned by a still-running instance, so no drop
   *  cascade removes it). */
  deleteScope(scopeId: ScopeId): Promise<void>;
  /** Drop a completed / torn-down instance, cascading its threads, the scopes it still owns, its issued
   *  delegations, and its raised escalations (mirrors the tables' ON DELETE CASCADE). A scope its result
   *  released to in-transit (`owner = null`) is no longer owned by it, so it survives the cascade. */
  dropInstance(instanceId: InstanceId): Promise<void>;
  /** Delete the inbound outbox row this turn consumed (`null` for an originated turn — an api command or an
   *  ephemeral FFI completion — which has no durable row to delete). */
  consumeOutbox(seq: OutboxSeq): Promise<void>;
  /** Insert the events this turn produced as outbox rows (delivered to the mailbox after the commit). */
  produceOutbox(messages: OutboxMessage[]): Promise<void>;
  /** Insert a run's metadata sidecar — written by the api root in the same commit as the run's `delegate`, so
   *  startRun is atomic (a run is never durable without its launch metadata). Idempotent. */
  putRun(run: PersistedRun): Promise<void>;
  /** Record a user's cancel reason on a run, in the same commit as its `terminate`. */
  setRunCancelReason(run: DelegationId, reason: string | null): Promise<void>;
  /** Append a run's answered-escalation history row, in the same commit as the relayed `escalateAck`. */
  putRunEscalationAudit(audit: PersistedRunEscalationAudit): Promise<void>;
}

/** A persisted open escalation (an `escalations` row still in the `open` state). The actor rehydrates the
 *  user-facing ones (those raised by a run root) into the api reactor's registry on reactivation, and the
 *  core reactor reloads all of them (it is the raiser). */
export interface PersistedOpenEscalation {
  escalation: EscalationId;
  raiser: InstanceId;
  request: string;
  argument: Value | null;
}

/** A project's reconstructed state, sliced by each reactor on reactivation.
 *
 *  The engine graph (instances / scopes) rebuilds the core reactor's store; routing (which instance issued /
 *  handles each delegation) is rederived from the surviving `DelegateThread`s and instance `delegationId`s,
 *  so it never depends on a separate edge map. `liveDelegations` carries the still-running rows each reactor
 *  reloads as its own (the core reactor takes those whose caller is one of its instances; the api reactor
 *  takes the run rows whose caller is the api root). `openEscalations` are all core-raised. */
export interface ProjectSnapshot {
  instances: ProjectStore["instances"];
  scopes: ProjectStore["scopes"];
  nextScopeId: number;
  /** Live (running / cancelling) delegation rows — the ones that still carry routing and still accept a
   *  transition. Finished delegations (done / gone / failed) are history and are excluded. */
  liveDelegations: PersistedDelegation[];
  /** Open escalation rows. The actor keeps the user-facing ones (raised by a run root) so a run suspended
   *  awaiting a user's answer survives a restart; the core reactor reloads all of them (it marks them
   *  answered when the `escalateAck` arrives). */
  openEscalations: PersistedOpenEscalation[];
  /** Undrained outbox rows: events produced before the crash but not yet consumed. The actor replays them
   *  into its mailbox so an in-flight event (e.g. a completed child's `delegateAck`) is not lost. */
  pendingOutbox: OutboxMessage[];
}

export interface Persistence {
  /** Load a project's persisted engine graph + live delegation rows + open escalations to reactivate its
   *  warm actor. */
  loadProject(projectId: ProjectId): Promise<ProjectSnapshot>;
  /** Durably ensure the project's permanent `api` management root exists as an `instances` row, so a run's
   *  delegation (whose caller is the api root) satisfies the `delegations.caller_instance_id` FK. Idempotent;
   *  a no-op for the in-memory seam (no FK to satisfy). Called once on reactivation, before any commit can
   *  reference the api root. */
  ensureApiRoot(projectId: ProjectId, apiRootId: InstanceId): Promise<void>;
  /** Run one turn's writes atomically: open a transaction, hand the reactor + substrate a `PersistenceTx`,
   *  and commit. The body issues the reactor's `persist(tx)` and the outbox consume / produce. */
  transaction(projectId: ProjectId, body: (tx: PersistenceTx) => Promise<void>): Promise<void>;
}

/** The seam implementation: the warm store is the truth, so nothing persists and nothing loads. */
export class InMemoryPersistence implements Persistence {
  async loadProject(): Promise<ProjectSnapshot> {
    return {
      instances: {},
      scopes: {},
      nextScopeId: 0,
      liveDelegations: [],
      openEscalations: [],
      pendingOutbox: [],
    };
  }
  async ensureApiRoot(): Promise<void> {}
  async transaction(
    _projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    // Nothing is stored; the tx methods are no-ops. The body still runs (it has no other effect), so a
    // reactor's `persist` and the outbox writes execute against a sink — the warm maps remain the truth.
    await body(NO_OP_TX);
  }
}

const NO_OP_TX: PersistenceTx = {
  async putDelegation() {},
  async putEscalation() {},
  async putInstance() {},
  async putScope() {},
  async deleteScope() {},
  async dropInstance() {},
  async consumeOutbox() {},
  async produceOutbox() {},
  async putRun() {},
  async setRunCancelReason() {},
  async putRunEscalationAudit() {},
};
