// Persistence layer interfaces.
//
// `katari-api-server` always talks to storage through these interfaces. The
// production binding is Postgres (`pg.ts`); tests use `memory-storage.ts`
// for hermeticity. Adding a new backend means only implementing `Storage`.
//
// Conceptual model (v0.1.0):
//   - `Project`         — top-level deploy unit (one project = one app)
//   - `Snapshot`        — one `apply`'s frozen IR + sidecar + schema + message
//   - `EngineCheckpoint` — frozen CORE state per-snapshot (from runtime)
//   - `Delegation`      — one live execution entity (= in-flight call frame)
//                         created by `delegate` event, deleted on terminal ack.
//                         Same physical table for every Module; each Module's
//                         repo filters by `callerEndpoint = self`.
//   - `Escalation`      — one live escalation entity raised from inside a
//                         delegation. State terminal on answered / cancelled
//                         (cascade only — no standalone cancel API).
//   - `RunsAuditRow`    — ApiModule's persistent audit log of operator-launched
//                         root delegations. Survives terminal state so the UI
//                         can show "Run X succeeded with result Y".

import type {
  AgentDefId,
  DelegationId,
  EncryptedValue,
  EngineCheckpoint,
  EscalationId,
  ProjectIndexStore,
  ShardStore,
  ValueStore,
} from "@katari-lang/runtime";
import type { IRModule, SchemaBundle, SidecarBundle } from "@katari-lang/types";

export type {
  DelegationId,
  EscalationId,
  ProjectIndexStore,
  ShardStore,
  SidecarBundle,
  ValueStore,
};

// ─── Brands ────────────────────────────────────────────────────────────────

export type ProjectId = string & { readonly __brand: "ProjectId" };
export type SnapshotId = string & { readonly __brand: "SnapshotId" };

// ─── States ────────────────────────────────────────────────────────────────

/**
 * Live delegation state. Terminal (succeeded / cancelled / error) is not
 * representable here: rows are physically deleted on the terminal ack.
 * Operator-visible terminal state for root delegations lives in
 * `RunsAuditRow.state`.
 */
export type DelegationState = "running" | "cancelling";

export type EscalationState = "open" | "answered" | "cancelled";

/**
 * Operator-visible state for a "run" (= ApiModule-issued root delegation).
 * The 3 terminal states are reached via different paths:
 *   - succeeded:  `delegateAck` on the root
 *   - cancelled:  `terminateAck` after a user-initiated cancel (`cancelReason='user'`)
 *   - error:      `terminateAck` after a child-throw cascade   (`cancelReason='error'`)
 */
export type RunsAuditState = "running" | "cancelling" | "cancelled" | "error" | "succeeded";

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

// ─── Delegations (= live execution entities) ───────────────────────────────
//
// One physical `delegations` table; logical ownership is by Module. The
// Module that issued the `delegate` event (= `callerEndpoint`) writes the
// row, updates state, and deletes it on terminal ack. Every Module that
// might issue a `delegate` (CORE, FFI, API) writes through this same
// shape; EnvModule never delegates onward so it has no rows.

export type DelegationRow = {
  /** Entity identity. Set at delegate-event creation by the caller. */
  id: DelegationId;
  /** Denormalised: id of the topmost ancestor (= the run root). */
  rootDelegationId: DelegationId;
  /** One hop up. `null` when this row IS the root. */
  parentDelegationId: DelegationId | null;
  snapshotId: SnapshotId;
  /** Module that issued the delegate event. Owns writes for this row. */
  callerEndpoint: string;
  /** Module that runs this entity. */
  ownerEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: DelegationState;
  createdAt: string;
  updatedAt: string;
};

export interface DelegationRepo {
  insert(row: DelegationRow): Promise<void>;
  get(id: DelegationId): Promise<DelegationRow | null>;
  /**
   * List delegations matching the filter. All filter fields are optional;
   * supply none to retrieve every row (`tests` use this sparingly).
   *
   * Common patterns:
   *   - `{ rootDelegationId }` — tree assembly for one run
   *   - `{ callerEndpoint, rootDelegationId }` — one Module's slice of a tree
   *   - `{ callerEndpoint, snapshotId }` — Module-local snapshot cleanup
   *   - `{ parentDelegationId }` — direct children (FFI ext-spawn lookup)
   */
  list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      callerEndpoint?: string;
      rootDelegationId?: DelegationId;
      parentDelegationId?: DelegationId;
      state?: DelegationState;
    } & ListOptions,
  ): Promise<ListResult<DelegationRow>>;
  /**
   * State transition with optional optimistic check. Returns true if a row
   * was updated.
   */
  setState(
    id: DelegationId,
    state: DelegationState,
    options?: { expectedState?: DelegationState },
  ): Promise<boolean>;
  /** Mark every row in a root subtree as `cancelling` (where currently `running`). */
  markAllUnderRootAsCancelling(rootDelegationId: DelegationId): Promise<void>;
  /** Drop the row at terminal ack (= success or cancel-complete). */
  delete(id: DelegationId): Promise<boolean>;
  /** Delete every row in a root subtree (root + all children). */
  deleteAllUnderRoot(rootDelegationId: DelegationId): Promise<void>;
  /** Snapshot ids that still own at least one live delegation. */
  listLiveSnapshotIds(): Promise<SnapshotId[]>;
}

// ─── Escalations (= live escalation entities) ──────────────────────────────
//
// Each row represents one in-flight `escalate` event raised inside a
// delegation. The Module that issued the escalate event (= the originator
// of the question, typically CORE for AI-to-user) owns the row. State
// reaches `cancelled` only via cascade when the parent delegation chain
// is cancelled; there is no standalone "cancel this escalation" path.

export type EscalationRow = {
  id: EscalationId;
  /** The delegation in which this escalation was raised. */
  delegationId: DelegationId;
  /** Denormalised: root of `delegationId`'s tree. */
  rootDelegationId: DelegationId;
  snapshotId: SnapshotId;
  /** Module that issued the escalate event. */
  callerEndpoint: string;
  /** Module the bus event was addressed to (= the would-be answerer). */
  receiverEndpoint: string;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: EscalationState;
  /** Set when state === "answered". */
  value?: EncryptedValue;
  createdAt: string;
};

export interface EscalationRepo {
  insert(row: EscalationRow): Promise<void>;
  get(id: EscalationId): Promise<EscalationRow | null>;
  list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      callerEndpoint?: string;
      receiverEndpoint?: string;
      rootDelegationId?: DelegationId;
      delegationId?: DelegationId;
      state?: EscalationState;
    } & ListOptions,
  ): Promise<ListResult<EscalationRow>>;
  setAnswered(id: EscalationId, value: EncryptedValue): Promise<boolean>;
  /**
   * Mark every open escalation in a root subtree as `cancelled`. Called by
   * the cancel cascade — never invoked by single-escalation operations.
   */
  cancelAllUnderRoot(rootDelegationId: DelegationId): Promise<void>;
  /** Drop the row (= used by ext-side relays that are restart-wiped). */
  delete(id: EscalationId): Promise<boolean>;
}

// ─── Runs audit (= ApiModule persistent log) ───────────────────────────────
//
// One row per operator-launched root delegation. Created alongside the
// live `delegations` row in startRun; survives the live row's terminal
// deletion to retain audit history (state / result / cancel reason).

export type RunsAuditRow = {
  /** = root delegation id. */
  id: DelegationId;
  snapshotId: SnapshotId;
  /** Display label. Filled with a sensible default
   *  (`"<qualifiedName> @ HH:mm"`) by the server when the operator
   *  omits one, so this is always a non-empty string. */
  name: string;
  qualifiedName: string;
  args: Record<string, EncryptedValue>;
  state: RunsAuditState;
  /**
   * Set on `running → cancelling`; persists through the terminal state so
   * a UI viewer can tell "this run was cancelled by the user" vs "by an
   * unhandled child throw".
   */
  cancelReason: CancelReason | null;
  result?: EncryptedValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
};

export interface RunsAuditRepo {
  insert(row: RunsAuditRow): Promise<void>;
  get(id: DelegationId): Promise<RunsAuditRow | null>;
  list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      state?: RunsAuditState;
    } & ListOptions,
  ): Promise<ListResult<RunsAuditRow>>;
  setState(
    id: DelegationId,
    patch: {
      state: RunsAuditState;
      cancelReason?: CancelReason | null;
      result?: EncryptedValue;
      errorMessage?: string;
      completedAt?: string;
    },
  ): Promise<boolean>;
}

// ─── FFI sidecar relay state (private to FFI Module, Phase 5 will unify) ──
//
// The FFI Runner holds a sidecar per-snapshot. Its in-memory state is only
// the subprocess pid level; in-flight delegation / escalation rows are
// written to these tables. On server restart, the FFI Runner reads them
// and notifies the sidecar via `ipcDelegateRestarted`.
//
// Phase 5 of Wave 6e merges these into the unified `delegations` /
// `escalations` tables. Until then, they live alongside the unified
// tables and the tree assembler reads BOTH.

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
// Key/value store backing EnvModule. Shared across snapshots (env
// outlives any single deploy). Secret entries hold AES-GCM ciphertext
// produced by the EnvModule; the storage layer sees only opaque
// strings.

export type EnvEntryRow = {
  key: string;
  value: string;
  isSecret: boolean;
  updatedAt: string;
};

export interface EnvEntryRepo {
  get(key: string): Promise<EnvEntryRow | null>;
  upsert(row: { key: string; value: string; isSecret: boolean }): Promise<void>;
  delete(key: string): Promise<boolean>;
  list(): Promise<EnvEntryRow[]>;
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
  delegations: DelegationRepo;
  escalations: EscalationRepo;
  runsAudit: RunsAuditRepo;
  /** Private FFI sidecar relay state. To be merged into `delegations` in Phase 5. */
  ffiDelegations: FfiPendingDelegationRepo;
  ffiEscalations: FfiPendingEscalationRepo;
  envEntries: EnvEntryRepo;
  /** 3-layer byte-sequence storage (refs / files / blobs). */
  values: ValueStore;
  /** Per-agent engine shards (Phase E). Replaces `checkpoints` once CORE shards. */
  shards: ShardStore;
  /** Project-local routing index for shards (Phase E). */
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
   *               No placeholder row is required; the advisory key is
   *               derived from the snapshot id and released automatically
   *               at tx end.
   *   - Memory:   per-snapshot Mutex map internal to the implementation.
   *
   * `withSnapshotLock` MUST be called inside `withTransaction` so the
   * advisory lock is bound to the surrounding tx lifetime.
   */
  withSnapshotLock<T>(tx: Storage, snapshotId: SnapshotId, fn: () => Promise<T>): Promise<T>;

  close?(): Promise<void>;
}
