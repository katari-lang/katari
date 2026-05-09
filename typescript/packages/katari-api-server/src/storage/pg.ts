// Postgres-backed `Storage`. The bin entrypoint constructs this; tests use
// `InMemoryStorage` instead so they need not provision a database.

import postgres from "postgres";
import { v7 as uuidv7 } from "uuid";
import type {
  DelegationId,
  Diff,
  EngineSnapshot,
  EngineValue,
  IRModule,
  SchemaBundle,
} from "katari-runtime";

type MachineSnapshot = EngineSnapshot;
type Value = EngineValue;
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

/**
 * Helper for the `postgres` driver's `sql.json(...)` argument: the driver
 * types it as a domain-specific `JSONValue` that doesn't intersect with
 * our app's data shapes (recursive Value / IRModule), so direct passing
 * fails type-check. We funnel every json-serializable parameter through
 * here so the unsafe cast lives in exactly one place — easier to audit
 * and to swap out if we ever migrate off this driver.
 */
function asJson<T>(value: T): never {
  return value as never;
}

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

function clampLimit(requested: number | undefined): number {
  if (requested === undefined) return DEFAULT_LIMIT;
  if (!Number.isFinite(requested) || requested <= 0) return DEFAULT_LIMIT;
  return Math.min(MAX_LIMIT, Math.floor(requested));
}

function clampOffset(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested) || requested < 0) {
    return 0;
  }
  return Math.floor(requested);
}

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
      VALUES (${id}, ${input.name}, ${this.sql.json(asJson(input.irModule))}, ${this.sql.json(asJson(input.schemaBundle))})
    `;
    return id as VersionId;
  }

  async list(options?: { limit?: number; offset?: number }): Promise<ModuleSummary[]> {
    const limit = clampLimit(options?.limit);
    const offset = clampOffset(options?.offset);
    const rows = await this.sql<{
      id: string;
      name: string;
      created_at: Date;
    }[]>`
      SELECT id, name, created_at
      FROM module_versions
      ORDER BY created_at DESC
      LIMIT ${limit} OFFSET ${offset}
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

  async delete(id: VersionId): Promise<boolean> {
    const result = await this.sql`DELETE FROM module_versions WHERE id = ${id}`;
    return (result.count ?? 0) > 0;
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
        ${this.sql.json(asJson(row.args))},
        ${row.state},
        ${row.result === undefined ? null : this.sql.json(asJson(row.result))},
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

  async list(filter?: {
    versionId?: VersionId;
    limit?: number;
    offset?: number;
  }): Promise<AgentRow[]> {
    const limit = clampLimit(filter?.limit);
    const offset = clampOffset(filter?.offset);
    const rows =
      filter?.versionId !== undefined
        ? await this.sql<DbAgentRow[]>`
            SELECT id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at
            FROM agents
            WHERE version_id = ${filter.versionId}
            ORDER BY created_at DESC
            LIMIT ${limit} OFFSET ${offset}
          `
        : await this.sql<DbAgentRow[]>`
            SELECT id, delegation_id, version_id, qualified_name, args, state, result, error_message, created_at, updated_at
            FROM agents
            ORDER BY created_at DESC
            LIMIT ${limit} OFFSET ${offset}
          `;
    return rows.map(dbRowToAgentRow);
  }

  async setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
    options?: { expectedState?: AgentState },
  ): Promise<boolean> {
    // Build the update set dynamically. Each column has its own clause.
    const sets: ReturnType<Sql>[] = [];
    if (patch.state !== undefined) {
      sets.push(this.sql`state = ${patch.state}`);
    }
    if (patch.result !== undefined) {
      sets.push(
        this.sql`result = ${this.sql.json(asJson(patch.result))}`,
      );
    }
    if (patch.errorMessage !== undefined) {
      sets.push(this.sql`error_message = ${patch.errorMessage}`);
    }
    if (sets.length === 0) return true;
    sets.push(this.sql`updated_at = now()`);

    // Join sets with commas. `sql.join` exists on the postgres driver.
    const joined = sets.reduce((acc, cur, i) =>
      i === 0 ? cur : this.sql`${acc}, ${cur}`,
    );
    const expected = options?.expectedState;
    const result =
      expected !== undefined
        ? await this.sql`UPDATE agents SET ${joined} WHERE id = ${id} AND state = ${expected}`
        : await this.sql`UPDATE agents SET ${joined} WHERE id = ${id}`;
    // postgres driver exposes affected-row count on the result object.
    return (result.count ?? 0) > 0;
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

class PgDiffRepo {
  constructor(private readonly sql: Sql) {}

  async append(versionId: VersionId, diffs: Diff[]): Promise<void> {
    if (diffs.length === 0) return;
    await this.sql`
      INSERT INTO machine_diffs (version_id, batch, created_at)
      VALUES (${versionId}, ${this.sql.json(asJson(diffs))}, now())
    `;
  }

  async list(versionId: VersionId): Promise<Diff[]> {
    const rows = await this.sql<{ batch: Diff[] }[]>`
      SELECT batch FROM machine_diffs
      WHERE version_id = ${versionId}
      ORDER BY id ASC
    `;
    return rows.flatMap((r) => r.batch);
  }

  async delete(versionId: VersionId): Promise<void> {
    await this.sql`DELETE FROM machine_diffs WHERE version_id = ${versionId}`;
  }
}

class PgSnapshotRepo implements SnapshotRepo {
  constructor(private readonly sql: Sql) {}

  async upsert(versionId: VersionId, snapshot: MachineSnapshot): Promise<void> {
    await this.sql`
      INSERT INTO machine_snapshots (version_id, snapshot, updated_at)
      VALUES (${versionId}, ${this.sql.json(asJson(snapshot))}, now())
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
  readonly diffs: PgDiffRepo;

  private constructor(private readonly sql: Sql) {
    this.modules = new PgModuleRepo(sql);
    this.agents = new PgAgentRepo(sql);
    this.snapshots = new PgSnapshotRepo(sql);
    this.diffs = new PgDiffRepo(sql);
  }

  static create(databaseUrl: string): PostgresStorage {
    const sql = postgres(databaseUrl, { transform: { undefined: null } });
    return new PostgresStorage(sql);
  }

  /**
   * Run `fn` inside a Postgres transaction. The `tx` argument is a `Storage`
   * scoped to the transaction's `sql` handle — every call on `tx.modules`,
   * `tx.agents`, or `tx.snapshots` participates in the same BEGIN/COMMIT
   * boundary. Throwing from `fn` triggers a ROLLBACK; returning normally
   * triggers COMMIT.
   *
   * Nested calls open a savepoint via the same `txSql.begin` so the inner
   * commit/rollback only affects work since the savepoint, not the whole
   * outer transaction. The previous implementation bound
   * `this.withTransaction` (= the *outer* pool's begin), which silently
   * opened a parallel BEGIN that didn't participate in the savepoint —
   * BUG-03 in /review/02-phase2-modules.md.
   */
  async withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T> {
    return runInTx(this.sql, fn) as Promise<T>;
  }

  async close(): Promise<void> {
    await this.sql.end();
  }
}

// ─── Transaction helper ────────────────────────────────────────────────────

/**
 * Open a transaction (or savepoint, when called with a TransactionSql)
 * via `sqlHandle.begin(...)` and run `fn` against a Storage facade scoped
 * to the inner `txSql`.
 *
 * The `postgres` driver's `.begin` is the key: invoked on a pool it
 * starts a new BEGIN; invoked on a TransactionSql it issues a savepoint.
 * That makes this function reentrant — `txStorage.withTransaction(...)`
 * inside an outer block reuses the inner sql handle and creates a
 * savepoint, instead of (incorrectly) starting a parallel transaction
 * on the outer pool.
 */
function runInTx<T>(
  sqlHandle: Sql,
  fn: (tx: Storage) => Promise<T>,
): Promise<T> {
  // `sqlHandle` may be either the pool Sql or a TransactionSql. Both
  // expose `.begin(...)` with the same signature. The cast keeps
  // TypeScript happy because the postgres types narrow `.begin` differently
  // for these two.
  const begin = (sqlHandle as unknown as { begin: typeof sqlHandle.begin }).begin.bind(sqlHandle);
  return begin(async (txSql) => {
    const innerSql = txSql as unknown as Sql;
    const txStorage: Storage = {
      modules: new PgModuleRepo(innerSql),
      agents: new PgAgentRepo(innerSql),
      snapshots: new PgSnapshotRepo(innerSql),
      diffs: new PgDiffRepo(innerSql),
      // Bind the *inner* sql so nested calls use savepoints on it,
      // not new BEGINs on the outer pool.
      withTransaction: (innerFn) => runInTx(innerSql, innerFn),
    };
    return fn(txStorage);
  }) as Promise<T>;
}
