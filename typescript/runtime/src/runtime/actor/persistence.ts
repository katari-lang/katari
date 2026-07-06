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

import type { DelegationState, RunState } from "../../db/tables/execution.js";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import type {
  BlobId,
  DelegationId,
  EscalationId,
  InstanceId,
  OutboxSeq,
  ProjectId,
  ScopeId,
  SnapshotId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type {
  DeserializedEngine,
  PersistedBlob,
  PersistedInstanceEnvelope,
  PersistedScope,
  SerializedCoreInstance,
} from "./persistence-codec.js";

/** A caller-owned delegation row at one instant (the `delegations` table shape) — pure live routing. Only the
 *  running / cancelling rows exist; a terminal one is deleted (its outcome lives on `runs`). `fromReactor` (the
 *  caller's reactor) / `toReactor` (the callee's) let each reactor reload its own delegations on restart
 *  without classifying by the caller's identity. Nothing beyond routing is stored: the target / argument ride
 *  on the (undelivered) `delegate` in the outbox, and the result flows on the `delegateAck` event. */
export interface PersistedDelegation {
  delegation: DelegationId;
  caller: InstanceId;
  fromReactor: ReactorName;
  toReactor: ReactorName;
  state: DelegationState;
}

/** A raiser-owned (open) escalation row (the `escalations` table shape). The raiser is a `core` instance today;
 *  the row exists only while open (answering deletes it — the Q&A lives in the audit). `fromReactor` (the
 *  raiser's reactor) / `toReactor` (the reactor the escalate was addressed to) let each reactor self-select on
 *  restart — `toReactor = "api"` ⟺ the raiser is a run root (a user-facing escalation). `delegation` is the
 *  raiser's delegation (the answer's routing); `run` is the run instance it belongs to (its attribution). */
export interface PersistedEscalation {
  escalation: EscalationId;
  raiser: InstanceId;
  fromReactor: ReactorName;
  toReactor: ReactorName;
  delegation: DelegationId;
  run: InstanceId;
  request: string;
  argument: Value | null;
}

/** One produced external event awaiting delivery — a durable outbox row. Routing is carried on the event
 *  itself (`from` / `to`) and recovered from the engine threads, so no issuer is stored. */
export interface OutboxMessage {
  seq: OutboxSeq;
  event: ExternalEvent;
}

/** A run's launch record (`runs` row — the run instance's extension record, keyed by that instance's id),
 *  written by the api reactor atomically with the run instance's envelope and its `delegate`, so a run is
 *  never visible without its launch metadata. The run starts `running`; its outcome is updated later via
 *  `setRunOutcome`. */
export interface PersistedRun {
  run: InstanceId;
  name: string;
  qualifiedName: string;
  snapshotId: SnapshotId;
  argument: Value | null;
}

/** A run's state / outcome update — the api reactor writes it as the run advances (`cancelling` on a cancel
 *  request; `done` / `cancelled` / `error` with its result / error at the terminal). Since the run delegation
 *  row is deleted on terminal, this is the durable source of truth for the run's outcome. A `cancelReason`
 *  rides along on the `cancelling` update (so a cancel's state + reason commit as one write); it is `undefined`
 *  on every other update, leaving the stored reason untouched. */
export interface PersistedRunOutcome {
  run: InstanceId;
  state: RunState;
  result: Value | null;
  errorMessage: string | null;
  cancelReason?: string | null;
}

/** One answered user-facing escalation, recorded for the run's history (`run_escalations_audit`) when the
 *  api reactor relays the answer back — live escalations are open-only and raiser-owned, so the answered
 *  ones live as this projection. */
export interface PersistedRunEscalationAudit {
  run: InstanceId;
  escalation: EscalationId;
  question: Value | null;
  answer: Value;
}

/** One escalation an ffi call is proxying upward: the outer id it was re-raised under, and the child leg
 *  (inner delegation + its escalation) the answer descends to. Rides on the call's ext row so an in-flight
 *  answer still routes down after a restart. */
export interface PersistedEscalationRelay {
  escalation: EscalationId;
  child: DelegationId;
  childEscalation: EscalationId;
}

/** One inner delegation's transport correlation (delegation ↔ the sidecar's `call` token), riding on the
 *  call's ext row so a settled result still finds its consumer after a warm reset. */
export interface PersistedInnerCall {
  delegation: DelegationId;
  call: string;
}

/** The `ffi` instance extension write (`ffi_instances`) — the call-specific state behind an `ffi`-kind
 *  instance envelope. The delegation it handles is on the envelope (`delegation_id`), so it is not repeated
 *  here; `projectId` is injected by the transaction. The argument is NOT stored: recovery never re-runs a
 *  handler (at-most-once, like http), so nothing reads it back — and it may carry secrets. */
export interface PersistedFfiInstanceRow {
  instanceId: InstanceId;
  /** The snapshot whose sidecar bundle hosts the handler — pins the running version. */
  snapshotId: SnapshotId;
  key: string;
  status: "running" | "cancelling" | "awaitingAnswer";
  relays: PersistedEscalationRelay[];
  innerCalls: PersistedInnerCall[];
}

/** One in-flight FFI call a reactivation reads (envelope ⋈ `ffi_instances`): the ffi reactor rebuilds its
 *  warm call keyed by `delegation` (from the envelope). `instance` is the call's own id (the issuer on its
 *  replies); `caller` is the reactor to reply to. */
export interface PersistedFfiInstance {
  delegation: DelegationId;
  instance: InstanceId;
  snapshot: SnapshotId;
  key: string;
  caller: ReactorName;
  /** The run the call belongs to (its trace context), from the envelope. */
  run: InstanceId;
  status: "running" | "cancelling" | "awaitingAnswer";
  relays: PersistedEscalationRelay[];
  innerCalls: PersistedInnerCall[];
}

/** The `http` instance extension write (`http_instances`) — just the call-specific `status` (the envelope
 *  cannot carry `awaitingAnswer`), behind an `http`-kind instance envelope. The delegation it handles and the
 *  caller reactor its reply routes to are both on the envelope. Mirrors 'PersistedFfiInstanceRow' minus the
 *  snapshot/key/argument an http recovery never re-sends. */
export interface PersistedHttpInstanceRow {
  instanceId: InstanceId;
  status: "running" | "cancelling" | "awaitingAnswer";
}

/** One in-flight http call a reactivation reads (envelope ⋈ `http_instances`): the http reactor rebuilds its
 *  warm call keyed by `delegation` (from the envelope), with `instance` the call's own id, the precise
 *  `status` from the extension (so an `awaitingAnswer` call is not mistaken for a `running` one), and the
 *  `caller` reactor its reply routes to. */
export interface PersistedHttpInstance {
  delegation: DelegationId;
  instance: InstanceId;
  caller: ReactorName;
  /** The run the call belongs to (its trace context), from the envelope. */
  run: InstanceId;
  status: "running" | "cancelling" | "awaitingAnswer";
}

/** The base-class write surface: the generic state every reactor's base owns — the instance envelope, the
 *  caller-owned delegations, the raiser-owned escalations, and the cascade drop. A concrete reactor never
 *  touches this directly; it goes through `Reactor.persistBase`, so the protocol is uniform (and a reactor
 *  that issues no delegations, like `ffi` today, can start to without any new wiring). */
export interface BaseTx {
  /** Upsert the generic envelope (id / kind / delegation / status), before any FK that points at the instance. */
  putInstanceEnvelope(envelope: PersistedInstanceEnvelope): Promise<void>;
  /** Upsert a live caller-owned delegation row (running / cancelling). */
  putDelegation(row: PersistedDelegation): Promise<void>;
  /** Delete a delegation that reached a terminal state (mirroring its in-memory eviction — the row is pure
   *  live routing, its outcome lives on `runs`). Idempotent. */
  deleteDelegation(delegation: DelegationId): Promise<void>;
  /** Upsert an open raiser-owned escalation row. */
  putEscalation(row: PersistedEscalation): Promise<void>;
  /** Delete an answered escalation (its in-memory eviction; the answered Q&A lives in the escalations audit).
   *  Idempotent. */
  deleteEscalation(escalation: EscalationId): Promise<void>;
  /** Drop a completed / torn-down instance, cascading its extension / threads / owned scopes / issued
   *  delegations / raised escalations (mirrors the tables' ON DELETE CASCADE). */
  dropInstance(instanceId: InstanceId): Promise<void>;
}

/** The `core` reactor's *own-data* write surface — just its `core_instances` extension + thread tree. The
 *  envelope / delegations / escalations / drop go through `BaseTx`. */
export interface CoreTx {
  putCoreInstance(serialized: SerializedCoreInstance): Promise<void>;
}

/** The `api` reactor's *own-data* write surface — the run-metadata sidecar / audit it owns. */
export interface ApiTx {
  /** Insert a run's launch record — written in the same commit as the run's `delegate`, so startRun is atomic
   *  (a run is never durable without its launch metadata). Starts `running`. Idempotent. */
  putRun(run: PersistedRun): Promise<void>;
  /** Update a run's state / outcome (the durable SoT now the delegation row is deleted on terminal): `state`,
   *  and `result` / `errorMessage` at a terminal, with `completedAt` set then; a `cancelReason` (on a cancel's
   *  `cancelling` update) rides along here too. In the same commit as the event that caused it (a `terminate`,
   *  or the terminal `delegateAck` / `terminateAck` / `escalate`). */
  setRunOutcome(outcome: PersistedRunOutcome): Promise<void>;
  /** Append a run's answered-escalation history row, in the same commit as the relayed `escalateAck`. */
  putRunEscalationAudit(audit: PersistedRunEscalationAudit): Promise<void>;
}

/** The `ffi` reactor's *own-data* write surface — its `ffi_instances` extension (the envelope is base). */
export interface FfiTx {
  putFfiInstance(row: PersistedFfiInstanceRow): Promise<void>;
}

/** The `http` reactor's *own-data* write surface — its `http_instances` extension (the envelope is base). */
export interface HttpTx {
  putHttpInstance(row: PersistedHttpInstanceRow): Promise<void>;
}

/** The `ResourcePool`'s write surface: the independent scope / blob-ownership resource. `owner` may be `null`
 *  (a value in transit between owners mid-ascent). */
export interface PoolTx {
  putScope(scope: PersistedScope): Promise<void>;
  /** Delete one scope the intra-instance GC reclaimed (owned by a still-running instance, so no cascade). */
  deleteScope(scopeId: ScopeId): Promise<void>;
  putBlob(blob: PersistedBlob): Promise<void>;
  /** Delete one blob row the GC reclaimed; its bytes are freed separately, post-commit. */
  dropBlob(blobId: BlobId): Promise<void>;
}

/** The substrate's transactional-outbox write surface. */
export interface OutboxTx {
  /** Delete the inbound outbox row this turn consumed (`null` for an originated turn — an api command or an
   *  ephemeral FFI completion — which has no durable row to delete). */
  consumeOutbox(seq: OutboxSeq): Promise<void>;
  /** Insert the events this turn produced as outbox rows (delivered to the mailbox after the commit). */
  produceOutbox(messages: OutboxMessage[]): Promise<void>;
}

/** The substrate's journal write surface: the permanent, append-only twin of the outbox. Where the outbox is
 *  transient delivery (a row is deleted once consumed), the journal keeps every produced event forever as a
 *  run's execution trace, keyed by the event's own `run` stamp — appended in the same commit as
 *  `produceOutbox`, so an event is journaled exactly iff it was durably sent. */
export interface JournalTx {
  appendEvents(events: ExternalEvent[]): Promise<void>;
}

/** The per-turn write surface over one shared transaction: the base-managed generic rows go through `tx.base`
 *  (via `Reactor.persistBase`), each reactor's own extension through `tx.<name>`, the pool through `tx.pool`,
 *  the substrate through `tx.outbox`. So a concrete reactor's `persist` is `persistBase(tx.base, …)` plus its
 *  own data — the flat god-interface is gone, and the generic half is written in exactly one place. */
export interface PersistenceTx {
  base: BaseTx;
  core: CoreTx;
  api: ApiTx;
  ffi: FfiTx;
  http: HttpTx;
  pool: PoolTx;
  outbox: OutboxTx;
  journal: JournalTx;
}

/** A persisted open escalation (an `escalations` row still in the `open` state). Each reactor self-selects
 *  the ones it needs from the `Loader` by reactor (`from` = the raiser's reactor; `to` = the addressed
 *  reactor — `to = "api"` is a user-facing escalation). `delegation` routes the answer; `run` attributes it. */
export interface PersistedOpenEscalation {
  escalation: EscalationId;
  raiser: InstanceId;
  fromReactor: ReactorName;
  toReactor: ReactorName;
  delegation: DelegationId;
  run: InstanceId;
  request: string;
  argument: Value | null;
}

/** The `core` reactor's read surface: its engine graph plus the Layer 1 edges it owns. Every query returns
 *  only live (running / cancelling) delegations / open escalations — terminal rows are history. */
/** The base-class read surface, symmetric to `BaseTx`: the generic Layer 1 edges a reactor owns, reloaded
 *  through `Reactor.loadBase` (which passes `this.name`). A reactor reloads the delegations it *issued* and
 *  the escalations it *raised* — both `from = self`. Uniform across reactors (a reactor that raises / issues
 *  none just gets an empty set). */
export interface BaseLoader {
  /** The live delegations issued by `from` (the caller's reactor). */
  delegations(from: ReactorName): Promise<PersistedDelegation[]>;
  /** The open escalations raised by `from` (the raiser's reactor) — so the raiser can mark them answered. */
  raisedEscalations(from: ReactorName): Promise<PersistedOpenEscalation[]>;
}

/** The `core` reactor's own-data read surface: just its engine graph (its delegations / escalations come
 *  through `BaseLoader`). */
export interface CoreLoader {
  /** The core engine graph (instances + their threads + the shared scopes / blobs). */
  engine(): Promise<DeserializedEngine>;
}

/** The `api` reactor's own-data read surface: the escalations *addressed to* it (`to = api`) — its answerable
 *  set, a projection of core-raised rows, not edges it owns (those come through `BaseLoader`). */
export interface ApiLoader {
  answerableEscalations(): Promise<PersistedOpenEscalation[]>;
}

/** The `ffi` reactor's own-data read surface: its in-flight instances (calls), to recover / re-abort. */
export interface FfiLoader {
  instances(): Promise<PersistedFfiInstance[]>;
}

/** The `http` reactor's own-data read surface: its in-flight calls (envelope ⋈ `http_instances`), to fail
 *  at-most-once on recovery. */
export interface HttpLoader {
  instances(): Promise<PersistedHttpInstance[]>;
}

/** The substrate's read surface: the undrained outbox, replayed into the mailbox so an in-flight event is not
 *  lost across a restart. */
export interface OutboxLoader {
  pending(): Promise<OutboxMessage[]>;
}

/** The per-owner read surface, symmetric to `PersistenceTx`: the base-managed edges through `loader.base`
 *  (via `Reactor.loadBase`), each reactor's own data through `loader.<name>`, the outbox replay through
 *  `loader.outbox`. The engine graph rebuilds the core store; routing is rederived from the surviving
 *  `DelegateThread`s and instance `delegationId`s. (Scopes / blobs ride in `core.engine()` into the shared
 *  store, which the pool then reads — it has no separate load.) */
export interface Loader {
  base: BaseLoader;
  core: CoreLoader;
  api: ApiLoader;
  ffi: FfiLoader;
  http: HttpLoader;
  outbox: OutboxLoader;
}

export interface Persistence {
  /** Reactivate a project: open a read, hand each reactor a `Loader` to pull the rows it owns, replay the
   *  outbox. The body restores the warm reactors + enqueues the undrained outbox. */
  load(projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void>;
  /** Run one turn's writes atomically: open a transaction, hand the reactor + substrate a `PersistenceTx`,
   *  and commit. The body issues the reactor's `persist(tx)` and the outbox consume / produce. */
  transaction(projectId: ProjectId, body: (tx: PersistenceTx) => Promise<void>): Promise<void>;
}

/** The seam implementation: the warm store is the truth, so nothing persists and nothing loads. */
export class InMemoryPersistence implements Persistence {
  async load(_projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void> {
    // Nothing was stored, so every query is empty; the warm reactors come up clean.
    await body(EMPTY_LOADER);
  }
  async transaction(
    _projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    // Nothing is stored; the tx methods are no-ops. The body still runs (it has no other effect), so a
    // reactor's `persist` and the outbox writes execute against a sink — the warm maps remain the truth.
    await body(NO_OP_TX);
  }
}

/** A fully no-op `PersistenceTx` — the in-memory backend's write surface (the warm store is the truth), and a
 *  convenient base a test can spread and override one port of. */
export const NO_OP_TX: PersistenceTx = {
  base: {
    async putInstanceEnvelope() {},
    async putDelegation() {},
    async deleteDelegation() {},
    async putEscalation() {},
    async deleteEscalation() {},
    async dropInstance() {},
  },
  core: {
    async putCoreInstance() {},
  },
  api: {
    async putRun() {},
    async setRunOutcome() {},
    async putRunEscalationAudit() {},
  },
  ffi: {
    async putFfiInstance() {},
  },
  http: {
    async putHttpInstance() {},
  },
  pool: {
    async putScope() {},
    async deleteScope() {},
    async putBlob() {},
    async dropBlob() {},
  },
  outbox: {
    async consumeOutbox() {},
    async produceOutbox() {},
  },
  journal: {
    async appendEvents() {},
  },
};

const EMPTY_LOADER: Loader = {
  base: {
    async delegations() {
      return [];
    },
    async raisedEscalations() {
      return [];
    },
  },
  core: {
    async engine() {
      return { instances: {}, scopes: {}, blobs: {}, nextScopeId: 0 };
    },
  },
  api: {
    async answerableEscalations() {
      return [];
    },
  },
  ffi: {
    async instances() {
      return [];
    },
  },
  http: {
    async instances() {
      return [];
    },
  },
  outbox: {
    async pending() {
      return [];
    },
  },
};
