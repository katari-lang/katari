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

  async list(): Promise<ModuleSummary[]> {
    return [...this.rows.values()].map((row) => ({
      id: row.id,
      name: row.name,
      createdAt: row.createdAt,
    }));
  }

  async get(id: VersionId): Promise<ModuleRow | null> {
    const row = this.rows.get(id);
    return row ? clone(row) : null;
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

  async list(filter?: { versionId?: VersionId }): Promise<AgentRow[]> {
    const all = [...this.rows.values()];
    const filtered =
      filter?.versionId !== undefined
        ? all.filter((row) => row.versionId === filter.versionId)
        : all;
    return filtered.map(clone);
  }

  async setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
  ): Promise<void> {
    const row = this.rows.get(id);
    if (row === undefined) return;
    const updated: AgentRow = {
      ...row,
      ...clone(patch),
      updatedAt: new Date().toISOString(),
    };
    this.rows.set(id, updated);
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
}
