// In-memory implementation of `Storage`. Used by tests to avoid a real DB.
//
// This implementation provides `withSnapshotLock` via a per-snapshot Mutex
// map, and `withTransaction` via global snapshot & restore. The orchestrator
// (api-server core) only knows this interface and can be swapped with the
// Postgres impl.

import { v7 as uuidv7 } from "uuid";
import { Mutex } from "async-mutex";
import type {
  AgentDefId,
  DelegationId,
  EncryptedValue,
  EngineCheckpoint,
  EscalationId,
  IRModule,
  SchemaBundle,
} from "@katari-lang/runtime";
import type {
  AgentId,
  AgentRepo,
  AgentRow,
  AgentState,
  ApiPendingEscalation,
  ApiPendingEscalationRepo,
  EngineCheckpointRepo,
  EnvEntryRepo,
  EnvEntryRow,
  FfiPendingDelegation,
  FfiPendingDelegationRepo,
  FfiPendingEscalation,
  FfiPendingEscalationRepo,
  ListOptions,
  Project,
  ProjectId,
  ProjectRepo,
  SidecarBundle,
  Snapshot,
  SnapshotId,
  SnapshotRepo,
  SnapshotSummary,
  Storage,
} from "./types.js";

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

function clampLimit(requested: number | undefined): number {
  if (requested === undefined) return DEFAULT_LIMIT;
  if (!Number.isFinite(requested) || requested <= 0) return DEFAULT_LIMIT;
  return Math.min(MAX_LIMIT, Math.floor(requested));
}

// ─── Repos ─────────────────────────────────────────────────────────────────

class InMemoryProjectRepo implements ProjectRepo {
  rows = new Map<ProjectId, Project>();
  byName = new Map<string, ProjectId>();

  async upsertByName(name: string): Promise<Project> {
    const existing = this.byName.get(name);
    if (existing !== undefined) {
      const row = this.rows.get(existing);
      if (row !== undefined) return clone(row);
    }
    const id = uuidv7() as ProjectId;
    const project: Project = { id, name, createdAt: new Date().toISOString() };
    this.rows.set(id, project);
    this.byName.set(name, id);
    return clone(project);
  }

  async list(options?: ListOptions): Promise<Project[]> {
    const all = [...this.rows.values()];
    const offset = Math.max(0, options?.offset ?? 0);
    const limit = clampLimit(options?.limit);
    return all.slice(offset, offset + limit).map(clone);
  }

  async get(id: ProjectId): Promise<Project | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async getByName(name: string): Promise<Project | null> {
    const id = this.byName.get(name);
    if (id === undefined) return null;
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async delete(id: ProjectId): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    this.byName.delete(row.name);
    this.rows.delete(id);
    return true;
  }
}

class InMemorySnapshotRepo implements SnapshotRepo {
  rows = new Map<SnapshotId, Snapshot>();

  async insert(input: {
    projectId: ProjectId;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
  }): Promise<SnapshotId> {
    const id = uuidv7() as SnapshotId;
    this.rows.set(id, {
      id,
      projectId: input.projectId,
      irModule: clone(input.irModule),
      sidecarBundle:
        input.sidecarBundle !== null ? clone(input.sidecarBundle) : null,
      schemaBundle: clone(input.schemaBundle),
      createdAt: new Date().toISOString(),
    });
    return id;
  }

  async get(id: SnapshotId): Promise<Snapshot | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async list(
    filter?: { projectId?: ProjectId } & ListOptions,
  ): Promise<SnapshotSummary[]> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) {
      all = all.filter((r) => r.projectId === filter.projectId);
    }
    const offset = Math.max(0, filter?.offset ?? 0);
    const limit = clampLimit(filter?.limit);
    return all
      .slice(offset, offset + limit)
      .map((r) => ({
        id: r.id,
        projectId: r.projectId,
        createdAt: r.createdAt,
      }));
  }

  async latest(projectId: ProjectId): Promise<SnapshotId | null> {
    // uuidv7 ids are monotonically increasing, so the largest id under a
    // given project is the most recent snapshot. (Falling back on
    // createdAt would race because Date.now() has 1-ms resolution and
    // two inserts in the same tick can tie.)
    let latest: Snapshot | undefined;
    for (const row of this.rows.values()) {
      if (row.projectId !== projectId) continue;
      if (latest === undefined || row.id > latest.id) latest = row;
    }
    return latest !== undefined ? latest.id : null;
  }

  async delete(id: SnapshotId): Promise<boolean> {
    return this.rows.delete(id);
  }
}

class InMemoryEngineCheckpointRepo implements EngineCheckpointRepo {
  rows = new Map<SnapshotId, EngineCheckpoint>();

  async upsert(snapshotId: SnapshotId, checkpoint: EngineCheckpoint): Promise<void> {
    this.rows.set(snapshotId, clone(checkpoint));
  }

  async get(snapshotId: SnapshotId): Promise<EngineCheckpoint | null> {
    const row = this.rows.get(snapshotId);
    return row !== undefined ? clone(row) : null;
  }

  async delete(snapshotId: SnapshotId): Promise<void> {
    this.rows.delete(snapshotId);
  }
}

class InMemoryAgentRepo implements AgentRepo {
  rows = new Map<AgentId, AgentRow>();
  byDelegation = new Map<DelegationId, AgentId>();
  /**
   * Snapshot → project lookup. Injected at construction time so the
   * `projectId` filter on `list` can resolve a project's agents
   * cross-snapshot without each repo owning its own snapshot table.
   */
  constructor(
    private readonly projectIdOfSnapshot: (id: SnapshotId) => ProjectId | null,
  ) {}

  async insert(row: AgentRow): Promise<void> {
    this.rows.set(row.id, clone(row));
    this.byDelegation.set(row.delegationId, row.id);
  }

  async get(id: AgentId): Promise<AgentRow | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async findByDelegationId(delegationId: DelegationId): Promise<AgentRow | null> {
    const agentId = this.byDelegation.get(delegationId);
    if (agentId === undefined) return null;
    const row = this.rows.get(agentId);
    return row !== undefined ? clone(row) : null;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      state?: AgentState;
      afterId?: AgentId;
    } & ListOptions,
  ): Promise<AgentRow[]> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) {
      const want = filter.projectId;
      all = all.filter((r) => this.projectIdOfSnapshot(r.snapshotId) === want);
    }
    if (filter?.snapshotId !== undefined) {
      all = all.filter((r) => r.snapshotId === filter.snapshotId);
    }
    if (filter?.state !== undefined) {
      all = all.filter((r) => r.state === filter.state);
    }
    if (filter?.afterId !== undefined) {
      const afterId = filter.afterId;
      const idx = all.findIndex((r) => r.id === afterId);
      all = idx === -1 ? all : all.slice(idx + 1);
    }
    const offset = Math.max(0, filter?.offset ?? 0);
    const limit = clampLimit(filter?.limit);
    return all.slice(offset, offset + limit).map(clone);
  }

  async setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
    options?: { expectedState?: AgentState },
  ): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    if (
      options?.expectedState !== undefined &&
      row.state !== options.expectedState
    ) {
      return false;
    }
    this.rows.set(id, {
      ...row,
      ...clone(patch),
      updatedAt: new Date().toISOString(),
    });
    return true;
  }

  async markAllRunningAsError(
    snapshotId: SnapshotId,
    message: string,
  ): Promise<void> {
    const now = new Date().toISOString();
    for (const row of this.rows.values()) {
      if (row.snapshotId !== snapshotId) continue;
      if (row.state !== "running" && row.state !== "cancelling") continue;
      this.rows.set(row.id, {
        ...row,
        state: "error",
        errorMessage: message,
        updatedAt: now,
      });
    }
  }

  async listRunningSnapshotIds(): Promise<SnapshotId[]> {
    const ids = new Set<SnapshotId>();
    for (const row of this.rows.values()) {
      if (row.state === "running" || row.state === "cancelling") {
        ids.add(row.snapshotId);
      }
    }
    return [...ids];
  }
}

class InMemoryFfiPendingDelegationRepo implements FfiPendingDelegationRepo {
  rows = new Map<DelegationId, FfiPendingDelegation>();

  async insert(row: FfiPendingDelegation): Promise<void> {
    this.rows.set(row.delegationId, clone(row));
  }

  async get(delegationId: DelegationId): Promise<FfiPendingDelegation | null> {
    const row = this.rows.get(delegationId);
    return row !== undefined ? clone(row) : null;
  }

  async setState(
    delegationId: DelegationId,
    state: "running" | "cancelling",
  ): Promise<boolean> {
    const row = this.rows.get(delegationId);
    if (row === undefined) return false;
    this.rows.set(delegationId, { ...row, state });
    return true;
  }

  async delete(delegationId: DelegationId): Promise<boolean> {
    return this.rows.delete(delegationId);
  }

  async listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingDelegation[]> {
    return [...this.rows.values()]
      .filter((r) => r.snapshotId === snapshotId)
      .map(clone);
  }

  async listChildrenOf(
    parentDelegationId: DelegationId,
  ): Promise<FfiPendingDelegation[]> {
    return [...this.rows.values()]
      .filter((r) => r.parentExtDelegationId === parentDelegationId)
      .map(clone);
  }
}

class InMemoryFfiPendingEscalationRepo implements FfiPendingEscalationRepo {
  rows = new Map<EscalationId, FfiPendingEscalation>();

  async insert(row: FfiPendingEscalation): Promise<void> {
    this.rows.set(row.escalationId, clone(row));
  }

  async get(escalationId: EscalationId): Promise<FfiPendingEscalation | null> {
    const row = this.rows.get(escalationId);
    return row !== undefined ? clone(row) : null;
  }

  async delete(escalationId: EscalationId): Promise<boolean> {
    return this.rows.delete(escalationId);
  }

  async listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingEscalation[]> {
    return [...this.rows.values()]
      .filter((r) => r.snapshotId === snapshotId)
      .map(clone);
  }
}

class InMemoryApiPendingEscalationRepo implements ApiPendingEscalationRepo {
  rows = new Map<EscalationId, ApiPendingEscalation>();

  constructor(
    private readonly projectIdOfSnapshot: (id: SnapshotId) => ProjectId | null,
  ) {}

  async insert(row: ApiPendingEscalation): Promise<void> {
    this.rows.set(row.escalationId, clone(row));
  }

  async get(escalationId: EscalationId): Promise<ApiPendingEscalation | null> {
    const row = this.rows.get(escalationId);
    return row !== undefined ? clone(row) : null;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      state?: ApiPendingEscalation["state"];
    } & ListOptions,
  ): Promise<ApiPendingEscalation[]> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) {
      const want = filter.projectId;
      all = all.filter((r) => this.projectIdOfSnapshot(r.snapshotId) === want);
    }
    if (filter?.snapshotId !== undefined) {
      all = all.filter((r) => r.snapshotId === filter.snapshotId);
    }
    if (filter?.state !== undefined) {
      all = all.filter((r) => r.state === filter.state);
    }
    const offset = Math.max(0, filter?.offset ?? 0);
    const limit = clampLimit(filter?.limit);
    return all.slice(offset, offset + limit).map(clone);
  }

  async setAnswered(
    escalationId: EscalationId,
    value: EncryptedValue,
  ): Promise<boolean> {
    const row = this.rows.get(escalationId);
    if (row === undefined) return false;
    if (row.state !== "open") return false;
    this.rows.set(escalationId, {
      ...row,
      state: "answered",
      value: clone(value),
    });
    return true;
  }

  async setCancelled(escalationId: EscalationId): Promise<boolean> {
    const row = this.rows.get(escalationId);
    if (row === undefined) return false;
    if (row.state !== "open") return false;
    this.rows.set(escalationId, { ...row, state: "cancelled" });
    return true;
  }
}

// ─── Storage facade ────────────────────────────────────────────────────────

class InMemoryEnvEntryRepo implements EnvEntryRepo {
  rows = new Map<string, EnvEntryRow>();

  async get(key: string): Promise<EnvEntryRow | null> {
    return this.rows.get(key) ?? null;
  }

  async upsert(row: {
    key: string;
    value: string;
    isSecret: boolean;
  }): Promise<void> {
    this.rows.set(row.key, { ...row, updatedAt: new Date().toISOString() });
  }

  async delete(key: string): Promise<boolean> {
    return this.rows.delete(key);
  }

  async list(): Promise<EnvEntryRow[]> {
    return [...this.rows.values()].sort((a, b) =>
      a.key < b.key ? -1 : a.key > b.key ? 1 : 0,
    );
  }
}

export class InMemoryStorage implements Storage {
  readonly projects = new InMemoryProjectRepo();
  readonly snapshots = new InMemorySnapshotRepo();
  readonly checkpoints = new InMemoryEngineCheckpointRepo();
  // Snapshot → project lookup used by AgentRepo / ApiPendingEscalationRepo
  // when filtering cross-snapshot by `projectId`. Direct `.rows` access
  // avoids the async-Promise hop on every list() call.
  private readonly projectIdOfSnapshot = (id: SnapshotId): ProjectId | null =>
    this.snapshots.rows.get(id)?.projectId ?? null;
  readonly agents = new InMemoryAgentRepo(this.projectIdOfSnapshot);
  readonly ffiDelegations = new InMemoryFfiPendingDelegationRepo();
  readonly ffiEscalations = new InMemoryFfiPendingEscalationRepo();
  readonly apiEscalations = new InMemoryApiPendingEscalationRepo(
    this.projectIdOfSnapshot,
  );
  readonly envEntries = new InMemoryEnvEntryRepo();

  /** Per-snapshot mutex map for `withSnapshotLock` (= in-memory version of a row lock). */
  private readonly snapshotMutexes = new Map<SnapshotId, Mutex>();

  /**
   * Pseudo-transaction via snapshot-and-restore. Mutations inside fn are
   * rolled back across all repos on throw.
   */
  async withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T> {
    const before = this.snapshotState();
    try {
      return await fn(this);
    } catch (err) {
      this.restoreState(before);
      throw err;
    }
  }

   /**
    * Serialize concurrency via a per-snapshot Mutex. tx is not used; the
    * Mutex alone guarantees serialization (the Postgres version uses the
    * equivalent of `SELECT ... FOR UPDATE`).
    */
  async withSnapshotLock<T>(
    _tx: Storage,
    snapshotId: SnapshotId,
    fn: () => Promise<T>,
  ): Promise<T> {
    let mu = this.snapshotMutexes.get(snapshotId);
    if (mu === undefined) {
      mu = new Mutex();
      this.snapshotMutexes.set(snapshotId, mu);
    }
    return mu.runExclusive(fn);
  }

  // ─── Internal: snapshot/restore for withTransaction ─────────────────────

  private snapshotState(): TxSnapshot {
    return {
      projectsRows: new Map(this.projects.rows),
      projectsByName: new Map(this.projects.byName),
      snapshotsRows: new Map(this.snapshots.rows),
      checkpointsRows: new Map(this.checkpoints.rows),
      agentsRows: new Map(this.agents.rows),
      agentsByDelegation: new Map(this.agents.byDelegation),
      ffiDelegationsRows: new Map(this.ffiDelegations.rows),
      ffiEscalationsRows: new Map(this.ffiEscalations.rows),
      apiEscalationsRows: new Map(this.apiEscalations.rows),
      envEntriesRows: new Map(this.envEntries.rows),
    };
  }

  private restoreState(snap: TxSnapshot): void {
    this.projects.rows = snap.projectsRows;
    this.projects.byName = snap.projectsByName;
    this.snapshots.rows = snap.snapshotsRows;
    this.checkpoints.rows = snap.checkpointsRows;
    this.agents.rows = snap.agentsRows;
    this.agents.byDelegation = snap.agentsByDelegation;
    this.ffiDelegations.rows = snap.ffiDelegationsRows;
    this.ffiEscalations.rows = snap.ffiEscalationsRows;
    this.apiEscalations.rows = snap.apiEscalationsRows;
    this.envEntries.rows = snap.envEntriesRows;
  }
}

type TxSnapshot = {
  projectsRows: Map<ProjectId, Project>;
  projectsByName: Map<string, ProjectId>;
  snapshotsRows: Map<SnapshotId, Snapshot>;
  checkpointsRows: Map<SnapshotId, EngineCheckpoint>;
  agentsRows: Map<AgentId, AgentRow>;
  agentsByDelegation: Map<DelegationId, AgentId>;
  ffiDelegationsRows: Map<DelegationId, FfiPendingDelegation>;
  ffiEscalationsRows: Map<EscalationId, FfiPendingEscalation>;
  apiEscalationsRows: Map<EscalationId, ApiPendingEscalation>;
  envEntriesRows: Map<string, EnvEntryRow>;
};

// `AgentDefId` is referenced in repo types but not used directly here.
void (null as unknown as AgentDefId);
