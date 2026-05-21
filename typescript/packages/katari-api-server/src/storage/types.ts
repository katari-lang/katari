// Persistence layer interfaces.
//
// `katari-api-server` always talks to storage through these interfaces. The
// production binding is Postgres (`pg.ts`); tests use `memory-storage.ts`
// for hermeticity. Adding a new backend means only implementing `Storage`.
//
// Naming conventions (finalized in this plan):
//   - `Project` / `ProjectId`     — top-level deploy unit (e.g. one app)
//   - `Snapshot` / `SnapshotId`   — output of one `apply` (IR + sidecar JS +
//                                    schema). Multiple snapshots per project.
//   - `EngineCheckpoint`          — frozen engine-internal state (per-snapshot)
//                                    — defined on the runtime side
//   - `FfiPendingDelegation`      — pending delegation held by the FFI Runner
//   - `FfiPendingEscalation`      — pending escalation held by the FFI Runner
//   - `ApiPendingEscalation`      — pending user-bound escalation held by the API module
//                                    (= DB representation of an AI -> user question)
//
// "agent" itself corresponds directly to the existing `agents` table as the
// persistence of "delegation from API module to CORE". Use delegationId as the key.

import type {
  DelegationId,
  EscalationId,
  EngineCheckpoint,
  IRModule,
  SchemaBundle,
  Value,
  AgentDefId,
} from "@katari-lang/runtime";

export type { EscalationId };

// ─── Brands ────────────────────────────────────────────────────────────────

export type ProjectId = string & { readonly __brand: "ProjectId" };
export type SnapshotId = string & { readonly __brand: "SnapshotId" };
export type AgentId = string & { readonly __brand: "AgentId" };

/**
 * Lifecycle states an agent (= API→CORE delegation row) can be in.
 * Mirrors the previous schema 1:1.
 */
export type AgentState =
  | "running"
  | "cancelling"
  | "cancelled"
  | "succeeded"
  | "error";

// ─── Project ───────────────────────────────────────────────────────────────

export type Project = {
  id: ProjectId;
  name: string;
  createdAt: string;
};

export interface ProjectRepo {
  /** Idempotent: returns existing if name already exists, else creates. */
  upsertByName(name: string): Promise<Project>;
  list(options?: ListOptions): Promise<Project[]>;
  get(id: ProjectId): Promise<Project | null>;
  getByName(name: string): Promise<Project | null>;
  /** Throws via FK when snapshots are still attached. */
  delete(id: ProjectId): Promise<boolean>;
}

// ─── Snapshot (= deploy unit) ──────────────────────────────────────────────

/**
 * Sidecar bundle attached to a snapshot. `null` means the snapshot uses
 * no FFI (= `BlockExternal` blocks reach a sidecar that errors on every
 * invoke). `entry` is the bundled JS source string (CLI bundles it via
 * esbuild before upload). Mirrors `katari-runtime/src/sidecar/types.ts`.
 */
export type SidecarBundle = {
  entry: string;
  runtime: "node";
  schemaVersion: 1;
};

export type Snapshot = {
  id: SnapshotId;
  projectId: ProjectId;
  irModule: IRModule;
  sidecarBundle: SidecarBundle | null;
  schemaBundle: SchemaBundle;
  createdAt: string;
};

export type SnapshotSummary = {
  id: SnapshotId;
  projectId: ProjectId;
  createdAt: string;
};

export interface SnapshotRepo {
  insert(input: {
    projectId: ProjectId;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
  }): Promise<SnapshotId>;
  get(id: SnapshotId): Promise<Snapshot | null>;
  list(
    filter?: { projectId?: ProjectId } & ListOptions,
  ): Promise<SnapshotSummary[]>;
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

// ─── Agents (= API → CORE delegation rows) ─────────────────────────────────
//
// "agent" is the persistence destination of the API module's
// `pendingDelegateOut` (CORE-bound). Read id = delegationId.

export type AgentRow = {
  id: AgentId;
  /** Same value as `id`, kept for API compatibility. */
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  qualifiedName: string;
  args: Record<string, Value>;
  state: AgentState;
  result?: Value;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
};

export interface AgentRepo {
  insert(row: AgentRow): Promise<void>;
  get(id: AgentId): Promise<AgentRow | null>;
  findByDelegationId(delegationId: DelegationId): Promise<AgentRow | null>;
  list(
    filter?: {
      snapshotId?: SnapshotId;
      state?: AgentState;
      afterId?: AgentId;
    } & ListOptions,
  ): Promise<AgentRow[]>;
  setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
    options?: { expectedState?: AgentState },
  ): Promise<boolean>;
  markAllRunningAsError(snapshotId: SnapshotId, message: string): Promise<void>;
  /** Distinct snapshot ids that still have at least one running/cancelling agent. */
  listRunningSnapshotIds(): Promise<SnapshotId[]>;
}

// ─── FFI module persistent state ───────────────────────────────────────────
//
// The FFI Runner holds a sidecar per-snapshot. The Runner's own in-memory
// state is only the subprocess pid level; in-flight delegation / escalation
// is written to the DB. On server restart, the FFI Runner reads these and
// notifies the sidecar via a `restored` IPC event.

export type FfiPendingDelegation = {
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  /** Endpoint to send acks to (= normally CORE). */
  peerEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
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
  setState(
    delegationId: DelegationId,
    state: "running" | "cancelling",
  ): Promise<boolean>;
  delete(delegationId: DelegationId): Promise<boolean>;
  listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingDelegation[]>;
  /** Children of a given ext-call delegation (= parentExtDelegationId match). */
  listChildrenOf(
    parentDelegationId: DelegationId,
  ): Promise<FfiPendingDelegation[]>;
}

export type FfiPendingEscalation = {
  escalationId: EscalationId;
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  /** Endpoint to send acks to (= normally via sidecar = expected from the CORE side). */
  peerEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
  createdAt: string;
};

export interface FfiPendingEscalationRepo {
  insert(row: FfiPendingEscalation): Promise<void>;
  get(escalationId: EscalationId): Promise<FfiPendingEscalation | null>;
  delete(escalationId: EscalationId): Promise<boolean>;
  listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingEscalation[]>;
}

// ─── API module persistent state ───────────────────────────────────────────
//
// API module = user's proxy endpoint. pendingDelegateOut is handled directly
// by the `agents` table (= agents launched by the CLI). pendingEscalateIn is
// the queue that holds "AI -> user questions".

export type ApiPendingEscalation = {
  escalationId: EscalationId;
  /** Which delegation fired this (= from which agent). */
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
  /** "open" = awaiting user reply / "answered" = already escalateAck'd / "cancelled" */
  state: "open" | "answered" | "cancelled";
  /** Set when state === "answered". */
  value?: Value;
  createdAt: string;
};

export interface ApiPendingEscalationRepo {
  insert(row: ApiPendingEscalation): Promise<void>;
  get(escalationId: EscalationId): Promise<ApiPendingEscalation | null>;
  list(
    filter?: { snapshotId?: SnapshotId; state?: ApiPendingEscalation["state"] }
      & ListOptions,
  ): Promise<ApiPendingEscalation[]>;
  setAnswered(escalationId: EscalationId, value: Value): Promise<boolean>;
  setCancelled(escalationId: EscalationId): Promise<boolean>;
}

// ─── Pagination ────────────────────────────────────────────────────────────

export type ListOptions = {
  limit?: number;
  offset?: number;
};

// ─── Storage facade ────────────────────────────────────────────────────────

export interface Storage {
  projects: ProjectRepo;
  snapshots: SnapshotRepo;
  checkpoints: EngineCheckpointRepo;
  agents: AgentRepo;
  ffiDelegations: FfiPendingDelegationRepo;
  ffiEscalations: FfiPendingEscalationRepo;
  apiEscalations: ApiPendingEscalationRepo;

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
   *               No placeholder row is required; the advisory key is
   *               derived from the snapshot id and released automatically
   *               at tx end.
   *   - Memory:   per-snapshot Mutex map internal to the implementation.
   *
   * `withSnapshotLock` MUST be called inside `withTransaction` so the
   * advisory lock is bound to the surrounding tx lifetime.
   */
  withSnapshotLock<T>(
    tx: Storage,
    snapshotId: SnapshotId,
    fn: () => Promise<T>,
  ): Promise<T>;

  close?(): Promise<void>;
}
