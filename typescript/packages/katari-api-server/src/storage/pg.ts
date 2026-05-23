// Postgres-backed `Storage`. The bin entrypoint constructs this; tests use
// `InMemoryStorage` instead so they need not provision a database.
//
// Each repo wraps the same `sql` handle so they all participate in the
// same transaction when invoked under `withTransaction`. Concurrency
// control is via `SELECT ... FOR UPDATE` (`withSnapshotLock`) — the
// stateless orchestrator holds the snapshot row lock during one request's
// engine work and releases on commit.

import postgres from "postgres";
import { v7 as uuidv7 } from "uuid";
import type {
  AgentDefId,
  DelegationId,
  EncryptedValue,
  EngineCheckpoint,
  EscalationId,
  IRModule,
  Json,
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

function clampOffset(requested: number | undefined): number {
  if (requested === undefined || !Number.isFinite(requested) || requested < 0) {
    return 0;
  }
  return Math.floor(requested);
}

// ─── Project ───────────────────────────────────────────────────────────────

class PgProjectRepo implements ProjectRepo {
  constructor(private readonly sql: Sql) {}

  async upsertByName(name: string): Promise<Project> {
    const id = uuidv7();
    const rows = await this.sql<
      { id: string; name: string; created_at: Date }[]
    >`
      INSERT INTO projects (id, name, created_at)
      VALUES (${id}, ${name}, now())
      ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
      RETURNING id, name, created_at
    `;
    const row = rows[0]!;
    return {
      id: row.id as ProjectId,
      name: row.name,
      createdAt: row.created_at.toISOString(),
    };
  }

  async list(options?: ListOptions): Promise<Project[]> {
    const limit = clampLimit(options?.limit);
    const offset = clampOffset(options?.offset);
    const rows = await this.sql<
      { id: string; name: string; created_at: Date }[]
    >`
      SELECT id, name, created_at
      FROM projects
      ORDER BY created_at DESC
      LIMIT ${limit} OFFSET ${offset}
    `;
    return rows.map((r) => ({
      id: r.id as ProjectId,
      name: r.name,
      createdAt: r.created_at.toISOString(),
    }));
  }

  async get(id: ProjectId): Promise<Project | null> {
    const rows = await this.sql<
      { id: string; name: string; created_at: Date }[]
    >`SELECT id, name, created_at FROM projects WHERE id = ${id}`;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      id: row.id as ProjectId,
      name: row.name,
      createdAt: row.created_at.toISOString(),
    };
  }

  async getByName(name: string): Promise<Project | null> {
    const rows = await this.sql<
      { id: string; name: string; created_at: Date }[]
    >`SELECT id, name, created_at FROM projects WHERE name = ${name}`;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      id: row.id as ProjectId,
      name: row.name,
      createdAt: row.created_at.toISOString(),
    };
  }

  async delete(id: ProjectId): Promise<boolean> {
    const result =
      await this.sql`DELETE FROM projects WHERE id = ${id}`;
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
  created_at: Date;
};

class PgSnapshotRepo implements SnapshotRepo {
  constructor(private readonly sql: Sql) {}

  async insert(input: {
    projectId: ProjectId;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
  }): Promise<SnapshotId> {
    const id = uuidv7();
    await this.sql`
      INSERT INTO snapshots (id, project_id, ir_module, sidecar_bundle, schema_bundle, created_at)
      VALUES (
        ${id},
        ${input.projectId},
        ${this.sql.json(asJson(input.irModule))},
        ${input.sidecarBundle === null
          ? null
          : this.sql.json(asJson(input.sidecarBundle))},
        ${this.sql.json(asJson(input.schemaBundle))},
        now()
      )
    `;
    return id as SnapshotId;
  }

  async get(id: SnapshotId): Promise<Snapshot | null> {
    const rows = await this.sql<DbSnapshotRow[]>`
      SELECT id, project_id, ir_module, sidecar_bundle, schema_bundle, created_at
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
      createdAt: row.created_at.toISOString(),
    };
  }

  async list(
    filter?: { projectId?: ProjectId } & ListOptions,
  ): Promise<SnapshotSummary[]> {
    const limit = clampLimit(filter?.limit);
    const offset = clampOffset(filter?.offset);
    const rows =
      filter?.projectId !== undefined
        ? await this.sql<
            { id: string; project_id: string; created_at: Date }[]
          >`
            SELECT id, project_id, created_at
            FROM snapshots
            WHERE project_id = ${filter.projectId}
            ORDER BY created_at DESC
            LIMIT ${limit} OFFSET ${offset}
          `
        : await this.sql<
            { id: string; project_id: string; created_at: Date }[]
          >`
            SELECT id, project_id, created_at
            FROM snapshots
            ORDER BY created_at DESC
            LIMIT ${limit} OFFSET ${offset}
          `;
    return rows.map((r) => ({
      id: r.id as SnapshotId,
      projectId: r.project_id as ProjectId,
      createdAt: r.created_at.toISOString(),
    }));
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
    return rows[0]?.id as SnapshotId | undefined ?? null;
  }

  async delete(id: SnapshotId): Promise<boolean> {
    const result = await this.sql`DELETE FROM snapshots WHERE id = ${id}`;
    return result.count > 0;
  }
}

// ─── EngineCheckpoint ──────────────────────────────────────────────────────

class PgEngineCheckpointRepo implements EngineCheckpointRepo {
  constructor(private readonly sql: Sql) {}

  async upsert(
    snapshotId: SnapshotId,
    checkpoint: EngineCheckpoint,
  ): Promise<void> {
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
      typeof checkpoint === "object"
      && !Array.isArray(checkpoint)
      && (checkpoint as { schemaVersion?: unknown }).schemaVersion === undefined
    ) {
      return null;
    }
    return checkpoint;
  }

  async delete(snapshotId: SnapshotId): Promise<void> {
    await this.sql`DELETE FROM engine_checkpoints WHERE snapshot_id = ${snapshotId}`;
  }
}

// ─── Agents ────────────────────────────────────────────────────────────────

type DbAgentRow = {
  id: string;
  delegation_id: string;
  snapshot_id: string;
  qualified_name: string;
  args: Record<string, EncryptedValue>;
  state: AgentState;
  result: EncryptedValue | null;
  error_message: string | null;
  created_at: Date;
  updated_at: Date;
};

function dbToAgentRow(row: DbAgentRow): AgentRow {
  return {
    id: row.id as AgentId,
    delegationId: row.delegation_id as DelegationId,
    snapshotId: row.snapshot_id as SnapshotId,
    qualifiedName: row.qualified_name,
    args: fromStorageJson(row.args),
    state: row.state,
    result:
      row.result === null ? undefined : fromStorageJson(row.result),
    errorMessage: row.error_message === null ? undefined : row.error_message,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

class PgAgentRepo implements AgentRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: AgentRow): Promise<void> {
    await this.sql`
      INSERT INTO agents (
        id, delegation_id, snapshot_id, qualified_name, args, state,
        result, error_message, created_at, updated_at
      ) VALUES (
        ${row.id}, ${row.delegationId}, ${row.snapshotId}, ${row.qualifiedName},
        ${this.sql.json(asJson(row.args))}, ${row.state},
        ${row.result === undefined ? null : this.sql.json(asJson(row.result))},
        ${row.errorMessage ?? null},
        ${row.createdAt}, ${row.updatedAt}
      )
    `;
  }

  async get(id: AgentId): Promise<AgentRow | null> {
    const rows = await this.sql<DbAgentRow[]>`
      SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
      FROM agents WHERE id = ${id}
    `;
    return rows[0] !== undefined ? dbToAgentRow(rows[0]) : null;
  }

  async findByDelegationId(delegationId: DelegationId): Promise<AgentRow | null> {
    const rows = await this.sql<DbAgentRow[]>`
      SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
      FROM agents WHERE delegation_id = ${delegationId}
    `;
    return rows[0] !== undefined ? dbToAgentRow(rows[0]) : null;
  }

  async list(
    filter?: { snapshotId?: SnapshotId; state?: AgentState; afterId?: AgentId } & ListOptions,
  ): Promise<AgentRow[]> {
    const limit = clampLimit(filter?.limit);
    const afterId = filter?.afterId;
    // afterId is keyset pagination; combining it with OFFSET produces
    // an unstable window (each row skipped by OFFSET also shifts the
    // keyset boundary). When afterId is provided, force offset = 0.
    const offset = afterId !== undefined ? 0 : clampOffset(filter?.offset);
    const snapshotId = filter?.snapshotId;
    const state = filter?.state;
    let rows: DbAgentRow[];
    if (snapshotId !== undefined && state !== undefined && afterId !== undefined) {
      rows = await this.sql<DbAgentRow[]>`
        SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
        FROM agents WHERE snapshot_id = ${snapshotId} AND state = ${state} AND id > ${afterId}
        ORDER BY id ASC LIMIT ${limit} OFFSET ${offset}
      `;
    } else if (snapshotId !== undefined && state !== undefined) {
      rows = await this.sql<DbAgentRow[]>`
        SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
        FROM agents WHERE snapshot_id = ${snapshotId} AND state = ${state}
        ORDER BY id ASC LIMIT ${limit} OFFSET ${offset}
      `;
    } else if (snapshotId !== undefined && afterId !== undefined) {
      rows = await this.sql<DbAgentRow[]>`
        SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
        FROM agents WHERE snapshot_id = ${snapshotId} AND id > ${afterId}
        ORDER BY id ASC LIMIT ${limit} OFFSET ${offset}
      `;
    } else if (snapshotId !== undefined) {
      rows = await this.sql<DbAgentRow[]>`
        SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
        FROM agents WHERE snapshot_id = ${snapshotId}
        ORDER BY id ASC LIMIT ${limit} OFFSET ${offset}
      `;
    } else if (afterId !== undefined) {
      rows = await this.sql<DbAgentRow[]>`
        SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
        FROM agents WHERE id > ${afterId}
        ORDER BY id ASC LIMIT ${limit} OFFSET ${offset}
      `;
    } else {
      rows = await this.sql<DbAgentRow[]>`
        SELECT id, delegation_id, snapshot_id, qualified_name, args, state, result, error_message, created_at, updated_at
        FROM agents
        ORDER BY id ASC LIMIT ${limit} OFFSET ${offset}
      `;
    }
    return rows.map(dbToAgentRow);
  }

  async setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
    options?: { expectedState?: AgentState },
  ): Promise<boolean> {
    // The patch is sparse — any subset of (state, result, error_message)
    // may be supplied. We compose the SET clause by chaining tagged-
    // template fragments through reduce. The intermediate ReturnType<Sql>
    // type is awkward but is the documented postgres.js pattern for
    // dynamic SET lists when fragment values must remain parameterised.
    const sets: ReturnType<Sql>[] = [];
    if (patch.state !== undefined) sets.push(this.sql`state = ${patch.state}`);
    if (patch.result !== undefined) {
      sets.push(this.sql`result = ${this.sql.json(asJson(patch.result))}`);
    }
    if (patch.errorMessage !== undefined) {
      sets.push(this.sql`error_message = ${patch.errorMessage}`);
    }
    if (sets.length === 0) return true;
    sets.push(this.sql`updated_at = now()`);
    const setSql = sets.reduce(
      (acc, cur, i) => (i === 0 ? cur : this.sql`${acc}, ${cur}`),
    );
    const result = options?.expectedState !== undefined
      ? await this.sql`UPDATE agents SET ${setSql} WHERE id = ${id} AND state = ${options.expectedState}`
      : await this.sql`UPDATE agents SET ${setSql} WHERE id = ${id}`;
    return result.count > 0;
  }

  async markAllRunningAsError(snapshotId: SnapshotId, message: string): Promise<void> {
    // Clear `result` alongside the state flip — a row that was running
    // may have written a partial result before the engine gave up, and
    // (state='error', result=<partial>) is contradictory to readers.
    await this.sql`
      UPDATE agents
      SET state = 'error',
          error_message = ${message},
          result = NULL,
          updated_at = now()
      WHERE snapshot_id = ${snapshotId} AND state IN ('running', 'cancelling')
    `;
  }

  async listRunningSnapshotIds(): Promise<SnapshotId[]> {
    const rows = await this.sql<{ snapshot_id: string }[]>`
      SELECT DISTINCT snapshot_id FROM agents WHERE state IN ('running', 'cancelling')
    `;
    return rows.map((r) => r.snapshot_id as SnapshotId);
  }
}

// ─── FFI pending tables ────────────────────────────────────────────────────

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

  async setState(
    delegationId: DelegationId,
    state: "running" | "cancelling",
  ): Promise<boolean> {
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

  async listChildrenOf(
    parentDelegationId: DelegationId,
  ): Promise<FfiPendingDelegation[]> {
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

class PgApiPendingEscalationRepo implements ApiPendingEscalationRepo {
  constructor(private readonly sql: Sql) {}

  async insert(row: ApiPendingEscalation): Promise<void> {
    await this.sql`
      INSERT INTO api_pending_escalations (escalation_id, delegation_id, snapshot_id, agent_def_id, args, state, value, created_at)
      VALUES (${row.escalationId}, ${row.delegationId}, ${row.snapshotId},
              ${this.sql.json(asJson(row.agentDefId))},
              ${this.sql.json(asJson(row.args))},
              ${row.state},
              ${row.value === undefined ? null : this.sql.json(asJson(row.value))},
              ${row.createdAt})
    `;
  }

  async get(escalationId: EscalationId): Promise<ApiPendingEscalation | null> {
    const rows = await this.sql<
      {
        escalation_id: string;
        delegation_id: string;
        snapshot_id: string;
        agent_def_id: AgentDefId;
        args: Record<string, EncryptedValue>;
        state: ApiPendingEscalation["state"];
        value: EncryptedValue | null;
        created_at: Date;
      }[]
    >`
      SELECT escalation_id, delegation_id, snapshot_id, agent_def_id, args, state, value, created_at
      FROM api_pending_escalations WHERE escalation_id = ${escalationId}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      escalationId: row.escalation_id as EscalationId,
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      state: row.state,
      value: row.value === null ? undefined : fromStorageJson(row.value),
      createdAt: row.created_at.toISOString(),
    };
  }

  async list(
    filter?: { snapshotId?: SnapshotId; state?: ApiPendingEscalation["state"] }
      & ListOptions,
  ): Promise<ApiPendingEscalation[]> {
    const limit = clampLimit(filter?.limit);
    const offset = clampOffset(filter?.offset);
    const snapshotId = filter?.snapshotId;
    const state = filter?.state;
    let rows: {
      escalation_id: string;
      delegation_id: string;
      snapshot_id: string;
      agent_def_id: AgentDefId;
      args: Record<string, EncryptedValue>;
      state: ApiPendingEscalation["state"];
      value: EncryptedValue | null;
      created_at: Date;
    }[];
    if (snapshotId !== undefined && state !== undefined) {
      rows = await this.sql`
        SELECT escalation_id, delegation_id, snapshot_id, agent_def_id, args, state, value, created_at
        FROM api_pending_escalations
        WHERE snapshot_id = ${snapshotId} AND state = ${state}
        ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}
      `;
    } else if (snapshotId !== undefined) {
      rows = await this.sql`
        SELECT escalation_id, delegation_id, snapshot_id, agent_def_id, args, state, value, created_at
        FROM api_pending_escalations WHERE snapshot_id = ${snapshotId}
        ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}
      `;
    } else if (state !== undefined) {
      rows = await this.sql`
        SELECT escalation_id, delegation_id, snapshot_id, agent_def_id, args, state, value, created_at
        FROM api_pending_escalations WHERE state = ${state}
        ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}
      `;
    } else {
      rows = await this.sql`
        SELECT escalation_id, delegation_id, snapshot_id, agent_def_id, args, state, value, created_at
        FROM api_pending_escalations
        ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}
      `;
    }
    return rows.map((row) => ({
      escalationId: row.escalation_id as EscalationId,
      delegationId: row.delegation_id as DelegationId,
      snapshotId: row.snapshot_id as SnapshotId,
      agentDefId: row.agent_def_id,
      args: fromStorageJson(row.args),
      state: row.state,
      value: row.value === null ? undefined : fromStorageJson(row.value),
      createdAt: row.created_at.toISOString(),
    }));
  }

  async setAnswered(
    escalationId: EscalationId,
    value: EncryptedValue,
  ): Promise<boolean> {
    const result = await this.sql`
      UPDATE api_pending_escalations
      SET state = 'answered', value = ${this.sql.json(asJson(value))}
      WHERE escalation_id = ${escalationId} AND state = 'open'
    `;
    return result.count > 0;
  }

  async setCancelled(escalationId: EscalationId): Promise<boolean> {
    const result = await this.sql`
      UPDATE api_pending_escalations SET state = 'cancelled'
      WHERE escalation_id = ${escalationId} AND state = 'open'
    `;
    return result.count > 0;
  }
}

// ─── Storage facade ────────────────────────────────────────────────────────

export class PostgresStorage implements Storage {
  readonly projects: ProjectRepo;
  readonly snapshots: SnapshotRepo;
  readonly checkpoints: EngineCheckpointRepo;
  readonly agents: AgentRepo;
  readonly ffiDelegations: FfiPendingDelegationRepo;
  readonly ffiEscalations: FfiPendingEscalationRepo;
  readonly apiEscalations: ApiPendingEscalationRepo;

  private constructor(private readonly sql: Sql) {
    this.projects = new PgProjectRepo(sql);
    this.snapshots = new PgSnapshotRepo(sql);
    this.checkpoints = new PgEngineCheckpointRepo(sql);
    this.agents = new PgAgentRepo(sql);
    this.ffiDelegations = new PgFfiPendingDelegationRepo(sql);
    this.ffiEscalations = new PgFfiPendingEscalationRepo(sql);
    this.apiEscalations = new PgApiPendingEscalationRepo(sql);
  }

  static create(databaseUrl: string): PostgresStorage {
    const sql = postgres(databaseUrl, { transform: { undefined: null } });
    return new PostgresStorage(sql);
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
    return runInTx(this.sql, fn) as Promise<T>;
  }

  async withSnapshotLock<T>(
    tx: Storage,
    snapshotId: SnapshotId,
    fn: () => Promise<T>,
  ): Promise<T> {
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
  fn: (tx: Storage) => Promise<T>,
): Promise<T> {
  const begin = (sqlHandle as unknown as { begin: typeof sqlHandle.begin })
    .begin
    .bind(sqlHandle);
  return begin(async (txSql) => {
    const innerSql = txSql as unknown as Sql;
    const txStorage: Storage = {
      projects: new PgProjectRepo(innerSql),
      snapshots: new PgSnapshotRepo(innerSql),
      checkpoints: new PgEngineCheckpointRepo(innerSql),
      agents: new PgAgentRepo(innerSql),
      ffiDelegations: new PgFfiPendingDelegationRepo(innerSql),
      ffiEscalations: new PgFfiPendingEscalationRepo(innerSql),
      apiEscalations: new PgApiPendingEscalationRepo(innerSql),
      withTransaction: (innerFn) => runInTx(innerSql, innerFn),
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
async function acquireSnapshotAdvisoryLock(
  sql: Sql,
  snapshotId: string,
): Promise<void> {
  await sql`SELECT pg_advisory_xact_lock(hashtextextended(${snapshotId}, 0))`;
}
