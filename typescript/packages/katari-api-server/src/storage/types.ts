// Persistence layer interfaces.
//
// `katari-api-server` always talks to storage through these interfaces. The
// production binding is Postgres (`pg.ts`); tests use `memory-storage.ts`
// for hermeticity. Adding a new backend means only implementing `Storage`.
//
// Conceptual model (v0.1.0 — Entity model, see docs/2026-06-01-entity-model.md):
//   - `Project`     — top-level deploy unit (one project = one app)
//   - `Snapshot`    — one `apply`'s frozen IR + sidecar + schema + message
//   - `Entity`      — the RECEIVER-managed execution node (ownership/cascade
//                     root). Minted by the module that processes a `delegate`,
//                     self-deleted on terminal. Refs + escalations hang off it.
//   - `Delegation`  — the ISSUER-managed request edge. Created by the parent on
//                     `delegate` emit, deleted on the result ack. Carries the
//                     parent link (`parentEntityId` = the issuer's OWN entity).
//   - `Escalation`  — a live capability request, owned by the entity that RAISED
//                     it (`state = open` only; terminal = the row is deleted).
//   - `Run`         — the API module's per-run management record (running /
//                     cancelling / done / error), 1:1 with a run-root entity.
//   - `ValueStore`  — refs (entity-owned blob handles) + value_blobs ledger.

import type {
  AgentDefId,
  DelegationId,
  EncryptedValue,
  EngineCheckpoint,
  EntityId,
  EscalationId,
  ProjectIndexStore,
  ShardStore,
  ValueStore,
} from "@katari-lang/runtime";
import type { IRModule, SchemaBundle, SidecarBundle } from "@katari-lang/types";

export type {
  DelegationId,
  EntityId,
  EscalationId,
  ProjectIndexStore,
  ShardStore,
  SidecarBundle,
  ValueStore,
};

// ─── Brands ────────────────────────────────────────────────────────────────

export type ProjectId = string & { readonly __brand: "ProjectId" };
export type SnapshotId = string & { readonly __brand: "SnapshotId" };

/** A run's id = its run-root entity id (the API keeps that entity as the run). */
export type RunId = EntityId;

// ─── States ────────────────────────────────────────────────────────────────

/** The module that runs an entity (the 4 katari-protocol endpoints). */
export type EntityModule = "core" | "ffi" | "api" | "env";

/**
 * The only entity / delegation states. Terminal (done / error) is NOT an entity
 * state — it lives on the `Run` record. Entity rows are physically deleted on
 * the terminal ack (the receiver self-deletes); delegation rows on the issuer's
 * ack-receipt.
 */
export type EntityState = "running" | "cancelling";
export type DelegationState = "running" | "cancelling";

/**
 * Operator-visible state for a run. It reflects the run's CHILD CORE-root
 * delegation, not the run-root entity's own state:
 *   - done:        `delegateAck` on the CORE root
 *   - error:       a child throw cascade (`cancelReason = 'error'`)
 *   - cancelling:  a cancel is in flight
 */
export type RunState = "running" | "cancelling" | "done" | "error";

export type CancelReason = "user" | "error";

// ─── Project ───────────────────────────────────────────────────────────────

export type Project = {
  id: ProjectId;
  name: string;
  /** One-line description from `katari.toml` `[package].description`.
   *  `null` when the operator hasn't set one. */
  description: string | null;
  /** Long-form README, picked up from `README.md` sibling of
   *  `katari.toml` on `apply`. `null` when no file is present. */
  readme: string | null;
  createdAt: string;
};

/** Input to `upsertProject`. Name is the identity key; description and
 *  readme are reconciler fields — they OVERWRITE the stored values on
 *  every call so `katari apply` keeps the runtime in sync with the
 *  operator's repo. `undefined` for either means "don't touch this
 *  field" (= partial update), `null` means "clear it". */
export type UpsertProjectInput = {
  name: string;
  description?: string | null;
  readme?: string | null;
};

export interface ProjectRepo {
  /** Idempotent on `name`. Description / readme are overwritten when
   *  provided so the toml-driven reconciler model holds. */
  upsertProject(input: UpsertProjectInput): Promise<Project>;
  list(options?: ListOptions): Promise<ListResult<Project>>;
  get(id: ProjectId): Promise<Project | null>;
  getByName(name: string): Promise<Project | null>;
  /** Throws via FK when snapshots are still attached. */
  delete(id: ProjectId): Promise<boolean>;
}

// ─── Snapshot (= deploy unit) ──────────────────────────────────────────────

export type Snapshot = {
  id: SnapshotId;
  projectId: ProjectId;
  irModule: IRModule;
  sidecarBundle: SidecarBundle | null;
  schemaBundle: SchemaBundle;
  /** Commit-message-like free text. Filled with a sensible default
   *  (`"snapshot @ YYYY-MM-DD HH:mm"`) by the server when the operator
   *  omits one, so this is always a non-empty string. */
  message: string;
  createdAt: string;
};

export type SnapshotSummary = {
  id: SnapshotId;
  projectId: ProjectId;
  message: string;
  createdAt: string;
};

export interface SnapshotRepo {
  insert(input: {
    projectId: ProjectId;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
    message: string;
  }): Promise<SnapshotId>;
  get(id: SnapshotId): Promise<Snapshot | null>;
  list(filter?: { projectId?: ProjectId } & ListOptions): Promise<ListResult<SnapshotSummary>>;
  /** Latest snapshot id within a project. `null` if empty. */
  latest(projectId: ProjectId): Promise<SnapshotId | null>;
  delete(id: SnapshotId): Promise<boolean>;
}

// ─── Engine checkpoint (CORE module state) ─────────────────────────────────

export interface EngineCheckpointRepo {
  upsert(snapshotId: SnapshotId, checkpoint: EngineCheckpoint): Promise<void>;
  get(snapshotId: SnapshotId): Promise<EngineCheckpoint | null>;
  delete(snapshotId: SnapshotId): Promise<void>;
}

// ─── Entities (= the execution node) ───────────────────────────────────────
//
// Created by the module that RECEIVES a `delegate` (it mints `E`), from the bus
// event + ambient context alone — it never reads the issuer's tables. Carries no
// parent/root link (those are off-server); the parent link is on the issuer-side
// `Delegation` row. Self-deleted on terminal (its refs + escalations cascade).

export type EntityRow = {
  /** Entity identity `E`, minted by the receiver (synthetic for the project root). */
  id: EntityId;
  /** The summoning delegation `D` (from the bus). `null` only for the project root. */
  delegationId: DelegationId | null;
  projectId: ProjectId;
  /** The module that runs this entity (self). */
  module: EntityModule;
  state: EntityState;
  /** What the entity runs (from the bus). `null` for the project root. */
  agentDefId: AgentDefId | null;
  args: Record<string, EncryptedValue>;
  createdAt: string;
  updatedAt: string;
};

export interface EntityRepo {
  insert(row: EntityRow): Promise<void>;
  get(id: EntityId): Promise<EntityRow | null>;
  /** Resolve bus `D → E` (the receiver's entity for a delegation). */
  getByDelegation(projectId: ProjectId, delegationId: DelegationId): Promise<EntityRow | null>;
  setState(
    id: EntityId,
    state: EntityState,
    options?: { expectedState?: EntityState },
  ): Promise<boolean>;
  /**
   * Self-delete (terminal). Cascades the entity's still-owned refs + raised
   * escalations (FK); the refs-delete trigger keeps blob refcounts correct.
   * Freed bytes are reclaimed separately by `ValueStore.reapFreedBlobs`.
   */
  delete(id: EntityId): Promise<boolean>;
  list(
    filter?: {
      projectId?: ProjectId;
      module?: EntityModule;
      state?: EntityState;
    } & ListOptions,
  ): Promise<ListResult<EntityRow>>;
}

// ─── Delegations (= the request edge) ──────────────────────────────────────
//
// Issuer-managed: the parent INSERTs at `delegate` emit and DELETEs on the
// result ack. `parentEntityId` is the issuer's OWN entity (known locally). The
// receiver never touches this row. lifetime(delegation) ⊇ lifetime(entity).

export type DelegationRow = {
  id: DelegationId;
  projectId: ProjectId;
  /** The issuer's own entity `E` (the parent link; local to the issuer). */
  parentEntityId: EntityId;
  /** The endpoint the delegate was addressed to (which module runs the child). */
  targetModule: EntityModule;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: DelegationState;
  createdAt: string;
  updatedAt: string;
};

export interface DelegationRepo {
  insert(row: DelegationRow): Promise<void>;
  get(id: DelegationId): Promise<DelegationRow | null>;
  setState(
    id: DelegationId,
    state: DelegationState,
    options?: { expectedState?: DelegationState },
  ): Promise<boolean>;
  delete(id: DelegationId): Promise<boolean>;
  list(
    filter?: {
      projectId?: ProjectId;
      parentEntityId?: EntityId;
      state?: DelegationState;
    } & ListOptions,
  ): Promise<ListResult<DelegationRow>>;
}

// ─── Escalations (= a live capability request, raiser-owned) ───────────────
//
// Owned by the entity that RAISED it (`entityId`). `state` is `open` only —
// answered / cancelled are terminal = the row is deleted (the raiser self-deletes
// on escalateAck; cancel cascades when the raiser entity is terminated). The
// history of answered, user-facing ones lives under the run
// (`run_escalations_audit`).

export type EscalationRow = {
  id: EscalationId;
  /** The raising entity (owner). */
  entityId: EntityId;
  projectId: ProjectId;
  /** The requested capability / `request` (same slot a delegate uses). */
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  createdAt: string;
};

export interface EscalationRepo {
  insert(row: EscalationRow): Promise<void>;
  get(id: EscalationId): Promise<EscalationRow | null>;
  delete(id: EscalationId): Promise<boolean>;
  list(
    filter?: {
      projectId?: ProjectId;
      entityId?: EntityId;
    } & ListOptions,
  ): Promise<ListResult<EscalationRow>>;
}

// ─── Runs (= the API module's per-run management record) ───────────────────
//
// 1:1 with a run-root entity (`id = E_run`). Its state reflects the run's CHILD
// CORE-root delegation. `coreDelegationId` = the `D` the run-root issued to the
// CORE root (so a delegateAck/terminateAck routes back here, and cancel/recovery
// can re-issue terminate). Kept as run history.

export type RunRow = {
  /** = the run-root entity id `E_run`. */
  id: RunId;
  projectId: ProjectId;
  snapshotId: SnapshotId;
  /** The `D` from run-root → CORE root. */
  coreDelegationId: DelegationId;
  /** Display label (defaulted server-side, always non-empty). */
  name: string;
  qualifiedName: string;
  args: Record<string, EncryptedValue>;
  state: RunState;
  /** Set on `running → cancelling`; persists through the terminal state. */
  cancelReason: CancelReason | null;
  result?: EncryptedValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
};

export interface RunRepo {
  insert(row: RunRow): Promise<void>;
  get(id: RunId): Promise<RunRow | null>;
  /** Resolve the run that issued `coreDelegationId` (the CORE-root ack target). */
  getByCoreDelegation(coreDelegationId: DelegationId): Promise<RunRow | null>;
  setState(
    id: RunId,
    patch: {
      state: RunState;
      cancelReason?: CancelReason | null;
      result?: EncryptedValue;
      errorMessage?: string;
      completedAt?: string;
    },
  ): Promise<boolean>;
  list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      state?: RunState;
    } & ListOptions,
  ): Promise<ListResult<RunRow>>;
}

// ─── Run escalations (the API's per-run operator-facing view) ──────────────
//
// One row per escalation that reached the API (mapped to its run via the bus
// `delegationId = D_core`). Both PENDING (`answer === undefined`) and ANSWERED.
// The live `escalations` row (raiser-owned, for cascade) is CORE's; this is the
// API's operator view + history, written from bus events (its OWN tables only).

export type RunEscalationAuditRow = {
  runId: RunId;
  escalationId: EscalationId;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  /** `undefined` while pending; set on answer. */
  answer?: EncryptedValue;
  createdAt: string;
  /** `undefined` while pending; set on answer. */
  answeredAt?: string;
};

export interface RunEscalationsAuditRepo {
  /** Record a pending operator-facing escalation (idempotent on escalationId). */
  insert(row: RunEscalationAuditRow): Promise<void>;
  get(escalationId: EscalationId): Promise<RunEscalationAuditRow | null>;
  /** Set the answer (PENDING → ANSWERED). Returns false if unknown. */
  setAnswer(
    escalationId: EscalationId,
    answer: EncryptedValue,
    answeredAt: string,
  ): Promise<boolean>;
  list(runId: RunId): Promise<RunEscalationAuditRow[]>;
}

// ─── FFI sidecar relay state (private to FFI Module) ───────────────────────
//
// The FFI Runner holds a sidecar per-snapshot. Its in-flight delegation /
// escalation relay rows are written here; on restart the FFI Runner reads them
// and notifies the sidecar. Operational bookkeeping, distinct from the protocol
// entity layer (the tree assembler reads `entities`, not these).

export type FfiPendingDelegation = {
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  /** Endpoint to send acks to (= normally CORE). */
  peerEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: "running" | "cancelling";
  createdAt: string;
  /**
   * Non-null when this delegation was started by an ext handler via
   * `katari.delegate(...)`. Points at the ext invocation that owns it
   * so the FfiModule can route escalate relays and terminate orphans
   * on restart.
   */
  parentExtDelegationId: DelegationId | null;
};

export interface FfiPendingDelegationRepo {
  insert(row: FfiPendingDelegation): Promise<void>;
  get(delegationId: DelegationId): Promise<FfiPendingDelegation | null>;
  setState(delegationId: DelegationId, state: "running" | "cancelling"): Promise<boolean>;
  delete(delegationId: DelegationId): Promise<boolean>;
  listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingDelegation[]>;
  listChildrenOf(parentDelegationId: DelegationId): Promise<FfiPendingDelegation[]>;
  /** Snapshot ids that still own at least one in-flight ext delegation —
   *  the set whose sidecars boot recovery must respawn. */
  listLiveSnapshotIds(): Promise<SnapshotId[]>;
}

export type FfiPendingEscalation = {
  escalationId: EscalationId;
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  peerEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  createdAt: string;
};

export interface FfiPendingEscalationRepo {
  insert(row: FfiPendingEscalation): Promise<void>;
  get(escalationId: EscalationId): Promise<FfiPendingEscalation | null>;
  delete(escalationId: EscalationId): Promise<boolean>;
  listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingEscalation[]>;
}

// ─── Env entries ──────────────────────────────────────────────────────────
//
// Per-project key/value store backing EnvModule. Each project owns its own
// env space (keyed by project_id); shared across that project's snapshots
// (env outlives any single deploy). Secret entries hold AES-GCM ciphertext
// produced by the EnvModule; the storage layer sees only opaque strings.

export type EnvEntryRow = {
  key: string;
  value: string;
  isSecret: boolean;
  updatedAt: string;
};

export interface EnvEntryRepo {
  get(projectId: ProjectId, key: string): Promise<EnvEntryRow | null>;
  upsert(row: {
    projectId: ProjectId;
    key: string;
    value: string;
    isSecret: boolean;
  }): Promise<void>;
  delete(projectId: ProjectId, key: string): Promise<boolean>;
  list(projectId: ProjectId): Promise<EnvEntryRow[]>;
}

// ─── Pagination ────────────────────────────────────────────────────────────

export type ListOptions = {
  limit?: number;
  offset?: number;
  /** Opaque cursor from a previous `ListResult.nextCursor`. When
   *  provided, `offset` is ignored and the query resumes from the
   *  position encoded in the cursor. */
  cursor?: string;
};

/**
 * Paginated list response. Repos that support cursor-based pagination
 * return this instead of a bare array. `nextCursor` is `null` when
 * there are no more items.
 */
export type ListResult<T> = {
  items: T[];
  nextCursor: string | null;
};

// ─── Storage facade ────────────────────────────────────────────────────────

export interface Storage {
  projects: ProjectRepo;
  snapshots: SnapshotRepo;
  checkpoints: EngineCheckpointRepo;
  /** The execution node (receiver-managed; ownership/cascade root). */
  entities: EntityRepo;
  /** The request edge (issuer-managed). */
  delegations: DelegationRepo;
  /** Live capability requests, owned by their raiser entity. */
  escalations: EscalationRepo;
  /** The API module's per-run management records. */
  runs: RunRepo;
  /** Answered user-facing escalation history, kept under a run. */
  runEscalationsAudit: RunEscalationsAuditRepo;
  /** Private FFI sidecar relay state. */
  ffiDelegations: FfiPendingDelegationRepo;
  ffiEscalations: FfiPendingEscalationRepo;
  envEntries: EnvEntryRepo;
  /** refs (entity-owned blob handles) + value_blobs ledger. */
  values: ValueStore;
  /** Per-agent engine shards (keyed by entity id E). */
  shards: ShardStore;
  /** Project-local routing index for shards (bus id → shard E). */
  projectIndex: ProjectIndexStore;

  /**
   * Run `fn` inside a backend-native transaction. The `tx` argument exposes
   * the same repo facade; all calls participate in the same tx.
   */
  withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T>;

  /**
   * Run `fn` while holding a snapshot-level lock. Used by the
   * stateless orchestrator to serialize CORE state mutation per snapshot.
   *
   *   - Postgres: `pg_advisory_xact_lock(hashtext('snapshot:' || $1))`.
   *   - Memory:   per-snapshot Mutex map internal to the implementation.
   *
   * `withSnapshotLock` MUST be called inside `withTransaction` so the
   * advisory lock is bound to the surrounding tx lifetime.
   */
  withSnapshotLock<T>(tx: Storage, snapshotId: SnapshotId, fn: () => Promise<T>): Promise<T>;

  close?(): Promise<void>;
}
