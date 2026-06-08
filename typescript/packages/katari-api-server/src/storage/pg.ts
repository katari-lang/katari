// Postgres-backed `Storage`. The bin entrypoint constructs this; tests use
// `InMemoryStorage` instead so they need not provision a database.
//
// Each repo wraps the same `sql` handle so they all participate in the
// same transaction when invoked under `withTransaction`. Concurrency
// control is via an advisory lock (`withSnapshotLock`) — the stateless
// orchestrator holds the snapshot's lock during one request's engine
// work and releases on commit.

import type {
  AgentDefId,
  DelegationId,
  EncryptedValue,
  EngineCheckpoint,
  EntityId,
  EscalationId,
  IRModule,
  Json,
  ProjectIndexStore,
  SchemaBundle,
  ScopeStore,
  ShardStore,
  ValueStore,
} from "@katari-lang/runtime";
import postgres from "postgres";
import { v7 as uuidv7 } from "uuid";
import { decodeCursor, encodeCursor } from "../cursor.js";
import type { BlobStore } from "./blob-store.js";
import { PgScopeStore } from "./scope-store-pg.js";
import { PgProjectIndexStore, PgShardStore } from "./shard-store-pg.js";
import type {
  CancelReason,
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
import { PgValueStore } from "./value-store-pg.js";

type Sql = ReturnType<typeof postgres>;

/**
 * Helper for the `postgres` driver's `sql.json(...)` argument: the
 * driver types it as a domain-specific `JSONValue` that doesn't
 * structurally intersect with our 'Json' type. We accept anything that
 * fits our project-wide 'Json' (the recursive structural JSON type) and
 * adapt to the driver's expected shape at the call site.
 *
 * Secret encryption is the **caller's** responsibility (= each
 * Module's persistor encrypts at its typed boundary via
 * 'value-secret-codec' before handing data here); the storage layer
 * just persists what it's given.
 */
function asJson(value: Json): never {
  return value as never;
}

/**
 * Postgres `text` / `jsonb` cannot store U+0000 (NUL): a NUL anywhere in a
 * snapshot payload (IR / schema bundle / bundled ext JS) otherwise surfaces as
 * an opaque `unsupported Unicode escape sequence` from the driver, deep inside
 * an insert. Scan up front and fail with the exact field + offset + context so
 * the source is obvious. Cold path (once per apply), so the deep walk is fine.
 */
function assertNoNul(value: unknown, label: string): void {
  const visit = (node: unknown, path: string): void => {
    if (typeof node === "string") {
      const at = node.indexOf("\u0000");
      if (at >= 0) {
        const context = node.slice(Math.max(0, at - 30), at + 30);
        throw new Error(
          `snapshot ${label}${path} contains a NUL byte (U+0000) at offset ${at}, ` +
            `which Postgres cannot store. Context: ${JSON.stringify(context)}`,
        );
      }
    } else if (Array.isArray(node)) {
      node.forEach((element, index) => {
        visit(element, `${path}[${index}]`);
      });
    } else if (node !== null && typeof node === "object") {
      for (const [key, element] of Object.entries(node)) visit(element, `${path}.${key}`);
    }
  };
  visit(value, "");
}

/**
 * Identity helper retained at the call sites that previously decrypted
 * on read. With encryption now living inside each Module's persistor,
 * storage hands back whatever JSON was persisted; the Module decrypts
 * on the way out. This shim keeps the call-site shape stable so the
 * post-refactor Module wiring can land in one pass — once every
 * caller has moved to the new persistor, the shim disappears.
 */
function fromStorageJson<T>(value: T): T {
  return value;
}

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

function clampLimit(requested: number | undefined): number {
  if (requested === undefined) return DEFAULT_LIMIT;
  if (!Number.isFinite(requested) || requested <= 0) return DEFAULT_LIMIT;
  return Math.min(MAX_LIMIT, Math.floor(requested));
}

function _clampOffset(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested) || requested < 0) {
    return 0;
  }
  return Math.floor(requested);
}

/**
 * Compose a list of optional `sql` fragments into a single `WHERE`
 * clause. Used by every list() that has 4+ optional filter dimensions —
 * the alternative (one big if/else tree) was unmaintainable.
 */
function composeWhere(sql: Sql, pieces: ReadonlyArray<ReturnType<Sql> | null>): ReturnType<Sql> {
  const kept = pieces.filter((p): p is NonNullable<typeof p> => p !== null);
  if (kept.length === 0) return sql``;
  return sql`WHERE ${kept.reduce((acc, p, i) => (i === 0 ? p : sql`${acc} AND ${p}`))}`;
}

// ─── Project ───────────────────────────────────────────────────────────────

type DbProjectRow = {
  id: string;
  name: string;
  description: string | null;
  readme: string | null;
  created_at: Date;
};

function dbToProject(row: DbProjectRow): Project {
  return {
    id: row.id as ProjectId,
    name: row.name,
    description: row.description,
    readme: row.readme,
    createdAt: row.created_at.toISOString(),
  };
}

class PgProjectRepo implements ProjectRepo {
  constructor(private readonly sql: Sql) {}

  async upsertProject(input: UpsertProjectInput): Promise<Project> {
    const id = uuidv7();
    // COALESCE semantics: when the caller omits a field (= passes
    // `undefined`, normalised to `null` on the wire here as a sentinel
    // "no change"), the existing value is kept. To distinguish "clear"
    // from "skip" we send a second boolean per column.
    const setDescription = input.description !== undefined;
    const setReadme = input.readme !== undefined;
    const rows = await this.sql<DbProjectRow[]>`
      INSERT INTO projects (id, name, description, readme, created_at)
      VALUES (
        ${id},
        ${input.name},
        ${input.description ?? null},
        ${input.readme ?? null},
        now()
      )
      ON CONFLICT (name) DO UPDATE SET
        description = CASE WHEN ${setDescription} THEN EXCLUDED.description ELSE projects.description END,
        readme      = CASE WHEN ${setReadme}      THEN EXCLUDED.readme      ELSE projects.readme      END
      RETURNING id, name, description, readme, created_at
    `;
    return dbToProject(rows[0]!);
  }

  async list(options?: ListOptions): Promise<ListResult<Project>> {
    const limit = clampLimit(options?.limit);
    const cursor = options?.cursor !== undefined ? decodeCursor(options.cursor) : null;
    const fetchCount = limit + 1;
    const rows =
      cursor !== null
        ? await this.sql<DbProjectRow[]>`
          SELECT id, name, description, readme, created_at
          FROM projects
          WHERE (created_at, id) < (${cursor.createdAt}, ${cursor.id})
          ORDER BY created_at DESC, id DESC
          LIMIT ${fetchCount}
        `
        : await this.sql<DbProjectRow[]>`
          SELECT id, name, description, readme, created_at
          FROM projects
          ORDER BY created_at DESC, id DESC
          LIMIT ${fetchCount}
        `;
    const hasMore = rows.length > limit;
    const items = (hasMore ? rows.slice(0, limit) : rows).map(dbToProject);
    const last = items[items.length - 1];
    return {
      items,
      nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, last.id) : null,
    };
  }

  async get(id: ProjectId): Promise<Project | null> {
    const rows = await this.sql<DbProjectRow[]>`
      SELECT id, name, description, readme, created_at
      FROM projects WHERE id = ${id}
    `;
    const row = rows[0];
    return row !== undefined ? dbToProject(row) : null;
  }

  async getByName(name: string): Promise<Project | null> {
    const rows = await this.sql<DbProjectRow[]>`
      SELECT id, name, description, readme, created_at
      FROM projects WHERE name = ${name}
    `;
    const row = rows[0];
    return row !== undefined ? dbToProject(row) : null;
  }

  async delete(id: ProjectId): Promise<boolean> {
    const result = await this.sql`DELETE FROM projects WHERE id = ${id}`;
    return result.count > 0;
  }
}

// ─── Snapshot ──────────────────────────────────────────────────────────────

type DbSnapshotRow = {
  id: string;
  project_id: string;
  ir_module: IRModule;
  sidecar_bundle: SidecarBundle | null;
  schema_bundle: SchemaBundle;
  message: string;
  created_at: Date;
};

class PgSnapshotRepo implements SnapshotRepo {
  constructor(private readonly sql: Sql) {}

  async insert(input: {
    projectId: ProjectId;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
    message: string;
  }): Promise<SnapshotId> {
    // Postgres can't store NUL — surface a precise field + location instead of
    // the driver's opaque `unsupported Unicode escape sequence` deep in INSERT.
    assertNoNul(input.irModule, "irModule");
    if (input.sidecarBundle !== null) assertNoNul(input.sidecarBundle, "sidecarBundle");
    assertNoNul(input.schemaBundle, "schemaBundle");
    const id = uuidv7();
    await this.sql`
      INSERT INTO snapshots (id, project_id, ir_module, sidecar_bundle, schema_bundle, message, created_at)
      VALUES (
        ${id},
        ${input.projectId},
        ${this.sql.json(asJson(input.irModule))},
        ${input.sidecarBundle === null ? null : this.sql.json(asJson(input.sidecarBundle))},
        ${this.sql.json(asJson(input.schemaBundle))},
        ${input.message},
        now()
      )
    `;
    return id as SnapshotId;
  }

  async get(id: SnapshotId): Promise<Snapshot | null> {
    const rows = await this.sql<DbSnapshotRow[]>`
      SELECT id, project_id, ir_module, sidecar_bundle, schema_bundle, message, created_at
      FROM snapshots
      WHERE id = ${id}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      id: row.id as SnapshotId,
      projectId: row.project_id as ProjectId,
      irModule: row.ir_module,
      sidecarBundle: row.sidecar_bundle,
      schemaBundle: row.schema_bundle,
      message: row.message,
      createdAt: row.created_at.toISOString(),
    };
  }

  async list(
    filter?: { projectId?: ProjectId } & ListOptions,
  ): Promise<ListResult<SnapshotSummary>> {
    const limit = clampLimit(filter?.limit);
    const cursor = filter?.cursor !== undefined ? decodeCursor(filter.cursor) : null;
    const fetchCount = limit + 1;
    const sql = this.sql;
    const projectFilter =
      filter?.projectId !== undefined ? sql`project_id = ${filter.projectId}` : null;
    const cursorFilter =
      cursor !== null ? sql`(created_at, id) < (${cursor.createdAt}, ${cursor.id})` : null;
    const pieces = [projectFilter, cursorFilter].filter(
      (p): p is NonNullable<typeof p> => p !== null,
    );
    const whereClause =
      pieces.length === 0
        ? sql``
        : sql`WHERE ${pieces.reduce((acc, p, i) => (i === 0 ? p : sql`${acc} AND ${p}`))}`;
    const rows = await sql<{ id: string; project_id: string; message: string; created_at: Date }[]>`
      SELECT id, project_id, message, created_at
      FROM snapshots
      ${whereClause}
      ORDER BY created_at DESC, id DESC
      LIMIT ${fetchCount}
    `;
    const hasMore = rows.length > limit;
    const items = (hasMore ? rows.slice(0, limit) : rows).map((r) => ({
      id: r.id as SnapshotId,
      projectId: r.project_id as ProjectId,
      message: r.message,
      createdAt: r.created_at.toISOString(),
    }));
    const last = items[items.length - 1];
    return {
      items,
      nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, last.id) : null,
    };
  }

  async latest(projectId: ProjectId): Promise<SnapshotId | null> {
    // Order by (created_at DESC, id DESC) so two snapshots written
    // within the same now() tick — possible on a fast loop — produce a
    // deterministic winner. The id is uuidv7-ish (time-ordered) so
    // ties on created_at also break in chronological order.
    const rows = await this.sql<{ id: string }[]>`
      SELECT id FROM snapshots
      WHERE project_id = ${projectId}
      ORDER BY created_at DESC, id DESC
      LIMIT 1
    `;
    return (rows[0]?.id as SnapshotId | undefined) ?? null;
  }

  async delete(id: SnapshotId): Promise<boolean> {
    const result = await this.sql`DELETE FROM snapshots WHERE id = ${id}`;
    return result.count > 0;
  }
}

// ─── EngineCheckpoint ──────────────────────────────────────────────────────

class PgEngineCheckpointRepo implements EngineCheckpointRepo {
  constructor(private readonly sql: Sql) {}

  async upsert(snapshotId: SnapshotId, checkpoint: EngineCheckpoint): Promise<void> {
    await this.sql`
      INSERT INTO engine_checkpoints (snapshot_id, checkpoint, updated_at)
      VALUES (${snapshotId}, ${this.sql.json(asJson(checkpoint))}, now())
      ON CONFLICT (snapshot_id) DO UPDATE
        SET checkpoint = EXCLUDED.checkpoint,
            updated_at = EXCLUDED.updated_at
    `;
  }

  async get(snapshotId: SnapshotId): Promise<EngineCheckpoint | null> {
    const rows = await this.sql<{ checkpoint: EngineCheckpoint }[]>`
      SELECT checkpoint FROM engine_checkpoints WHERE snapshot_id = ${snapshotId}
    `;
    const rawCheckpoint = rows[0]?.checkpoint;
    if (rawCheckpoint === undefined || rawCheckpoint === null) return null;
    const checkpoint = fromStorageJson(rawCheckpoint);
    // Legacy compat: pre-v0.1.0-rc4 deployments used a `{}` placeholder
    // row to anchor `SELECT ... FOR UPDATE` locks. Current code uses an
    // advisory lock instead and never inserts placeholders, but rows
    // left by older servers can still be in the DB after an upgrade.
    // Treat any object lacking `schemaVersion` as "no real checkpoint
    // yet" so the engine boots a fresh state and overwrites it on
    // persist.
    if (
      typeof checkpoint === "object" &&
      !Array.isArray(checkpoint) &&
      (checkpoint as { schemaVersion?: unknown }).schemaVersion === undefined
    ) {
      return null;
    }
    return checkpoint;
  }

  async delete(snapshotId: SnapshotId): Promise<void> {
    await this.sql`DELETE FROM engine_checkpoints WHERE snapshot_id = ${snapshotId}`;
  }
}

// ─── Entities (receiver-managed execution node) ────────────────────────────

type DbEntityRow = {
  id: string;
  delegation_id: string | null;
  project_id: string;
  module: EntityModule;
  state: EntityState;
  agent_def_id: AgentDefId | null;
  args: Record<string, EncryptedValue>;
  created_at: Date;
  updated_at: Date;
};

function dbToEntityRow(row: DbEntityRow): EntityRow {
  return {
    id: row.id as EntityId,
    delegationId: row.delegation_id === null ? null : (row.delegation_id as DelegationId),
    projectId: row.project_id as ProjectId,
    module: row.module,
    state: row.state,
    agentDefId: row.agent_def_id,
    args: fromStorageJson(row.args),
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

class PgEntityRepo implements EntityRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: EntityRow): Promise<void> {
    await this.sql`
      INSERT INTO entities (
        id, delegation_id, project_id, module, state, agent_def_id, args,
        created_at, updated_at
      ) VALUES (
        ${row.id}, ${row.delegationId}, ${row.projectId}, ${row.module}, ${row.state},
        ${row.agentDefId === null ? null : this.sql.json(asJson(row.agentDefId))},
        ${this.sql.json(asJson(row.args))},
        ${row.createdAt}, ${row.updatedAt}
      )
    `;
  }

  async get(id: EntityId): Promise<EntityRow | null> {
    const rows = await this.sql<DbEntityRow[]>`
      SELECT id, delegation_id, project_id, module, state, agent_def_id, args,
             created_at, updated_at
      FROM entities WHERE id = ${id}
    `;
    return rows[0] !== undefined ? dbToEntityRow(rows[0]) : null;
  }

  async getByDelegation(
    projectId: ProjectId,
    delegationId: DelegationId,
  ): Promise<EntityRow | null> {
    const rows = await this.sql<DbEntityRow[]>`
      SELECT id, delegation_id, project_id, module, state, agent_def_id, args,
             created_at, updated_at
      FROM entities WHERE project_id = ${projectId} AND delegation_id = ${delegationId}
    `;
    return rows[0] !== undefined ? dbToEntityRow(rows[0]) : null;
  }

  async setState(
    id: EntityId,
    state: EntityState,
    options?: { expectedState?: EntityState },
  ): Promise<boolean> {
    const result =
      options?.expectedState !== undefined
        ? await this.sql`
          UPDATE entities SET state = ${state}, updated_at = now()
          WHERE id = ${id} AND state = ${options.expectedState}
        `
        : await this.sql`
          UPDATE entities SET state = ${state}, updated_at = now()
          WHERE id = ${id}
        `;
    return result.count > 0;
  }

  async delete(id: EntityId): Promise<boolean> {
    // Cascades the entity's still-owned refs + raised escalations (FK); the
    // refs-delete trigger decrements blob refcounts. Freed bytes are reaped
    // separately by `ValueStore.reapFreedBlobs`.
    const result = await this.sql`DELETE FROM entities WHERE id = ${id}`;
    return result.count > 0;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      module?: EntityModule;
      state?: EntityState;
    } & ListOptions,
  ): Promise<ListResult<EntityRow>> {
    const limit = clampLimit(filter?.limit);
    const cursor = filter?.cursor !== undefined ? decodeCursor(filter.cursor) : null;
    const fetchCount = limit + 1;
    const sql = this.sql;
    const whereClause = composeWhere(sql, [
      filter?.projectId !== undefined ? sql`project_id = ${filter.projectId}` : null,
      filter?.module !== undefined ? sql`module = ${filter.module}` : null,
      filter?.state !== undefined ? sql`state = ${filter.state}` : null,
      cursor !== null ? sql`(created_at, id) > (${cursor.createdAt}, ${cursor.id})` : null,
    ]);
    const rows = await sql<DbEntityRow[]>`
      SELECT id, delegation_id, project_id, module, state, agent_def_id, args,
             created_at, updated_at
      FROM entities
      ${whereClause}
      ORDER BY created_at ASC, id ASC LIMIT ${fetchCount}
    `;
    const hasMore = rows.length > limit;
    const items = (hasMore ? rows.slice(0, limit) : rows).map(dbToEntityRow);
    const last = items[items.length - 1];
    return {
      items,
      nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, last.id) : null,
    };
  }
}

// ─── Delegations (issuer-managed request edge) ─────────────────────────────

type DbDelegationRow = {
  id: string;
  project_id: string;
  parent_entity_id: string;
  target_module: EntityModule;
  agent_def_id: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: DelegationState;
  created_at: Date;
  updated_at: Date;
};

function dbToDelegationRow(row: DbDelegationRow): DelegationRow {
  return {
    id: row.id as DelegationId,
    projectId: row.project_id as ProjectId,
    parentEntityId: row.parent_entity_id as EntityId,
    targetModule: row.target_module,
    agentDefId: row.agent_def_id,
    args: fromStorageJson(row.args),
    state: row.state,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

class PgDelegationRepo implements DelegationRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: DelegationRow): Promise<void> {
    await this.sql`
      INSERT INTO delegations (
        id, project_id, parent_entity_id, target_module, agent_def_id, args,
        state, created_at, updated_at
      ) VALUES (
        ${row.id}, ${row.projectId}, ${row.parentEntityId}, ${row.targetModule},
        ${this.sql.json(asJson(row.agentDefId))},
        ${this.sql.json(asJson(row.args))},
        ${row.state}, ${row.createdAt}, ${row.updatedAt}
      )
    `;
  }

  async get(id: DelegationId): Promise<DelegationRow | null> {
    const rows = await this.sql<DbDelegationRow[]>`
      SELECT id, project_id, parent_entity_id, target_module, agent_def_id, args, state,
             created_at, updated_at
      FROM delegations WHERE id = ${id}
    `;
    return rows[0] !== undefined ? dbToDelegationRow(rows[0]) : null;
  }

  async setState(
    id: DelegationId,
    state: DelegationState,
    options?: { expectedState?: DelegationState },
  ): Promise<boolean> {
    const result =
      options?.expectedState !== undefined
        ? await this.sql`
          UPDATE delegations SET state = ${state}, updated_at = now()
          WHERE id = ${id} AND state = ${options.expectedState}
        `
        : await this.sql`
          UPDATE delegations SET state = ${state}, updated_at = now()
          WHERE id = ${id}
        `;
    return result.count > 0;
  }

  async delete(id: DelegationId): Promise<boolean> {
    const result = await this.sql`DELETE FROM delegations WHERE id = ${id}`;
    return result.count > 0;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      parentEntityId?: EntityId;
      state?: DelegationState;
    } & ListOptions,
  ): Promise<ListResult<DelegationRow>> {
    const limit = clampLimit(filter?.limit);
    const cursor = filter?.cursor !== undefined ? decodeCursor(filter.cursor) : null;
    const fetchCount = limit + 1;
    const sql = this.sql;
    const whereClause = composeWhere(sql, [
      filter?.projectId !== undefined ? sql`project_id = ${filter.projectId}` : null,
      filter?.parentEntityId !== undefined
        ? sql`parent_entity_id = ${filter.parentEntityId}`
        : null,
      filter?.state !== undefined ? sql`state = ${filter.state}` : null,
      cursor !== null ? sql`(created_at, id) > (${cursor.createdAt}, ${cursor.id})` : null,
    ]);
    const rows = await sql<DbDelegationRow[]>`
      SELECT id, project_id, parent_entity_id, target_module, agent_def_id, args, state,
             created_at, updated_at
      FROM delegations
      ${whereClause}
      ORDER BY created_at ASC, id ASC LIMIT ${fetchCount}
    `;
    const hasMore = rows.length > limit;
    const items = (hasMore ? rows.slice(0, limit) : rows).map(dbToDelegationRow);
    const last = items[items.length - 1];
    return {
      items,
      nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, last.id) : null,
    };
  }
}

// ─── Escalations (raiser-owned, open only) ─────────────────────────────────

type DbEscalationRow = {
  id: string;
  entity_id: string;
  project_id: string;
  agent_def_id: AgentDefId;
  args: Record<string, EncryptedValue>;
  created_at: Date;
};

function dbToEscalationRow(row: DbEscalationRow): EscalationRow {
  return {
    id: row.id as EscalationId,
    entityId: row.entity_id as EntityId,
    projectId: row.project_id as ProjectId,
    agentDefId: row.agent_def_id,
    args: fromStorageJson(row.args),
    createdAt: row.created_at.toISOString(),
  };
}

class PgEscalationRepo implements EscalationRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: EscalationRow): Promise<void> {
    await this.sql`
      INSERT INTO escalations (id, entity_id, project_id, agent_def_id, args, state, created_at)
      VALUES (
        ${row.id}, ${row.entityId}, ${row.projectId},
        ${this.sql.json(asJson(row.agentDefId))},
        ${this.sql.json(asJson(row.args))},
        'open', ${row.createdAt}
      )
    `;
  }

  async get(id: EscalationId): Promise<EscalationRow | null> {
    const rows = await this.sql<DbEscalationRow[]>`
      SELECT id, entity_id, project_id, agent_def_id, args, created_at
      FROM escalations WHERE id = ${id}
    `;
    return rows[0] !== undefined ? dbToEscalationRow(rows[0]) : null;
  }

  async delete(id: EscalationId): Promise<boolean> {
    const result = await this.sql`DELETE FROM escalations WHERE id = ${id}`;
    return result.count > 0;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      entityId?: EntityId;
    } & ListOptions,
  ): Promise<ListResult<EscalationRow>> {
    const limit = clampLimit(filter?.limit);
    const cursor = filter?.cursor !== undefined ? decodeCursor(filter.cursor) : null;
    const fetchCount = limit + 1;
    const sql = this.sql;
    const whereClause = composeWhere(sql, [
      filter?.projectId !== undefined ? sql`project_id = ${filter.projectId}` : null,
      filter?.entityId !== undefined ? sql`entity_id = ${filter.entityId}` : null,
      cursor !== null ? sql`(created_at, id) < (${cursor.createdAt}, ${cursor.id})` : null,
    ]);
    const rows = await sql<DbEscalationRow[]>`
      SELECT id, entity_id, project_id, agent_def_id, args, created_at
      FROM escalations
      ${whereClause}
      ORDER BY created_at DESC, id DESC LIMIT ${fetchCount}
    `;
    const hasMore = rows.length > limit;
    const items = (hasMore ? rows.slice(0, limit) : rows).map(dbToEscalationRow);
    const last = items[items.length - 1];
    return {
      items,
      nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, last.id) : null,
    };
  }
}

// ─── Runs (the API module's per-run management record) ─────────────────────

type DbRunRow = {
  id: string;
  project_id: string;
  snapshot_id: string;
  core_delegation_id: string;
  name: string;
  qualified_name: string;
  args: Record<string, EncryptedValue>;
  state: RunState;
  cancel_reason: CancelReason | null;
  result: EncryptedValue | null;
  error_message: string | null;
  created_at: Date;
  updated_at: Date;
  completed_at: Date | null;
};

function dbToRunRow(row: DbRunRow): RunRow {
  return {
    id: row.id as RunId,
    projectId: row.project_id as ProjectId,
    snapshotId: row.snapshot_id as SnapshotId,
    coreDelegationId: row.core_delegation_id as DelegationId,
    name: row.name,
    qualifiedName: row.qualified_name,
    args: fromStorageJson(row.args),
    state: row.state,
    cancelReason: row.cancel_reason,
    result: row.result === null ? undefined : fromStorageJson(row.result),
    errorMessage: row.error_message === null ? undefined : row.error_message,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
    completedAt: row.completed_at === null ? undefined : row.completed_at.toISOString(),
  };
}

class PgRunRepo implements RunRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: RunRow): Promise<void> {
    await this.sql`
      INSERT INTO runs (
        id, project_id, snapshot_id, core_delegation_id, name, qualified_name, args,
        state, cancel_reason, result, error_message, created_at, updated_at, completed_at
      ) VALUES (
        ${row.id}, ${row.projectId}, ${row.snapshotId}, ${row.coreDelegationId},
        ${row.name}, ${row.qualifiedName}, ${this.sql.json(asJson(row.args))},
        ${row.state}, ${row.cancelReason},
        ${row.result === undefined ? null : this.sql.json(asJson(row.result))},
        ${row.errorMessage ?? null},
        ${row.createdAt}, ${row.updatedAt}, ${row.completedAt ?? null}
      )
    `;
  }

  async get(id: RunId): Promise<RunRow | null> {
    const rows = await this.sql<DbRunRow[]>`
      SELECT id, project_id, snapshot_id, core_delegation_id, name, qualified_name, args,
             state, cancel_reason, result, error_message, created_at, updated_at, completed_at
      FROM runs WHERE id = ${id}
    `;
    return rows[0] !== undefined ? dbToRunRow(rows[0]) : null;
  }

  async getByCoreDelegation(coreDelegationId: DelegationId): Promise<RunRow | null> {
    const rows = await this.sql<DbRunRow[]>`
      SELECT id, project_id, snapshot_id, core_delegation_id, name, qualified_name, args,
             state, cancel_reason, result, error_message, created_at, updated_at, completed_at
      FROM runs WHERE core_delegation_id = ${coreDelegationId}
    `;
    return rows[0] !== undefined ? dbToRunRow(rows[0]) : null;
  }

  async list(
    filter?: {
      projectId?: ProjectId;
      snapshotId?: SnapshotId;
      state?: RunState;
    } & ListOptions,
  ): Promise<ListResult<RunRow>> {
    const limit = clampLimit(filter?.limit);
    const cursor = filter?.cursor !== undefined ? decodeCursor(filter.cursor) : null;
    const fetchCount = limit + 1;
    const sql = this.sql;
    const whereClause = composeWhere(sql, [
      filter?.projectId !== undefined ? sql`project_id = ${filter.projectId}` : null,
      filter?.snapshotId !== undefined ? sql`snapshot_id = ${filter.snapshotId}` : null,
      filter?.state !== undefined ? sql`state = ${filter.state}` : null,
      cursor !== null ? sql`(created_at, id) < (${cursor.createdAt}, ${cursor.id})` : null,
    ]);
    const rows = await sql<DbRunRow[]>`
      SELECT id, project_id, snapshot_id, core_delegation_id, name, qualified_name, args,
             state, cancel_reason, result, error_message, created_at, updated_at, completed_at
      FROM runs
      ${whereClause}
      ORDER BY created_at DESC, id DESC LIMIT ${fetchCount}
    `;
    const hasMore = rows.length > limit;
    const items = (hasMore ? rows.slice(0, limit) : rows).map(dbToRunRow);
    const last = items[items.length - 1];
    return {
      items,
      nextCursor: hasMore && last !== undefined ? encodeCursor(last.createdAt, last.id) : null,
    };
  }

  async setState(
    id: RunId,
    patch: {
      state: RunState;
      cancelReason?: CancelReason | null;
      result?: EncryptedValue;
      errorMessage?: string;
      completedAt?: string;
    },
  ): Promise<boolean> {
    const sets: ReturnType<Sql>[] = [this.sql`state = ${patch.state}`];
    if (patch.cancelReason !== undefined) {
      sets.push(this.sql`cancel_reason = ${patch.cancelReason}`);
    }
    if (patch.result !== undefined) {
      sets.push(this.sql`result = ${this.sql.json(asJson(patch.result))}`);
    }
    if (patch.errorMessage !== undefined) {
      sets.push(this.sql`error_message = ${patch.errorMessage}`);
    }
    if (patch.completedAt !== undefined) {
      sets.push(this.sql`completed_at = ${patch.completedAt}`);
    }
    sets.push(this.sql`updated_at = now()`);
    const setSql = sets.reduce((acc, cur, i) => (i === 0 ? cur : this.sql`${acc}, ${cur}`));
    const result = await this.sql`UPDATE runs SET ${setSql} WHERE id = ${id}`;
    return result.count > 0;
  }
}

// ─── Run escalations audit (answered, user-facing escalations) ─────────────

type DbRunEscalationAuditRow = {
  run_id: string;
  escalation_id: string;
  agent_def_id: AgentDefId;
  args: Record<string, EncryptedValue>;
  answer: EncryptedValue | null;
  created_at: Date;
  answered_at: Date | null;
};

function dbToRunEscalationAuditRow(row: DbRunEscalationAuditRow): RunEscalationAuditRow {
  return {
    runId: row.run_id as RunId,
    escalationId: row.escalation_id as EscalationId,
    agentDefId: row.agent_def_id,
    args: fromStorageJson(row.args),
    answer: row.answer === null ? undefined : fromStorageJson(row.answer),
    createdAt: row.created_at.toISOString(),
    answeredAt: row.answered_at === null ? undefined : row.answered_at.toISOString(),
  };
}

class PgRunEscalationsAuditRepo implements RunEscalationsAuditRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: RunEscalationAuditRow): Promise<void> {
    await this.sql`
      INSERT INTO run_escalations_audit (run_id, escalation_id, agent_def_id, args, answer, created_at, answered_at)
      VALUES (
        ${row.runId}, ${row.escalationId},
        ${this.sql.json(asJson(row.agentDefId))},
        ${this.sql.json(asJson(row.args))},
        ${row.answer === undefined ? null : this.sql.json(asJson(row.answer))},
        ${row.createdAt}, ${row.answeredAt ?? null}
      )
      ON CONFLICT (run_id, escalation_id) DO NOTHING
    `;
  }

  async get(escalationId: EscalationId): Promise<RunEscalationAuditRow | null> {
    const rows = await this.sql<DbRunEscalationAuditRow[]>`
      SELECT run_id, escalation_id, agent_def_id, args, answer, created_at, answered_at
      FROM run_escalations_audit WHERE escalation_id = ${escalationId}
    `;
    return rows[0] !== undefined ? dbToRunEscalationAuditRow(rows[0]) : null;
  }

  async setAnswer(
    escalationId: EscalationId,
    answer: EncryptedValue,
    answeredAt: string,
  ): Promise<boolean> {
    const result = await this.sql`
      UPDATE run_escalations_audit
      SET answer = ${this.sql.json(asJson(answer))}, answered_at = ${answeredAt}
      WHERE escalation_id = ${escalationId}
    `;
    return result.count > 0;
  }

  async list(runId: RunId): Promise<RunEscalationAuditRow[]> {
    const rows = await this.sql<DbRunEscalationAuditRow[]>`
      SELECT run_id, escalation_id, agent_def_id, args, answer, created_at, answered_at
      FROM run_escalations_audit WHERE run_id = ${runId}
      ORDER BY created_at ASC
    `;
    return rows.map(dbToRunEscalationAuditRow);
  }
}

// ─── FFI pending tables (private to FFI Module; Phase 5 will unify) ────────

class PgFfiPendingDelegationRepo implements FfiPendingDelegationRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: FfiPendingDelegation): Promise<void> {
    await this.sql`
      INSERT INTO ffi_pending_delegations
        (delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, state, created_at, parent_ext_delegation_id)
      VALUES (${row.delegationId}, ${row.snapshotId}, ${row.peerEndpoint},
              ${this.sql.json(asJson(row.agentDefId))},
              ${this.sql.json(asJson(row.args))},
              ${row.state}, ${row.createdAt},
              ${row.parentExtDelegationId})
    `;
  }

  async get(delegationId: DelegationId): Promise<FfiPendingDelegation | null> {
    const rows = await this.sql<
      {
        delegation_id: string;
        snapshot_id: string;
        peer_endpoint: string;
        agent_def_id: AgentDefId;
        args: Record<string, EncryptedValue>;
        state: "running" | "cancelling";
        created_at: Date;
        parent_ext_delegation_id: string | null;
      }[]
    >`
      SELECT delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, state, created_at, parent_ext_delegation_id
      FROM ffi_pending_delegations WHERE delegation_id = ${delegationId}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      peerEndpoint: row.peer_endpoint,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      state: row.state,
      createdAt: row.created_at.toISOString(),
      parentExtDelegationId:
        row.parent_ext_delegation_id === null
          ? null
          : (row.parent_ext_delegation_id as DelegationId),
    };
  }

  async setState(delegationId: DelegationId, state: "running" | "cancelling"): Promise<boolean> {
    const result = await this.sql`
      UPDATE ffi_pending_delegations SET state = ${state} WHERE delegation_id = ${delegationId}
    `;
    return result.count > 0;
  }

  async delete(delegationId: DelegationId): Promise<boolean> {
    const result = await this.sql`
      DELETE FROM ffi_pending_delegations WHERE delegation_id = ${delegationId}
    `;
    return result.count > 0;
  }

  async listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingDelegation[]> {
    const rows = await this.sql<
      {
        delegation_id: string;
        snapshot_id: string;
        peer_endpoint: string;
        agent_def_id: AgentDefId;
        args: Record<string, EncryptedValue>;
        state: "running" | "cancelling";
        created_at: Date;
        parent_ext_delegation_id: string | null;
      }[]
    >`
      SELECT delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, state, created_at, parent_ext_delegation_id
      FROM ffi_pending_delegations WHERE snapshot_id = ${snapshotId}
    `;
    return rows.map((row) => ({
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      peerEndpoint: row.peer_endpoint,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      state: row.state,
      createdAt: row.created_at.toISOString(),
      parentExtDelegationId:
        row.parent_ext_delegation_id === null
          ? null
          : (row.parent_ext_delegation_id as DelegationId),
    }));
  }

  async listChildrenOf(parentDelegationId: DelegationId): Promise<FfiPendingDelegation[]> {
    const rows = await this.sql<
      {
        delegation_id: string;
        snapshot_id: string;
        peer_endpoint: string;
        agent_def_id: AgentDefId;
        args: Record<string, EncryptedValue>;
        state: "running" | "cancelling";
        created_at: Date;
        parent_ext_delegation_id: string | null;
      }[]
    >`
      SELECT delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, state, created_at, parent_ext_delegation_id
      FROM ffi_pending_delegations
      WHERE parent_ext_delegation_id = ${parentDelegationId}
    `;
    return rows.map((row) => ({
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      peerEndpoint: row.peer_endpoint,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      state: row.state,
      createdAt: row.created_at.toISOString(),
      parentExtDelegationId:
        row.parent_ext_delegation_id === null
          ? null
          : (row.parent_ext_delegation_id as DelegationId),
    }));
  }

  async listLiveSnapshotIds(): Promise<SnapshotId[]> {
    const rows = await this.sql<{ snapshot_id: string }[]>`
      SELECT DISTINCT snapshot_id FROM ffi_pending_delegations
    `;
    return rows.map((r) => r.snapshot_id as SnapshotId);
  }
}

class PgFfiPendingEscalationRepo implements FfiPendingEscalationRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: FfiPendingEscalation): Promise<void> {
    await this.sql`
      INSERT INTO ffi_pending_escalations (escalation_id, delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, created_at)
      VALUES (${row.escalationId}, ${row.delegationId}, ${row.snapshotId}, ${row.peerEndpoint},
              ${this.sql.json(asJson(row.agentDefId))},
              ${this.sql.json(asJson(row.args))},
              ${row.createdAt})
    `;
  }

  async get(escalationId: EscalationId): Promise<FfiPendingEscalation | null> {
    const rows = await this.sql<
      {
        escalation_id: string;
        delegation_id: string;
        snapshot_id: string;
        peer_endpoint: string;
        agent_def_id: AgentDefId;
        args: Record<string, EncryptedValue>;
        created_at: Date;
      }[]
    >`
      SELECT escalation_id, delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, created_at
      FROM ffi_pending_escalations WHERE escalation_id = ${escalationId}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      escalationId: row.escalation_id as EscalationId,
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      peerEndpoint: row.peer_endpoint,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      createdAt: row.created_at.toISOString(),
    };
  }

  async delete(escalationId: EscalationId): Promise<boolean> {
    const result = await this.sql`
      DELETE FROM ffi_pending_escalations WHERE escalation_id = ${escalationId}
    `;
    return result.count > 0;
  }

  async listBySnapshot(snapshotId: SnapshotId): Promise<FfiPendingEscalation[]> {
    const rows = await this.sql<
      {
        escalation_id: string;
        delegation_id: string;
        snapshot_id: string;
        peer_endpoint: string;
        agent_def_id: AgentDefId;
        args: Record<string, EncryptedValue>;
        created_at: Date;
      }[]
    >`
      SELECT escalation_id, delegation_id, snapshot_id, peer_endpoint, agent_def_id, args, created_at
      FROM ffi_pending_escalations WHERE snapshot_id = ${snapshotId}
    `;
    return rows.map((row) => ({
      escalationId: row.escalation_id as EscalationId,
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      peerEndpoint: row.peer_endpoint,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      createdAt: row.created_at.toISOString(),
    }));
  }
}

// ─── Env entries ────────────────────────────────────────────────────────────

class PgEnvEntryRepo implements EnvEntryRepo {
  constructor(private readonly sql: Sql) {}

  async get(projectId: ProjectId, key: string): Promise<EnvEntryRow | null> {
    const rows = await this.sql<
      { key: string; value: string; is_secret: boolean; updated_at: Date }[]
    >`
      SELECT key, value, is_secret, updated_at
      FROM env_entries WHERE project_id = ${projectId} AND key = ${key}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      key: row.key,
      value: row.value,
      isSecret: row.is_secret,
      updatedAt: row.updated_at.toISOString(),
    };
  }

  async upsert(row: {
    projectId: ProjectId;
    key: string;
    value: string;
    isSecret: boolean;
  }): Promise<void> {
    await this.sql`
      INSERT INTO env_entries (project_id, key, value, is_secret, updated_at)
      VALUES (${row.projectId}, ${row.key}, ${row.value}, ${row.isSecret}, now())
      ON CONFLICT (project_id, key) DO UPDATE
        SET value = EXCLUDED.value,
            is_secret = EXCLUDED.is_secret,
            updated_at = now()
    `;
  }

  async delete(projectId: ProjectId, key: string): Promise<boolean> {
    const result = await this
      .sql`DELETE FROM env_entries WHERE project_id = ${projectId} AND key = ${key}`;
    return result.count > 0;
  }

  async list(projectId: ProjectId): Promise<EnvEntryRow[]> {
    const rows = await this.sql<
      { key: string; value: string; is_secret: boolean; updated_at: Date }[]
    >`
      SELECT key, value, is_secret, updated_at FROM env_entries
      WHERE project_id = ${projectId} ORDER BY key
    `;
    return rows.map((r) => ({
      key: r.key,
      value: r.value,
      isSecret: r.is_secret,
      updatedAt: r.updated_at.toISOString(),
    }));
  }
}

// ─── Storage facade ────────────────────────────────────────────────────────

export class PostgresStorage implements Storage {
  readonly projects: ProjectRepo;
  readonly snapshots: SnapshotRepo;
  readonly checkpoints: EngineCheckpointRepo;
  readonly entities: EntityRepo;
  readonly delegations: DelegationRepo;
  readonly escalations: EscalationRepo;
  readonly runs: RunRepo;
  readonly runEscalationsAudit: RunEscalationsAuditRepo;
  readonly ffiDelegations: FfiPendingDelegationRepo;
  readonly ffiEscalations: FfiPendingEscalationRepo;
  readonly envEntries: EnvEntryRepo;
  readonly values: ValueStore;
  readonly shards: ShardStore;
  readonly projectIndex: ProjectIndexStore;
  readonly scopes: ScopeStore;

  private constructor(
    private readonly sql: Sql,
    private readonly blobStore: BlobStore,
  ) {
    this.projects = new PgProjectRepo(sql);
    this.snapshots = new PgSnapshotRepo(sql);
    this.checkpoints = new PgEngineCheckpointRepo(sql);
    this.entities = new PgEntityRepo(sql);
    this.delegations = new PgDelegationRepo(sql);
    this.escalations = new PgEscalationRepo(sql);
    this.runs = new PgRunRepo(sql);
    this.runEscalationsAudit = new PgRunEscalationsAuditRepo(sql);
    this.ffiDelegations = new PgFfiPendingDelegationRepo(sql);
    this.ffiEscalations = new PgFfiPendingEscalationRepo(sql);
    this.envEntries = new PgEnvEntryRepo(sql);
    this.values = new PgValueStore(sql, blobStore);
    this.shards = new PgShardStore(sql);
    this.projectIndex = new PgProjectIndexStore(sql);
    this.scopes = new PgScopeStore(sql);
  }

  static create(databaseUrl: string, blobStore: BlobStore): PostgresStorage {
    const sql = postgres(databaseUrl, { transform: { undefined: null } });
    return new PostgresStorage(sql, blobStore);
  }

  /**
   * Apply the bundled DDL. The shipped `schema.sql` is fully idempotent
   * (every CREATE uses IF NOT EXISTS), so re-running is safe on every
   * boot. Wrapping in a transaction is defensive: if one statement
   * mid-file fails, the partial DDL rolls back rather than leaving the
   * database half-migrated for the next boot to wrestle with.
   */
  async migrate(schemaSql: string): Promise<void> {
    await this.sql.begin(async (tx) => {
      await tx.unsafe(schemaSql);
    });
  }

  async withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T> {
    return runInTx(this.sql, this.blobStore, fn) as Promise<T>;
  }

  async withSnapshotLock<T>(tx: Storage, snapshotId: SnapshotId, fn: () => Promise<T>): Promise<T> {
    const inner = (tx as PostgresStorage).sql;
    await acquireSnapshotAdvisoryLock(inner, snapshotId);
    return fn();
  }

  async close(): Promise<void> {
    await this.sql.end();
  }
}

// ─── Transaction helper ────────────────────────────────────────────────────

function runInTx<T>(
  sqlHandle: Sql,
  blobStore: BlobStore,
  fn: (tx: Storage) => Promise<T>,
): Promise<T> {
  const begin = (sqlHandle as unknown as { begin: typeof sqlHandle.begin }).begin.bind(sqlHandle);
  return begin(async (txSql) => {
    const innerSql = txSql as unknown as Sql;
    const txStorage: Storage = {
      projects: new PgProjectRepo(innerSql),
      snapshots: new PgSnapshotRepo(innerSql),
      checkpoints: new PgEngineCheckpointRepo(innerSql),
      entities: new PgEntityRepo(innerSql),
      delegations: new PgDelegationRepo(innerSql),
      escalations: new PgEscalationRepo(innerSql),
      runs: new PgRunRepo(innerSql),
      runEscalationsAudit: new PgRunEscalationsAuditRepo(innerSql),
      ffiDelegations: new PgFfiPendingDelegationRepo(innerSql),
      ffiEscalations: new PgFfiPendingEscalationRepo(innerSql),
      envEntries: new PgEnvEntryRepo(innerSql),
      values: new PgValueStore(innerSql, blobStore),
      shards: new PgShardStore(innerSql),
      projectIndex: new PgProjectIndexStore(innerSql),
      scopes: new PgScopeStore(innerSql),
      withTransaction: (innerFn) => runInTx(innerSql, blobStore, innerFn),
      withSnapshotLock: async (_innerTx, snapshotId, body) => {
        await acquireSnapshotAdvisoryLock(innerSql, snapshotId);
        return body();
      },
    };
    return fn(txStorage);
  }) as Promise<T>;
}

/**
 * Per-snapshot transaction-scoped advisory lock.
 *
 * Postgres' `pg_advisory_xact_lock(bigint)` blocks until the key is
 * free and auto-releases on commit/rollback. Unlike `SELECT ... FOR
 * UPDATE` it doesn't need an existing row to anchor on, so we can
 * serialize ticks without inserting a placeholder checkpoint first
 * (the historical placeholder occasionally leaked into `core.load`
 * and tripped the engine's schemaVersion check).
 *
 * `hashtextextended(text, bigint)` returns int8 — exactly the type
 * `pg_advisory_xact_lock` takes. Collisions across snapshot UUIDs
 * are 2^-64-ish and harmless (= two unrelated snapshots would briefly
 * serialise) so we don't bother with a longer key.
 */
async function acquireSnapshotAdvisoryLock(sql: Sql, snapshotId: string): Promise<void> {
  await sql`SELECT pg_advisory_xact_lock(hashtextextended(${snapshotId}, 0))`;
}
