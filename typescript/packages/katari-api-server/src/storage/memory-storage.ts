// In-memory implementation of `Storage`. Used by tests to avoid a real DB.
//
// This implementation provides `withSnapshotLock` via a per-snapshot Mutex
// map, and `withTransaction` via global snapshot & restore. The orchestrator
// (api-server core) only knows this interface and can be swapped with the
// Postgres impl.

import type {
  DelegationId,
  EncryptedValue,
  EngineCheckpoint,
  EntityId,
  EscalationId,
  IRModule,
  SchemaBundle,
} from "@katari-lang/runtime";
import { Mutex } from "async-mutex";
import { v7 as uuidv7 } from "uuid";
import { decodeCursor, encodeCursor } from "../cursor.js";
import { InMemoryProjectIndexStore, InMemoryShardStore } from "./shard-store-memory.js";
import type {
  DelegationRepo,
  DelegationRow,
  DelegationState,
  EngineCheckpointRepo,
  EntityModule,
  EntityRepo,
  EntityRow,
  EntityState,
  EnvEntryRepo,
  EnvEntryRow,
  EscalationRepo,
  EscalationRow,
  FfiPendingDelegation,
  FfiPendingDelegationRepo,
  FfiPendingEscalation,
  FfiPendingEscalationRepo,
  ListOptions,
  ListResult,
  Project,
  ProjectId,
  ProjectRepo,
  RunEscalationAuditRow,
  RunEscalationsAuditRepo,
  RunId,
  RunRepo,
  RunRow,
  RunState,
  SidecarBundle,
  Snapshot,
  SnapshotId,
  SnapshotRepo,
  SnapshotSummary,
  Storage,
  UpsertProjectInput,
} from "./types.js";
import { InMemoryValueStore } from "./value-store-memory.js";

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

/**
 * Apply cursor-based pagination to a pre-sorted array. Returns
 * `{ items, nextCursor }`. The caller must ensure `all` is already
 * sorted in the desired order.
 *
 * `comparator` defines how cursor position is located:
 *   - For DESC order: items whose `(createdAt, id)` is lexicographically
 *     LESS than the cursor are "after" the cursor in the result set.
 *   - For ASC order: items whose `(createdAt, id)` is lexicographically
 *     GREATER than the cursor are "after" the cursor in the result set.
 */
function paginateWithCursor<T extends { createdAt: string }>(
  all: T[],
  options: ListOptions | undefined,
  idFn: (item: T) => string,
  order: "asc" | "desc",
): ListResult<T> {
  const limit = clampLimit(options?.limit);
  const cursor = options?.cursor !== undefined ? decodeCursor(options.cursor) : null;
  let start = 0;
  if (cursor !== null) {
    start = all.findIndex((item) => {
      const id = idFn(item);
      if (order === "desc") {
        return (
          item.createdAt < cursor.createdAt ||
          (item.createdAt === cursor.createdAt && id < cursor.id)
        );
      }
      return (
        item.createdAt > cursor.createdAt || (item.createdAt === cursor.createdAt && id > cursor.id)
      );
    });
    if (start === -1) start = all.length;
  }
  const page = all.slice(start, start + limit + 1);
  const hasMore = page.length > limit;
  const items = hasMore ? page.slice(0, limit) : page;
  const last = items[items.length - 1];
  return {
    items: items.map(clone),
    nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, idFn(last)) : null,
  };
}

// ─── Repos ─────────────────────────────────────────────────────────────────

class InMemoryProjectRepo implements ProjectRepo {
  rows = new Map<ProjectId, Project>();
  byName = new Map<string, ProjectId>();

  async upsertProject(input: UpsertProjectInput): Promise<Project> {
    const existingId = this.byName.get(input.name);
    if (existingId !== undefined) {
      const row = this.rows.get(existingId);
      if (row !== undefined) {
        // Overwrite only the fields the caller explicitly provided;
        // `undefined` = "leave as-is", `null` = "clear".
        const next: Project = {
          ...row,
          description: input.description === undefined ? row.description : input.description,
          readme: input.readme === undefined ? row.readme : input.readme,
        };
        this.rows.set(existingId, next);
        return clone(next);
      }
    }
    const id = uuidv7() as ProjectId;
    const project: Project = {
      id,
      name: input.name,
      description: input.description ?? null,
      readme: input.readme ?? null,
      createdAt: new Date().toISOString(),
    };
    this.rows.set(id, project);
    this.byName.set(input.name, id);
    return clone(project);
  }

  async list(options?: ListOptions): Promise<ListResult<Project>> {
    const all = [...this.rows.values()].sort((a, b) =>
      a.createdAt > b.createdAt
        ? -1
        : a.createdAt < b.createdAt
          ? 1
          : a.id > b.id
            ? -1
            : a.id < b.id
              ? 1
              : 0,
    );
    return paginateWithCursor(all, options, (p) => p.id, "desc");
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
    message: string;
  }): Promise<SnapshotId> {
    const id = uuidv7() as SnapshotId;
    this.rows.set(id, {
      id,
      projectId: input.projectId,
      irModule: clone(input.irModule),
      sidecarBundle: input.sidecarBundle !== null ? clone(input.sidecarBundle) : null,
      schemaBundle: clone(input.schemaBundle),
      message: input.message,
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
  ): Promise<ListResult<SnapshotSummary>> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) {
      all = all.filter((r) => r.projectId === filter.projectId);
    }
    all.sort((a, b) =>
      a.createdAt > b.createdAt
        ? -1
        : a.createdAt < b.createdAt
          ? 1
          : a.id > b.id
            ? -1
            : a.id < b.id
              ? 1
              : 0,
    );
    const summaries = all.map((r) => ({
      id: r.id,
      projectId: r.projectId,
      message: r.message,
      createdAt: r.createdAt,
    }));
    return paginateWithCursor(summaries, filter, (s) => s.id, "desc");
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

class InMemoryEntityRepo implements EntityRepo {
  rows = new Map<EntityId, EntityRow>();

  // Holds the value store + escalation repo so `delete` can simulate the FK
  // CASCADE (drop the entity's still-owned refs + raised escalations) that the
  // Postgres impl gets for free.
  constructor(
    private readonly values: InMemoryValueStore,
    private readonly escalations: InMemoryEscalationRepo,
  ) {}

  async insert(row: EntityRow): Promise<void> {
    this.rows.set(row.id, clone(row));
  }

  async get(id: EntityId): Promise<EntityRow | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async getByDelegation(
    projectId: ProjectId,
    delegationId: DelegationId,
  ): Promise<EntityRow | null> {
    for (const row of this.rows.values()) {
      if (row.projectId === projectId && row.delegationId === delegationId) return clone(row);
    }
    return null;
  }

  async setState(
    id: EntityId,
    state: EntityState,
    options?: { expectedState?: EntityState },
  ): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    if (options?.expectedState !== undefined && row.state !== options.expectedState) return false;
    this.rows.set(id, { ...row, state, updatedAt: new Date().toISOString() });
    return true;
  }

  async delete(id: EntityId): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    this.rows.delete(id);
    // FK CASCADE (simulated): drop the entity's still-owned refs + escalations.
    this.values.deleteRefsOwnedBy(row.projectId, id);
    for (const esc of [...this.escalations.rows.values()]) {
      if (esc.entityId === id) this.escalations.rows.delete(esc.id);
    }
    return true;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      module?: EntityModule;
      state?: EntityState;
    } & ListOptions,
  ): Promise<ListResult<EntityRow>> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) all = all.filter((r) => r.projectId === filter.projectId);
    if (filter?.module !== undefined) all = all.filter((r) => r.module === filter.module);
    if (filter?.state !== undefined) all = all.filter((r) => r.state === filter.state);
    all.sort((a, b) =>
      a.createdAt < b.createdAt
        ? -1
        : a.createdAt > b.createdAt
          ? 1
          : a.id < b.id
            ? -1
            : a.id > b.id
              ? 1
              : 0,
    );
    return paginateWithCursor(all, filter, (r) => r.id, "asc");
  }
}

class InMemoryDelegationRepo implements DelegationRepo {
  rows = new Map<DelegationId, DelegationRow>();

  async insert(row: DelegationRow): Promise<void> {
    this.rows.set(row.id, clone(row));
  }

  async get(id: DelegationId): Promise<DelegationRow | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async setState(
    id: DelegationId,
    state: DelegationState,
    options?: { expectedState?: DelegationState },
  ): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    if (options?.expectedState !== undefined && row.state !== options.expectedState) return false;
    this.rows.set(id, { ...row, state, updatedAt: new Date().toISOString() });
    return true;
  }

  async delete(id: DelegationId): Promise<boolean> {
    return this.rows.delete(id);
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      parentEntityId?: EntityId;
      state?: DelegationState;
    } & ListOptions,
  ): Promise<ListResult<DelegationRow>> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) all = all.filter((r) => r.projectId === filter.projectId);
    if (filter?.parentEntityId !== undefined) {
      all = all.filter((r) => r.parentEntityId === filter.parentEntityId);
    }
    if (filter?.state !== undefined) all = all.filter((r) => r.state === filter.state);
    all.sort((a, b) =>
      a.createdAt < b.createdAt
        ? -1
        : a.createdAt > b.createdAt
          ? 1
          : a.id < b.id
            ? -1
            : a.id > b.id
              ? 1
              : 0,
    );
    return paginateWithCursor(all, filter, (r) => r.id, "asc");
  }
}

class InMemoryEscalationRepo implements EscalationRepo {
  rows = new Map<EscalationId, EscalationRow>();

  async insert(row: EscalationRow): Promise<void> {
    this.rows.set(row.id, clone(row));
  }

  async get(id: EscalationId): Promise<EscalationRow | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async delete(id: EscalationId): Promise<boolean> {
    return this.rows.delete(id);
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      entityId?: EntityId;
    } & ListOptions,
  ): Promise<ListResult<EscalationRow>> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) all = all.filter((r) => r.projectId === filter.projectId);
    if (filter?.entityId !== undefined) all = all.filter((r) => r.entityId === filter.entityId);
    all.sort((a, b) =>
      a.createdAt > b.createdAt
        ? -1
        : a.createdAt < b.createdAt
          ? 1
          : a.id > b.id
            ? -1
            : a.id < b.id
              ? 1
              : 0,
    );
    return paginateWithCursor(all, filter, (r) => r.id, "desc");
  }
}

class InMemoryRunRepo implements RunRepo {
  rows = new Map<RunId, RunRow>();

  async insert(row: RunRow): Promise<void> {
    this.rows.set(row.id, clone(row));
  }

  async get(id: RunId): Promise<RunRow | null> {
    const row = this.rows.get(id);
    return row !== undefined ? clone(row) : null;
  }

  async getByCoreDelegation(coreDelegationId: DelegationId): Promise<RunRow | null> {
    for (const row of this.rows.values()) {
      if (row.coreDelegationId === coreDelegationId) return clone(row);
    }
    return null;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      state?: RunState;
    } & ListOptions,
  ): Promise<ListResult<RunRow>> {
    let all = [...this.rows.values()];
    if (filter?.projectId !== undefined) all = all.filter((r) => r.projectId === filter.projectId);
    if (filter?.snapshotId !== undefined)
      all = all.filter((r) => r.snapshotId === filter.snapshotId);
    if (filter?.state !== undefined) all = all.filter((r) => r.state === filter.state);
    all.sort((a, b) =>
      a.createdAt > b.createdAt
        ? -1
        : a.createdAt < b.createdAt
          ? 1
          : a.id > b.id
            ? -1
            : a.id < b.id
              ? 1
              : 0,
    );
    return paginateWithCursor(all, filter, (r) => r.id, "desc");
  }

  async setState(
    id: RunId,
    patch: {
      state: RunState;
      cancelReason?: import("./types.js").CancelReason | null;
      result?: EncryptedValue;
      errorMessage?: string;
      completedAt?: string;
    },
  ): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    const next: RunRow = { ...row, state: patch.state, updatedAt: new Date().toISOString() };
    if (patch.cancelReason !== undefined) next.cancelReason = patch.cancelReason;
    if (patch.result !== undefined) next.result = clone(patch.result);
    if (patch.errorMessage !== undefined) next.errorMessage = patch.errorMessage;
    if (patch.completedAt !== undefined) next.completedAt = patch.completedAt;
    this.rows.set(id, next);
    return true;
  }
}

class InMemoryRunEscalationsAuditRepo implements RunEscalationsAuditRepo {
  // Keyed by escalationId (globally unique per hop) so `get`/`setAnswer` are O(1).
  rows = new Map<EscalationId, RunEscalationAuditRow>();

  async insert(row: RunEscalationAuditRow): Promise<void> {
    if (!this.rows.has(row.escalationId)) this.rows.set(row.escalationId, clone(row));
  }

  async get(escalationId: EscalationId): Promise<RunEscalationAuditRow | null> {
    const row = this.rows.get(escalationId);
    return row !== undefined ? clone(row) : null;
  }

  async setAnswer(
    escalationId: EscalationId,
    answer: EncryptedValue,
    answeredAt: string,
  ): Promise<boolean> {
    const row = this.rows.get(escalationId);
    if (row === undefined) return false;
    this.rows.set(escalationId, { ...row, answer: clone(answer), answeredAt });
    return true;
  }

  async list(runId: RunId): Promise<RunEscalationAuditRow[]> {
    return [...this.rows.values()]
      .filter((r) => r.runId === runId)
      .sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0))
      .map(clone);
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

  async setState(delegationId: DelegationId, state: "running" | "cancelling"): Promise<boolean> {
    const row = this.rows.get(delegationId);
    if (row === undefined) return false;
    this.rows.set(delegationId, { ...row, state });
    return true;
  }

  async delete(delegationId: DelegationId): Promise<boolean> {
    return this.rows.delete(delegationId);
  }

  async listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingDelegation[]> {
    return [...this.rows.values()].filter((r) => r.snapshotId === snapshotId).map(clone);
  }

  async listChildrenOf(parentDelegationId: DelegationId): Promise<FfiPendingDelegation[]> {
    return [...this.rows.values()]
      .filter((r) => r.parentExtDelegationId === parentDelegationId)
      .map(clone);
  }

  async listLiveSnapshotIds(): Promise<SnapshotId[]> {
    const ids = new Set<SnapshotId>();
    for (const row of this.rows.values()) ids.add(row.snapshotId);
    return [...ids];
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
    return [...this.rows.values()].filter((r) => r.snapshotId === snapshotId).map(clone);
  }
}

class InMemoryEnvEntryRepo implements EnvEntryRepo {
  // Keyed by `${projectId} ${key}` so one project's env can't shadow
  // another's. A space can't appear in a project UUID, so the prefix scan
  // in `list` is unambiguous.
  rows = new Map<string, EnvEntryRow>();

  private static composite(projectId: ProjectId, key: string): string {
    return `${projectId} ${key}`;
  }

  async get(projectId: ProjectId, key: string): Promise<EnvEntryRow | null> {
    return this.rows.get(InMemoryEnvEntryRepo.composite(projectId, key)) ?? null;
  }

  async upsert(row: {
    projectId: ProjectId;
    key: string;
    value: string;
    isSecret: boolean;
  }): Promise<void> {
    this.rows.set(InMemoryEnvEntryRepo.composite(row.projectId, row.key), {
      key: row.key,
      value: row.value,
      isSecret: row.isSecret,
      updatedAt: new Date().toISOString(),
    });
  }

  async delete(projectId: ProjectId, key: string): Promise<boolean> {
    return this.rows.delete(InMemoryEnvEntryRepo.composite(projectId, key));
  }

  async list(projectId: ProjectId): Promise<EnvEntryRow[]> {
    const prefix = `${projectId} `;
    return [...this.rows.entries()]
      .filter(([k]) => k.startsWith(prefix))
      .map(([, row]) => row)
      .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  }
}

// ─── Storage facade ────────────────────────────────────────────────────────

export class InMemoryStorage implements Storage {
  readonly projects = new InMemoryProjectRepo();
  readonly snapshots = new InMemorySnapshotRepo();
  readonly checkpoints = new InMemoryEngineCheckpointRepo();
  readonly values = new InMemoryValueStore();
  readonly escalations = new InMemoryEscalationRepo();
  // entities holds value-store + escalation refs so `delete` simulates the FK
  // CASCADE (refs + raised escalations) the Postgres impl gets for free.
  readonly entities = new InMemoryEntityRepo(this.values, this.escalations);
  readonly delegations = new InMemoryDelegationRepo();
  readonly runs = new InMemoryRunRepo();
  readonly runEscalationsAudit = new InMemoryRunEscalationsAuditRepo();
  readonly ffiDelegations = new InMemoryFfiPendingDelegationRepo();
  readonly ffiEscalations = new InMemoryFfiPendingEscalationRepo();
  readonly envEntries = new InMemoryEnvEntryRepo();
  readonly shards = new InMemoryShardStore();
  readonly projectIndex = new InMemoryProjectIndexStore();

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
      entitiesRows: new Map(this.entities.rows),
      delegationsRows: new Map(this.delegations.rows),
      escalationsRows: new Map(this.escalations.rows),
      runsRows: new Map(this.runs.rows),
      runEscalationsAuditRows: new Map(this.runEscalationsAudit.rows),
      ffiDelegationsRows: new Map(this.ffiDelegations.rows),
      ffiEscalationsRows: new Map(this.ffiEscalations.rows),
      envEntriesRows: new Map(this.envEntries.rows),
      // Blobs are content-addressed and immutable, so a shallow Map copy is a
      // valid rollback target (inserts/deletes revert; bytes never mutate).
      valueRefsRows: new Map(this.values.refs),
      valueBlobsRows: new Map(this.values.blobs),
      shardRows: new Map(this.shards.rows),
      projectIndexRows: new Map(this.projectIndex.rows),
    };
  }

  private restoreState(snap: TxSnapshot): void {
    this.projects.rows = snap.projectsRows;
    this.projects.byName = snap.projectsByName;
    this.snapshots.rows = snap.snapshotsRows;
    this.checkpoints.rows = snap.checkpointsRows;
    this.entities.rows = snap.entitiesRows;
    this.delegations.rows = snap.delegationsRows;
    this.escalations.rows = snap.escalationsRows;
    this.runs.rows = snap.runsRows;
    this.runEscalationsAudit.rows = snap.runEscalationsAuditRows;
    this.ffiDelegations.rows = snap.ffiDelegationsRows;
    this.ffiEscalations.rows = snap.ffiEscalationsRows;
    this.envEntries.rows = snap.envEntriesRows;
    this.values.refs = snap.valueRefsRows;
    this.values.blobs = snap.valueBlobsRows;
    this.shards.rows = snap.shardRows;
    this.projectIndex.rows = snap.projectIndexRows;
  }
}

type TxSnapshot = {
  projectsRows: Map<ProjectId, Project>;
  projectsByName: Map<string, ProjectId>;
  snapshotsRows: Map<SnapshotId, Snapshot>;
  checkpointsRows: Map<SnapshotId, EngineCheckpoint>;
  entitiesRows: Map<EntityId, EntityRow>;
  delegationsRows: Map<DelegationId, DelegationRow>;
  escalationsRows: Map<EscalationId, EscalationRow>;
  runsRows: Map<RunId, RunRow>;
  runEscalationsAuditRows: Map<EscalationId, RunEscalationAuditRow>;
  ffiDelegationsRows: Map<DelegationId, FfiPendingDelegation>;
  ffiEscalationsRows: Map<EscalationId, FfiPendingEscalation>;
  envEntriesRows: Map<string, EnvEntryRow>;
  valueRefsRows: InMemoryValueStore["refs"];
  valueBlobsRows: InMemoryValueStore["blobs"];
  shardRows: InMemoryShardStore["rows"];
  projectIndexRows: InMemoryProjectIndexStore["rows"];
};
