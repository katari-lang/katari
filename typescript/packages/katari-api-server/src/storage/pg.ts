// Postgres-backed `Storage`. The bin entrypoint constructs this; tests use
// `InMemoryStorage` instead so they need not provision a database.

import postgres from "postgres";
import { v7 as uuidv7 } from "uuid";
import type {
  DelegationId,
  IRModule,
  MachineSnapshot,
  SchemaBundle,
  Value,
} from "katari-runtime";
import type {
  AgentId,
  AgentRepo,
  AgentRow,
  AgentState,
  ModuleRepo,
  ModuleRow,
  ModuleSummary,
  SnapshotRepo,
  Storage,
  VersionId,
} from "./types.js";

type Sql = ReturnType<typeof postgres>;

class PgModuleRepo implements ModuleRepo {
  constructor(private readonly sql: Sql) {}

  async insert(input: {
    irModule: IRModule;
    schemaBundle: SchemaBundle;
    name: string;
  }): Promise<VersionId> {
    const id = uuidv7();
    await this.sql`
      INSERT INTO module_versions (id, name, ir_module, schema_bundle)
      VALUES (${id}, ${input.name}, ${this.sql.json(input.irModule as never)}, ${this.sql.json(input.schemaBundle as never)})
    `;
    return id as VersionId;
  }

  async list(): Promise<ModuleSummary[]> {
    const rows = await this.sql<{
      id: string;
      name: string;
      created_at: Date;
    }[]>`
      SELECT id, name, created_at
      FROM module_versions
      ORDER BY created_at DESC
    `;
    return rows.map((r) => ({
      id: r.id as VersionId,
      name: r.name,
      createdAt: r.created_at.toISOString(),
    }));
  }

  async get(id: VersionId): Promise<ModuleRow | null> {
    const rows = await this.sql<{
      id: string;
      name: string;
      ir_module: IRModule;
      schema_bundle: SchemaBundle;
      created_at: Date;
    }[]>`
      SELECT id, name, ir_module, schema_bundle, created_at
      FROM module_versions
      WHERE id = ${id}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      id: row.id as VersionId,
      name: row.name,
      irModule: row.ir_module,
      schemaBundle: row.schema_bundle,
      createdAt: row.created_at.toISOString(),
    };
  }
}

class PgAgentRepo implements AgentRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: AgentRow): Promise<void> {
    await this.sql`
      INSERT INTO agents (id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at)
      VALUES (
        ${row.id},
        ${row.delegationId},
        ${row.versionId},
        ${row.qualifiedName},
        ${this.sql.json(row.args as never)},
        ${row.state},
        ${row.result === undefined ? null : this.sql.json(row.result as never)},
        ${row.errorMessage ?? null},
        ${row.createdAt},
        ${row.updatedAt}
      )
    `;
  }

  async get(id: AgentId): Promise<AgentRow | null> {
    const rows = await this.sql<DbAgentRow[]>`
      SELECT id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at
      FROM agents
      WHERE id = ${id}
    `;
    const row = rows[0];
    return row === undefined ? null : dbRowToAgentRow(row);
  }

  async findByDelegationId(
    delegationId: DelegationId,
  ): Promise<AgentRow | null> {
    const rows = await this.sql<DbAgentRow[]>`
      SELECT id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at
      FROM agents
      WHERE delegation_id = ${delegationId}
    `;
    const row = rows[0];
    return row === undefined ? null : dbRowToAgentRow(row);
  }

  async list(filter?: { versionId?: VersionId }): Promise<AgentRow[]> {
    const rows =
      filter?.versionId !== undefined
        ? await this.sql<DbAgentRow[]>`
            SELECT id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at
            FROM agents
            WHERE version_id = ${filter.versionId}
            ORDER BY created_at DESC
          `
        : await this.sql<DbAgentRow[]>`
            SELECT id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at
            FROM agents
            ORDER BY created_at DESC
          `;
    return rows.map(dbRowToAgentRow);
  }

  async setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
  ): Promise<void> {
    // Build the update set dynamically. Each column has its own clause.
    const sets: ReturnType<Sql>[] = [];
    if (patch.state !== undefined) {
      sets.push(this.sql`state = ${patch.state}`);
    }
    if (patch.result !== undefined) {
      sets.push(
        this.sql`result = ${this.sql.json(patch.result as never)}`,
      );
    }
    if (patch.errorMessage !== undefined) {
      sets.push(this.sql`error_message = ${patch.errorMessage}`);
    }
    if (sets.length === 0) return;
    sets.push(this.sql`updated_at = now()`);

    // Join sets with commas. `sql.join` exists on the postgres driver.
    const joined = sets.reduce((acc, cur, i) =>
      i === 0 ? cur : this.sql`${acc}, ${cur}`,
    );
    await this.sql`UPDATE agents SET ${joined} WHERE id = ${id}`;
  }

  async markAllRunningAsError(
    versionId: VersionId,
    message: string,
  ): Promise<void> {
    await this.sql`
      UPDATE agents
      SET state = 'error',
          error_message = ${message},
          updated_at = now()
      WHERE version_id = ${versionId}
        AND state IN ('running', 'cancelling')
    `;
  }

  async listRunningVersionIds(): Promise<VersionId[]> {
    const rows = await this.sql<{ version_id: string }[]>`
      SELECT DISTINCT version_id
      FROM agents
      WHERE state IN ('running', 'cancelling')
    `;
    return rows.map((r) => r.version_id as VersionId);
  }
}

class PgSnapshotRepo implements SnapshotRepo {
  constructor(private readonly sql: Sql) {}

  async upsert(versionId: VersionId, snapshot: MachineSnapshot): Promise<void> {
    await this.sql`
      INSERT INTO machine_snapshots (version_id, snapshot, updated_at)
      VALUES (${versionId}, ${this.sql.json(snapshot as never)}, now())
      ON CONFLICT (version_id) DO UPDATE
        SET snapshot = EXCLUDED.snapshot,
            updated_at = EXCLUDED.updated_at
    `;
  }

  async get(versionId: VersionId): Promise<MachineSnapshot | null> {
    const rows = await this.sql<{ snapshot: MachineSnapshot }[]>`
      SELECT snapshot FROM machine_snapshots WHERE version_id = ${versionId}
    `;
    return rows[0]?.snapshot ?? null;
  }

  async delete(versionId: VersionId): Promise<void> {
    await this.sql`DELETE FROM machine_snapshots WHERE version_id = ${versionId}`;
  }
}

type DbAgentRow = {
  id: string;
  delegation_id: string;
  version_id: string;
  qualified_name: string;
  args: Record<string, Value>;
  state: AgentState;
  result: Value | null;
  error_message: string | null;
  created_at: Date;
  updated_at: Date;
};

function dbRowToAgentRow(row: DbAgentRow): AgentRow {
  return {
    id: row.id as AgentId,
    delegationId: row.delegation_id as DelegationId,
    versionId: row.version_id as VersionId,
    qualifiedName: row.qualified_name,
    args: row.args,
    state: row.state,
    result: row.result === null ? undefined : row.result,
    errorMessage: row.error_message === null ? undefined : row.error_message,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

export class PostgresStorage implements Storage {
  readonly modules: ModuleRepo;
  readonly agents: AgentRepo;
  readonly snapshots: SnapshotRepo;

  private constructor(private readonly sql: Sql) {
    this.modules = new PgModuleRepo(sql);
    this.agents = new PgAgentRepo(sql);
    this.snapshots = new PgSnapshotRepo(sql);
  }

  static create(databaseUrl: string): PostgresStorage {
    const sql = postgres(databaseUrl, { transform: { undefined: null } });
    return new PostgresStorage(sql);
  }

  async close(): Promise<void> {
    await this.sql.end();
  }
}
