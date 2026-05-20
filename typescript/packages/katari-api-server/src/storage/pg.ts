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
  EngineCheckpoint,
  EscalationId,
  IRModule,
  SchemaBundle,
  Value,
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
 * Helper for the `postgres` driver's `sql.json(...)` argument: the driver
 * types it as a domain-specific `JSONValue` that doesn't intersect with
 * our app's data shapes (recursive Value / IRModule), so direct passing
 * fails type-check. We funnel every json-serializable parameter through
 * here.
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
    const rows = await this.sql<{ id: string }[]>`
      SELECT id FROM snapshots
      WHERE project_id = ${projectId}
      ORDER BY created_at DESC
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
    return rows[0]?.checkpoint ?? null;
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
  args: Record<string, Value>;
  state: AgentState;
  result: Value | null;
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
    args: row.args,
    state: row.state,
    result: row.result === null ? undefined : row.result,
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
    const offset = clampOffset(filter?.offset);
    const afterId = filter?.afterId;
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
    await this.sql`
      UPDATE agents
      SET state = 'error', error_message = ${message}, updated_at = now()
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
        args: Record<string, Value>;
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
      args: row.args,
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
        args: Record<string, Value>;
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
      args: row.args,
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
        args: Record<string, Value>;
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
      args: row.args,
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
        args: Record<string, Value>;
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
      args: row.args,
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
        args: Record<string, Value>;
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
      args: row.args,
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
        args: Record<string, Value>;
        state: ApiPendingEscalation["state"];
        value: Value | null;
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
      args: row.args,
      state: row.state,
      value: row.value === null ? undefined : row.value,
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
      args: Record<string, Value>;
      state: ApiPendingEscalation["state"];
      value: Value | null;
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
      args: row.args,
      state: row.state,
      value: row.value === null ? undefined : row.value,
      createdAt: row.created_at.toISOString(),
    }));
  }

  async setAnswered(
    escalationId: EscalationId,
    value: Value,
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

  async withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T> {
    return runInTx(this.sql, fn) as Promise<T>;
  }

  async withSnapshotLock<T>(
    tx: Storage,
    snapshotId: SnapshotId,
    fn: () => Promise<T>,
  ): Promise<T> {
    // Acquire row lock on the corresponding engine_checkpoints row. If it
    // doesn't exist yet, insert a placeholder so subsequent SELECT FOR
    // UPDATE has something to lock. The placeholder gets overwritten by
    // the eventual `checkpoints.upsert(...)`.
    const inner = (tx as PostgresStorage).sql;
    await inner`
      INSERT INTO engine_checkpoints (snapshot_id, checkpoint, updated_at)
      VALUES (${snapshotId}, ${inner.json(asJson({}))}, now())
      ON CONFLICT (snapshot_id) DO NOTHING
    `;
    await inner`SELECT 1 FROM engine_checkpoints WHERE snapshot_id = ${snapshotId} FOR UPDATE`;
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
        await innerSql`
          INSERT INTO engine_checkpoints (snapshot_id, checkpoint, updated_at)
          VALUES (${snapshotId}, ${innerSql.json(asJson({}))}, now())
          ON CONFLICT (snapshot_id) DO NOTHING
        `;
        await innerSql`SELECT 1 FROM engine_checkpoints WHERE snapshot_id = ${snapshotId} FOR UPDATE`;
        return body();
      },
    };
    return fn(txStorage);
  }) as Promise<T>;
}
