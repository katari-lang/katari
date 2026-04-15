import type { JsonValue } from "katari-protocol";
import type { SerializedAgentState } from "./runtime/serialize.js";

// ===========================================================================
// Row types
// ===========================================================================

export interface AgentMetadataEntry {
  name: string;
  block_id: number;
  kind: "internal" | "external";
  alias?: string;
}

export interface RequestMetadataEntry {
  name: string;
  request_id: number;
  kind: "internal" | "external";
  alias?: string;
}

export interface ModuleRow {
  version: number;
  name: string;
  ktriBinary: Uint8Array;
  agents: AgentMetadataEntry[];
  schemas: Record<string, unknown>;
  requests: RequestMetadataEntry[];
  aliasEndpoints: Record<string, string>;
}

export interface AgentRow {
  id: string;
  agentDefId: number;
  state: SerializedAgentState;
  parentAgentId: string | null;
  parentThreadId: number | null;
  isToplevel: boolean;
  agentDefName: string | null;
  input: JsonValue | null;
  status: "running" | "completed" | "error" | "stopped";
  result: JsonValue | null;
  createdAt: string;
  finishedAt: string | null;
}

export interface RefRow {
  id: string;
  kind: "delegation" | "escalation";
  agentId: string;
  threadId: number;
}

// ===========================================================================
// SQL adapter interface — abstracts postgres / neon differences
// ===========================================================================

export interface SqlAdapter {
  query(text: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  /** Number of affected rows from last mutating query */
  lastCount: number;
}

// ===========================================================================
// Db class — driver-agnostic
// ===========================================================================

export class Db {
  private sql: SqlAdapter;

  constructor(adapter: SqlAdapter) {
    this.sql = adapter;
  }

  async initialize(): Promise<void> {
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS modules (
        version SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        ktri_binary BYTEA NOT NULL,
        agent_name_map JSONB NOT NULL DEFAULT '{}',
        schemas JSONB NOT NULL DEFAULT '{}',
        servers JSONB NOT NULL DEFAULT '{}',
        external_agents JSONB NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS agents (
        id TEXT PRIMARY KEY,
        agent_def_id INTEGER NOT NULL,
        state JSONB NOT NULL,
        parent_agent_id TEXT,
        parent_thread_id INTEGER,
        is_toplevel BOOLEAN NOT NULL DEFAULT FALSE,
        agent_def_name TEXT,
        input JSONB,
        status TEXT NOT NULL DEFAULT 'running',
        result JSONB,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        finished_at TIMESTAMPTZ
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS refs (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        thread_id INTEGER NOT NULL
      )
    `);
  }

  // =========================================================================
  // Modules
  // =========================================================================

  async saveModule(
    name: string,
    ktriBinary: Uint8Array,
    agents: unknown,
    schemas: Record<string, unknown>,
    requests: unknown,
    aliasEndpoints: Record<string, string>
  ): Promise<number> {
    const rows = await this.sql.query(
      `INSERT INTO modules (name, ktri_binary, agent_name_map, schemas, external_agents, servers)
       VALUES ($1, $2, $3, $4, $5, $6)
       RETURNING version`,
      [name, ktriBinary, JSON.stringify(agents), JSON.stringify(schemas),
       JSON.stringify(requests), JSON.stringify(aliasEndpoints)]
    );
    return rows[0]!.version as number;
  }

  async loadLatestModule(): Promise<ModuleRow | null> {
    const rows = await this.sql.query(
      `SELECT version, name, ktri_binary, agent_name_map, schemas, external_agents, servers
       FROM modules ORDER BY version DESC LIMIT 1`
    );
    if (rows.length === 0) return null;
    const row = rows[0]!;
    return {
      version: row.version as number,
      name: row.name as string,
      ktriBinary: toUint8Array(row.ktri_binary),
      agents: toJson(row.agent_name_map) as AgentMetadataEntry[],
      schemas: toJson(row.schemas) as Record<string, unknown>,
      requests: (toJson(row.external_agents) as RequestMetadataEntry[]) ?? [],
      aliasEndpoints: (toJson(row.servers) as Record<string, string>) ?? {},
    };
  }

  // =========================================================================
  // Agent state persistence
  // =========================================================================

  async saveAgent(
    id: string,
    agentDefId: number,
    state: SerializedAgentState,
    parentAgentId: string | null,
    parentThreadId: number | null,
    isToplevel: boolean,
    agentDefName: string | null,
    input: JsonValue | null,
  ): Promise<void> {
    await this.sql.query(
      `INSERT INTO agents (id, agent_def_id, state, parent_agent_id, parent_thread_id, is_toplevel, agent_def_name, input)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (id) DO UPDATE SET
         state = EXCLUDED.state,
         parent_agent_id = EXCLUDED.parent_agent_id,
         parent_thread_id = EXCLUDED.parent_thread_id`,
      [id, agentDefId, JSON.stringify(state), parentAgentId, parentThreadId,
       isToplevel, agentDefName, input !== null ? JSON.stringify(input) : null]
    );
  }

  async updateAgentState(id: string, state: SerializedAgentState): Promise<void> {
    await this.sql.query(
      `UPDATE agents SET state = $1 WHERE id = $2`,
      [JSON.stringify(state), id]
    );
  }

  async updateAgentStatus(id: string, status: string, result: JsonValue | null): Promise<void> {
    await this.sql.query(
      `UPDATE agents SET status = $1, result = $2, finished_at = NOW() WHERE id = $3`,
      [status, result !== null ? JSON.stringify(result) : null, id]
    );
  }

  async deleteAgent(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM agents WHERE id = $1`, [id]);
  }

  async loadAgent(id: string): Promise<AgentRow | null> {
    const rows = await this.sql.query(
      `SELECT id, agent_def_id, state, parent_agent_id, parent_thread_id,
              is_toplevel, agent_def_name, input, status, result,
              created_at, finished_at
       FROM agents WHERE id = $1`,
      [id]
    );
    if (rows.length === 0) return null;
    return this.toAgentRow(rows[0]!);
  }

  async loadRunningAgents(): Promise<AgentRow[]> {
    const rows = await this.sql.query(
      `SELECT id, agent_def_id, state, parent_agent_id, parent_thread_id,
              is_toplevel, agent_def_name, input, status, result,
              created_at, finished_at
       FROM agents WHERE status = 'running'`
    );
    return rows.map((r) => this.toAgentRow(r));
  }

  async listToplevelAgents(): Promise<AgentRow[]> {
    const rows = await this.sql.query(
      `SELECT id, agent_def_id, state, parent_agent_id, parent_thread_id,
              is_toplevel, agent_def_name, input, status, result,
              created_at, finished_at
       FROM agents WHERE is_toplevel = TRUE
       ORDER BY created_at DESC`
    );
    return rows.map((r) => this.toAgentRow(r));
  }

  private toAgentRow(r: Record<string, unknown>): AgentRow {
    return {
      id: r.id as string,
      agentDefId: r.agent_def_id as number,
      state: toJson(r.state) as SerializedAgentState,
      parentAgentId: r.parent_agent_id as string | null,
      parentThreadId: r.parent_thread_id as number | null,
      isToplevel: r.is_toplevel as boolean,
      agentDefName: r.agent_def_name as string | null,
      input: r.input != null ? toJson(r.input) as JsonValue : null,
      status: r.status as AgentRow["status"],
      result: r.result != null ? toJson(r.result) as JsonValue : null,
      createdAt: toISOString(r.created_at),
      finishedAt: r.finished_at ? toISOString(r.finished_at) : null,
    };
  }

  // =========================================================================
  // Ref tracking (delegation/escalation maps)
  // =========================================================================

  async saveRef(id: string, kind: "delegation" | "escalation", agentId: string, threadId: number): Promise<void> {
    await this.sql.query(
      `INSERT INTO refs (id, kind, agent_id, thread_id)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (id) DO UPDATE SET agent_id = EXCLUDED.agent_id, thread_id = EXCLUDED.thread_id`,
      [id, kind, agentId, threadId]
    );
  }

  async loadRef(id: string): Promise<RefRow | null> {
    const rows = await this.sql.query(
      `SELECT id, kind, agent_id, thread_id FROM refs WHERE id = $1`,
      [id]
    );
    if (rows.length === 0) return null;
    const r = rows[0]!;
    return {
      id: r.id as string,
      kind: r.kind as RefRow["kind"],
      agentId: r.agent_id as string,
      threadId: r.thread_id as number,
    };
  }

  async deleteRef(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM refs WHERE id = $1`, [id]);
  }

  async loadRefsByAgent(agentId: string): Promise<RefRow[]> {
    const rows = await this.sql.query(
      `SELECT id, kind, agent_id, thread_id FROM refs WHERE agent_id = $1`,
      [agentId]
    );
    return rows.map((r) => ({
      id: r.id as string,
      kind: r.kind as RefRow["kind"],
      agentId: r.agent_id as string,
      threadId: r.thread_id as number,
    }));
  }
}

// ===========================================================================
// Adapter: postgres (Node.js)
// ===========================================================================

export async function createPostgresAdapter(databaseUrl: string): Promise<SqlAdapter> {
  const pg = (await import("postgres")).default as unknown as (url: string) => any;
  const sql = pg(databaseUrl);
  let lastCount = 0;
  return {
    async query(text: string, params?: unknown[]): Promise<Record<string, unknown>[]> {
      // postgres.js uses $1, $2, ... syntax natively
      const result = params?.length
        ? await sql.unsafe(text, params as any[])
        : await sql.unsafe(text);
      lastCount = result.count ?? 0;
      return result as unknown as Record<string, unknown>[];
    },
    get lastCount() { return lastCount; },
    set lastCount(v) { lastCount = v; },
  };
}

// ===========================================================================
// Helpers
// ===========================================================================

function toJson(v: unknown): unknown {
  if (typeof v === "string") return JSON.parse(v);
  return v;
}

function toUint8Array(v: unknown): Uint8Array {
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (typeof v === "string") {
    // Base64 decode
    if (typeof Buffer !== "undefined") {
      return Buffer.from(v, "base64");
    }
    const binary = atob(v);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }
  if (typeof v === "object" && v !== null && "type" in v && (v as any).type === "Buffer") {
    return new Uint8Array((v as any).data);
  }
  return new Uint8Array(0);
}

function toISOString(v: unknown): string {
  if (v instanceof Date) return v.toISOString();
  if (typeof v === "string") return v;
  return String(v);
}
