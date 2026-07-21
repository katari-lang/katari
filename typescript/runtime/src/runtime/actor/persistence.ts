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
// The latter two share one turn-commit implementation over a `RowStore` (see `row-store.ts`), so their
// semantics cannot drift; only the row CRUD differs.
//
// External calls persist through ONE parametric port pair (`ExternalTx` / `ExternalLoader`): every call
// reactor's durable unit is the same shape — envelope + status + a kind-specific extension document —
// and the port never learns what is inside the document. Its type lives in the owning reactor's pure
// codec (`encode…Extension` / `decode…Extension`), so a new call reactor is a codec, not a port change.

import type { Json } from "@katari-lang/types";
import type { DelegationState, ExternalCallStatus, RunState } from "../../db/tables/execution.js";
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

/** A raiser-owned (open) escalation row (the `escalations` table shape). The row exists only while open
 *  (answering deletes it — the Q&A lives in the audit). `fromReactor` (the raiser's reactor) / `toReactor`
 *  (the reactor the escalate was addressed to) let each reactor self-select on restart — `toReactor = "api"`
 *  ⟺ the raiser is a run root (a user-facing escalation). `delegation` is the raiser's delegation (the
 *  answer's routing); `run` is the run instance it belongs to (its attribution). */
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

/** A persisted open escalation as a reactivation reads it — the same shape the raiser wrote (see
 *  `PersistedEscalation`), re-exported under the read-side name the loaders and tests use. */
export type PersistedOpenEscalation = PersistedEscalation;

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

/** One resolved escalation, recorded for the run's history (`run_escalations_audit`) — live escalations are
 *  open-only and raiser-owned, so the resolved ones live as this projection. The audit is the complete log
 *  of resolved escalations: an ANSWERED user-facing request carries its answer; a FAILED / cancelled one (a
 *  panic / throw / control escape the api resolved by failing the run) carries a `null` answer (the failure
 *  text lives on `runs.error`). The `answer` column is nullable to hold that failure case. */
export interface PersistedRunEscalationAudit {
  run: InstanceId;
  escalation: EscalationId;
  question: Value | null;
  answer: Value | null;
}

/** The envelope half every reloaded in-flight call shares (the join key + routing): `delegation` keys the
 *  reactor's warm call, `instance` is the call's own id (the issuer on its replies), `caller` is the
 *  reactor to reply to, and `run` is the run the call belongs to (its trace context). */
export interface PersistedCallEnvelope {
  delegation: DelegationId;
  instance: InstanceId;
  caller: ReactorName;
  run: InstanceId;
}

/** One external call's own-data write (`external_call_instances`) — the precise `status` (the envelope
 *  collapses `awaitingAnswer` to `running`) plus the kind-specific `extension` document the owning
 *  reactor's codec produced. The port does not know what is inside the document; it only seals it whole. */
export interface PersistedExternalCallRow {
  instanceId: InstanceId;
  status: ExternalCallStatus;
  extension: Json;
}

/** One in-flight external call a reactivation reads (envelope ⋈ `external_call_instances`). The `extension`
 *  is the raw (unsealed) document; the owning reactor's codec gives it back its type. */
export interface PersistedExternalCall extends PersistedCallEnvelope {
  status: ExternalCallStatus;
  extension: Json;
}

/** One capability-token route (`capability_routes`): the public token → the instance serving it. An index
 *  for cold inbound routing, not a SoT — the token also lives in the call's extension document, and the
 *  row dies with its instance (FK cascade), so there is no delete on this port. */
export interface PersistedCapabilityRoute {
  token: string;
  instance: InstanceId;
}

/** The base-class write surface: the generic state every reactor's base owns — the instance envelope, the
 *  caller-owned delegations, the raiser-owned escalations, and the cascade drop. A concrete reactor never
 *  touches this directly; it goes through `Reactor.persistBase`, so the protocol is uniform. */
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
   *  delegations / raised escalations / capability routes (mirrors the tables' ON DELETE CASCADE). */
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

/** Every call reactor's *own-data* write surface — the one `external_call_instances` extension row per
 *  call (the envelope is base). The kind is not passed: the envelope's `kind` (written by the same
 *  reactor's base) is the SoT for who owns the row. */
export interface ExternalTx {
  putCall(row: PersistedExternalCallRow): Promise<void>;
}

/** The capability-route write surface — the token-minting reactors (webhook / mcp-serve) maintain their
 *  routing index here, in the same commit as the call row. Upsert-only: a route is immutable while its
 *  instance lives and dies with it by cascade. */
export interface RouteTx {
  putRoute(route: PersistedCapabilityRoute): Promise<void>;
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
 *  (via `Reactor.persistBase`), core / api their own extensions, every call reactor the one `tx.external`,
 *  the pool through `tx.pool`, the substrate through `tx.outbox` / `tx.journal`. So a concrete reactor's
 *  `persist` is `persistBase(tx.base, …)` plus its own data — the generic half is written in exactly one
 *  place, and the external half through exactly one port. */
export interface PersistenceTx {
  base: BaseTx;
  core: CoreTx;
  api: ApiTx;
  external: ExternalTx;
  routes: RouteTx;
  pool: PoolTx;
  outbox: OutboxTx;
  journal: JournalTx;
}

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
  /** The delegations that summoned this reactor's instances (`to = core`) — the caller-side rows core does
   *  NOT own when a webhook / mcp / ffi reactor issued the delegate. Core reads them on load to re-derive
   *  each reloaded instance's caller INSTANCE (the blob-hoist target) from the durable
   *  `delegations.caller_instance_id`, so an upward event still hoists after a restart. */
  summoningDelegations(): Promise<PersistedDelegation[]>;
}

/** The `api` reactor's own-data read surface: the escalations *addressed to* it (`to = api`) — its answerable
 *  set, a projection of core-raised rows, not edges it owns (those come through `BaseLoader`). */
export interface ApiLoader {
  answerableEscalations(): Promise<PersistedOpenEscalation[]>;
  /** The MACHINE-ANSWERED escalations addressed to it (`to = api`, a `prelude.store.*` request): an
   *  unhandled store request whose runtime answer was interrupted by a crash before the `escalateAck`
   *  committed. The reactivation re-answers each (idempotent — re-read yields the same value, re-write is
   *  last-write-wins), so the run resumes. Disjoint from `answerableEscalations` (the user-facing filter
   *  excludes store), so the two together cover every open `to = api` row exactly once. */
  machineAnswerableEscalations(): Promise<PersistedOpenEscalation[]>;
}

/** Every call reactor's own-data read surface: its in-flight calls (envelope ⋈ `external_call_instances`,
 *  self-selected by the envelope's `kind` = the reactor's name). What a reactor does with a reloaded call
 *  is its recovery policy, decoded from the extension: fail at-most-once (http, a bare mcp transport call),
 *  re-register a token / scope (webhook, mcp serve / provide), re-arm a timer (time), reconcile with a
 *  possibly-surviving process (ffi), reconstruct a park (a parked mcp call). */
export interface ExternalLoader {
  instances(reactor: ReactorName): Promise<PersistedExternalCall[]>;
}

/** The substrate's read surface: the undrained outbox, replayed into the mailbox so an in-flight event is not
 *  lost across a restart. */
export interface OutboxLoader {
  pending(): Promise<OutboxMessage[]>;
}

/** The per-owner read surface, symmetric to `PersistenceTx`: the base-managed edges through `loader.base`
 *  (via `Reactor.loadBase`), core / api / the call reactors through their ports, the outbox replay through
 *  `loader.outbox`. The engine graph rebuilds the core store; routing is rederived from the surviving
 *  `DelegateThread`s and instance `delegationId`s. (Scopes / blobs ride in `core.engine()` into the shared
 *  store, which the pool then reads — it has no separate load. Capability routes are never loaded: warm
 *  re-registration reads the token from the extension document, its SoT.) */
export interface Loader {
  base: BaseLoader;
  core: CoreLoader;
  api: ApiLoader;
  external: ExternalLoader;
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
  external: {
    async putCall() {},
  },
  routes: {
    async putRoute() {},
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
    async summoningDelegations() {
      return [];
    },
  },
  api: {
    async answerableEscalations() {
      return [];
    },
    async machineAnswerableEscalations() {
      return [];
    },
  },
  external: {
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
