// Persistence layer interfaces.
//
// `katari-api-server` always talks to storage through these interfaces. The
// production binding is Postgres (`pg.ts`); tests use `memory-storage.ts`
// for hermeticity. Adding a new backend means only implementing `Storage`.
//
// Naming conventions (本 plan で確定):
//   - `Project` / `ProjectId`     — top-level deploy unit (e.g. one app)
//   - `Snapshot` / `SnapshotId`   — one `apply` の成果物 (IR + sidecar JS +
//                                    schema)。1 project に複数 snapshot。
//   - `EngineCheckpoint`          — engine 内部 state の凍結 (per-snapshot)
//                                    — runtime 側で定義
//   - `FfiPendingDelegation`      — FFI Runner が抱える未完 delegation
//   - `FfiPendingEscalation`      — FFI Runner が抱える未完 escalation
//   - `ApiPendingEscalation`      — API module が抱える、ユーザー宛の未答 escalation
//                                    (= AI から user への質問の DB 表現)
//
// "agent" 自体は「API module から CORE への delegation」の永続化として
// 既存 `agents` テーブルが直接対応する。delegationId をそのままキーに使う。

import type {
  DelegationId,
  EscalationId,
  EngineCheckpoint,
  IRModule,
  SchemaBundle,
  Value,
  AgentDefId,
} from "katari-runtime";

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
  /** project 内の最新 snapshot id。空なら null。 */
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
// 「agent」は API module の `pendingDelegateOut` (CORE 宛) の永続化先。
// id = delegationId と読み替えて良い。

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
// FFI Runner は per-snapshot で sidecar を抱える。Runner 自身の in-memory state
// は subprocess pid 程度で、in-flight delegation / escalation は DB に書く。
// サーバ再起動時に FFI Runner がこれらを読んで `restored` IPC event で sidecar
// に通知。

export type FfiPendingDelegation = {
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  /** ack を返す先 endpoint (= 通常 CORE)。 */
  peerEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
  state: "running" | "cancelling";
  createdAt: string;
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
}

export type FfiPendingEscalation = {
  escalationId: EscalationId;
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  /** ack を返す先 endpoint (= 通常 sidecar 経由 = CORE 側からの想定)。 */
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
// API module = ユーザーの代理 endpoint。pendingDelegateOut は `agents`
// テーブルがそのまま担当 (= CLI が起動した agent)。pendingEscalateIn は
// 「AI から user への質問」を保持するキュー。

export type ApiPendingEscalation = {
  escalationId: EscalationId;
  /** どの delegation の中で発火したか (= どの agent から)。 */
  delegationId: DelegationId;
  snapshotId: SnapshotId;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
  /** "open" = ユーザー回答待ち / "answered" = 既に escalateAck 済 / "cancelled" */
  state: "open" | "answered" | "cancelled";
  /** state === "answered" のとき設定。 */
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
   * Run `fn` while holding a snapshot-level row lock. Used by the
   * stateless orchestrator to serialize CORE state mutation per snapshot.
   *
   *   - Postgres: `SELECT ... FROM engine_checkpoints WHERE snapshot_id = $1 FOR UPDATE`
   *   - Memory:   per-snapshot Mutex map internal to the implementation.
   *
   * The lock is released when the surrounding transaction commits or
   * rolls back. `withSnapshotLock` MUST be called inside `withTransaction`.
   */
  withSnapshotLock<T>(
    tx: Storage,
    snapshotId: SnapshotId,
    fn: () => Promise<T>,
  ): Promise<T>;

  close?(): Promise<void>;
}
