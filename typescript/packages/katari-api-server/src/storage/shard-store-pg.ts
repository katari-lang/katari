// Postgres-backed ShardStore + ProjectIndexStore over `engine_shards` /
// `project_index`. A shard's encrypted checkpoint lives in `engine_shards.payload`
// keyed by (project_id, shard_id); `current_snapshot` records which code version
// the instance runs (FK to snapshots, RESTRICT). The project index is one JSONB
// row per project.

import type {
  ActiveShard,
  EncryptedEngineCheckpoint,
  ProjectIndex,
  ProjectIndexStore,
  ShardId,
  ShardStatus,
  ShardStore,
} from "@katari-lang/runtime";
import type postgres from "postgres";

type Sql = ReturnType<typeof postgres>;

// The `postgres` driver types `sql.json` against its own JSONValue; our
// payloads are plain JSON. Adapt at the call site.
function asJson(value: unknown): never {
  return value as never;
}

export class PgShardStore implements ShardStore {
  constructor(private readonly sql: Sql) {}

  async get(projectId: string, shardId: ShardId): Promise<EncryptedEngineCheckpoint | null> {
    const rows = await this.sql<{ payload: EncryptedEngineCheckpoint }[]>`
      SELECT payload FROM engine_shards
      WHERE project_id = ${projectId} AND shard_id = ${shardId}
    `;
    return rows[0]?.payload ?? null;
  }

  async upsert(input: {
    projectId: string;
    shardId: ShardId;
    currentSnapshot: string;
    status: ShardStatus;
    checkpoint: EncryptedEngineCheckpoint;
  }): Promise<void> {
    await this.sql`
      INSERT INTO engine_shards (project_id, shard_id, current_snapshot, payload, status, updated_at)
      VALUES (${input.projectId}, ${input.shardId}, ${input.currentSnapshot},
              ${this.sql.json(asJson(input.checkpoint))}, ${input.status}, now())
      ON CONFLICT (project_id, shard_id) DO UPDATE
        SET current_snapshot = EXCLUDED.current_snapshot,
            payload = EXCLUDED.payload,
            status = EXCLUDED.status,
            updated_at = now()
    `;
  }

  async delete(projectId: string, shardId: ShardId): Promise<void> {
    await this.sql`
      DELETE FROM engine_shards WHERE project_id = ${projectId} AND shard_id = ${shardId}
    `;
  }

  async listActive(projectId: string): Promise<ActiveShard[]> {
    const rows = await this.sql<{ shard_id: string; current_snapshot: string }[]>`
      SELECT shard_id, current_snapshot FROM engine_shards
      WHERE project_id = ${projectId} AND status = 'active'
    `;
    return rows.map((r) => ({ shardId: r.shard_id, currentSnapshot: r.current_snapshot }));
  }
}

export class PgProjectIndexStore implements ProjectIndexStore {
  constructor(private readonly sql: Sql) {}

  async get(projectId: string): Promise<ProjectIndex | null> {
    const rows = await this.sql<{ payload: ProjectIndex }[]>`
      SELECT payload FROM project_index WHERE project_id = ${projectId}
    `;
    return rows[0]?.payload ?? null;
  }

  async upsert(projectId: string, index: ProjectIndex): Promise<void> {
    await this.sql`
      INSERT INTO project_index (project_id, payload, updated_at)
      VALUES (${projectId}, ${this.sql.json(asJson(index))}, now())
      ON CONFLICT (project_id) DO UPDATE
        SET payload = EXCLUDED.payload, updated_at = now()
    `;
  }
}
