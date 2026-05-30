// In-memory ShardStore + ProjectIndexStore. Used by tests and the memory
// Storage backend. A shard persists as an EncryptedEngineCheckpoint keyed by
// (projectId, shardId); the project index is one plain-JSON row per project.

import type {
  ActiveShard,
  EncryptedEngineCheckpoint,
  LoadedShard,
  ProjectIndex,
  ProjectIndexStore,
  ShardId,
  ShardStatus,
  ShardStore,
} from "@katari-lang/runtime";

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

type ShardRow = {
  projectId: string;
  shardId: ShardId;
  currentSnapshot: string;
  status: ShardStatus;
  checkpoint: EncryptedEngineCheckpoint;
};

const shardKey = (projectId: string, shardId: ShardId): string => `${projectId}|${shardId}`;

export class InMemoryShardStore implements ShardStore {
  rows = new Map<string, ShardRow>();

  async get(projectId: string, shardId: ShardId): Promise<LoadedShard | null> {
    const row = this.rows.get(shardKey(projectId, shardId));
    return row !== undefined
      ? { checkpoint: clone(row.checkpoint), currentSnapshot: row.currentSnapshot }
      : null;
  }

  async upsert(input: {
    projectId: string;
    shardId: ShardId;
    currentSnapshot: string;
    status: ShardStatus;
    checkpoint: EncryptedEngineCheckpoint;
  }): Promise<void> {
    this.rows.set(shardKey(input.projectId, input.shardId), {
      projectId: input.projectId,
      shardId: input.shardId,
      currentSnapshot: input.currentSnapshot,
      status: input.status,
      checkpoint: clone(input.checkpoint),
    });
  }

  async delete(projectId: string, shardId: ShardId): Promise<void> {
    this.rows.delete(shardKey(projectId, shardId));
  }

  async listActive(projectId: string): Promise<ActiveShard[]> {
    return [...this.rows.values()]
      .filter((r) => r.projectId === projectId && r.status === "active")
      .map((r) => ({ shardId: r.shardId, currentSnapshot: r.currentSnapshot }));
  }
}

export class InMemoryProjectIndexStore implements ProjectIndexStore {
  rows = new Map<string, ProjectIndex>();

  async get(projectId: string): Promise<ProjectIndex | null> {
    const row = this.rows.get(projectId);
    return row !== undefined ? clone(row) : null;
  }

  async upsert(projectId: string, index: ProjectIndex): Promise<void> {
    this.rows.set(projectId, clone(index));
  }
}
