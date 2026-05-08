// In-memory implementation of `Storage` for tests. Holds JSON values in
// plain Maps; deep-clones on read/write so tests cannot accidentally mutate
// stored state via shared references.

import { v7 as uuidv7 } from "uuid";
import type {
  DelegationId,
  IRModule,
  MachineSnapshot,
  SchemaBundle,
} from "katari-runtime";
import type {
  AgentId,
  AgentRepo,
  AgentRow,
  ModuleRepo,
  ModuleRow,
  ModuleSummary,
  SnapshotRepo,
  Storage,
  VersionId,
} from "./types.js";

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

/**
 * Default page size and hard cap for `list` endpoints. The default is
 * intentionally low so a forgetful client gets bounded payload back, and
 * the cap prevents callers from asking for the whole table at once.
 */
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

function clampLimit(requested: number | undefined): number {
  if (requested === undefined) return DEFAULT_LIMIT;
  if (!Number.isFinite(requested) || requested <= 0) return DEFAULT_LIMIT;
  return Math.min(MAX_LIMIT, Math.floor(requested));
}

class InMemoryModuleRepo implements ModuleRepo {
  private rows = new Map<VersionId, ModuleRow>();

  async insert(input: {
    irModule: IRModule;
    schemaBundle: SchemaBundle;
    name: string;
  }): Promise<VersionId> {
    const id = uuidv7() as VersionId;
    this.rows.set(id, {
      id,
      name: input.name,
      irModule: clone(input.irModule),
      schemaBundle: clone(input.schemaBundle),
      createdAt: new Date().toISOString(),
    });
    return id;
  }

  async list(options?: { limit?: number; offset?: number }): Promise<ModuleSummary[]> {
    const all = [...this.rows.values()].map((row) => ({
      id: row.id,
      name: row.name,
      createdAt: row.createdAt,
    }));
    const offset = Math.max(0, options?.offset ?? 0);
    const limit = clampLimit(options?.limit);
    return all.slice(offset, offset + limit);
  }

  async get(id: VersionId): Promise<ModuleRow | null> {
    const row = this.rows.get(id);
    return row ? clone(row) : null;
  }

  async delete(id: VersionId): Promise<boolean> {
    return this.rows.delete(id);
  }
}

class InMemoryAgentRepo implements AgentRepo {
  private rows = new Map<AgentId, AgentRow>();
  private byDelegation = new Map<DelegationId, AgentId>();

  async insert(row: AgentRow): Promise<void> {
    this.rows.set(row.id, clone(row));
    this.byDelegation.set(row.delegationId, row.id);
  }

  async get(id: AgentId): Promise<AgentRow | null> {
    const row = this.rows.get(id);
    return row ? clone(row) : null;
  }

  async findByDelegationId(
    delegationId: DelegationId,
  ): Promise<AgentRow | null> {
    const agentId = this.byDelegation.get(delegationId);
    if (agentId === undefined) return null;
    const row = this.rows.get(agentId);
    return row ? clone(row) : null;
  }

  async list(filter?: {
    versionId?: VersionId;
    limit?: number;
    offset?: number;
  }): Promise<AgentRow[]> {
    const all = [...this.rows.values()];
    const filtered =
      filter?.versionId !== undefined
        ? all.filter((row) => row.versionId === filter.versionId)
        : all;
    const offset = Math.max(0, filter?.offset ?? 0);
    const limit = clampLimit(filter?.limit);
    return filtered.slice(offset, offset + limit).map(clone);
  }

  async setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
    options?: { expectedState?: import("./types.js").AgentState },
  ): Promise<boolean> {
    const row = this.rows.get(id);
    if (row === undefined) return false;
    if (options?.expectedState !== undefined && row.state !== options.expectedState) {
      return false;
    }
    const updated: AgentRow = {
      ...row,
      ...clone(patch),
      updatedAt: new Date().toISOString(),
    };
    this.rows.set(id, updated);
    return true;
  }

  async markAllRunningAsError(
    versionId: VersionId,
    message: string,
  ): Promise<void> {
    const now = new Date().toISOString();
    for (const row of this.rows.values()) {
      if (row.versionId !== versionId) continue;
      if (row.state !== "running" && row.state !== "cancelling") continue;
      this.rows.set(row.id, {
        ...row,
        state: "error",
        errorMessage: message,
        updatedAt: now,
      });
    }
  }

  async listRunningVersionIds(): Promise<VersionId[]> {
    const ids = new Set<VersionId>();
    for (const row of this.rows.values()) {
      if (row.state === "running" || row.state === "cancelling") {
        ids.add(row.versionId);
      }
    }
    return [...ids];
  }
}

class InMemorySnapshotRepo implements SnapshotRepo {
  private rows = new Map<VersionId, MachineSnapshot>();

  async upsert(versionId: VersionId, snapshot: MachineSnapshot): Promise<void> {
    this.rows.set(versionId, clone(snapshot));
  }

  async get(versionId: VersionId): Promise<MachineSnapshot | null> {
    const snap = this.rows.get(versionId);
    return snap ? clone(snap) : null;
  }

  async delete(versionId: VersionId): Promise<void> {
    this.rows.delete(versionId);
  }
}

export class InMemoryStorage implements Storage {
  readonly modules = new InMemoryModuleRepo();
  readonly agents = new InMemoryAgentRepo();
  readonly snapshots = new InMemorySnapshotRepo();

  /**
   * Snapshot-and-restore implementation: the in-memory backend isn't a real
   * MVCC store, so we approximate transactions by deep-cloning every Map
   * state up front and restoring on throw. On success, the live state
   * (which `fn` mutated through `this.modules` / `this.agents` /
   * `this.snapshots`) becomes the committed state.
   *
   * The `tx` argument is `this` itself — there is no separate "transaction
   * scope" in the memory backend, so any call on `tx.modules`/etc. flows
   * straight to the live data structures. Callers must not interleave
   * unrelated work inside the `fn` callback.
   */
  async withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T> {
    // Capture per-repo internal state. Each repo maintains private Maps
    // that we deep-clone via structuredClone, then swap back on throw.
    type RepoState = {
      modules: Map<VersionId, ModuleRow>;
      agentRows: Map<AgentId, AgentRow>;
      agentByDelegation: Map<DelegationId, AgentId>;
      snapshots: Map<VersionId, MachineSnapshot>;
    };
    const captureState = (): RepoState => {
      const m = this.modules as unknown as { rows: Map<VersionId, ModuleRow> };
      const a = this.agents as unknown as {
        rows: Map<AgentId, AgentRow>;
        byDelegation: Map<DelegationId, AgentId>;
      };
      const s = this.snapshots as unknown as { rows: Map<VersionId, MachineSnapshot> };
      return {
        modules: new Map(m.rows),
        agentRows: new Map(a.rows),
        agentByDelegation: new Map(a.byDelegation),
        snapshots: new Map(s.rows),
      };
    };
    const restoreState = (snap: RepoState): void => {
      const m = this.modules as unknown as { rows: Map<VersionId, ModuleRow> };
      const a = this.agents as unknown as {
        rows: Map<AgentId, AgentRow>;
        byDelegation: Map<DelegationId, AgentId>;
      };
      const s = this.snapshots as unknown as { rows: Map<VersionId, MachineSnapshot> };
      m.rows = snap.modules;
      a.rows = snap.agentRows;
      a.byDelegation = snap.agentByDelegation;
      s.rows = snap.snapshots;
    };

    const before = captureState();
    try {
      return await fn(this);
    } catch (err) {
      restoreState(before);
      throw err;
    }
  }
}
