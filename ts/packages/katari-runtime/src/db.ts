import postgres from "postgres";
import type { JsonValue } from "katari-protocol";

// ===========================================================================
// Row types
// ===========================================================================

export interface ModuleRow {
  version: number;
  name: string;
  ktriBinary: Buffer;
  agentNameMap: Record<string, number>;
  schemas: Record<string, unknown>;
  servers: Record<string, string>;
  externalAgents: Record<string, string>;
}

export interface ToplevelAgentRow {
  id: string;
  agentDefId: number;
  agentDefName: string;
  input: JsonValue | null;
  status: "running" | "completed" | "error" | "stopped";
  result: JsonValue | null;
  startedAt: string;
  finishedAt: string | null;
}

// ===========================================================================
// Db class
// ===========================================================================

export class Db {
  private sql: postgres.Sql;

  constructor(databaseUrl: string) {
    this.sql = postgres(databaseUrl);
  }

  async initialize(): Promise<void> {
    await this.sql`
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
    `;
    await this.sql`
      CREATE TABLE IF NOT EXISTS toplevel_agents (
        id TEXT PRIMARY KEY,
        agent_def_id INTEGER NOT NULL,
        agent_def_name TEXT NOT NULL,
        input JSONB,
        status TEXT NOT NULL DEFAULT 'running',
        result JSONB,
        started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        finished_at TIMESTAMPTZ
      )
    `;
  }

  // =========================================================================
  // Modules
  // =========================================================================

  async saveModule(
    name: string,
    ktriBinary: Buffer,
    agentNameMap: Record<string, number>,
    schemas: Record<string, unknown>,
    servers: Record<string, string> = {},
    externalAgents: Record<string, string> = {}
  ): Promise<number> {
    const [row] = await this.sql`
      INSERT INTO modules (name, ktri_binary, agent_name_map, schemas, servers, external_agents)
      VALUES (
        ${name},
        ${ktriBinary},
        ${this.sql.json(agentNameMap as Record<string, number>)},
        ${this.sql.json(schemas as unknown as postgres.JSONValue)},
        ${this.sql.json(servers as Record<string, string>)},
        ${this.sql.json(externalAgents as Record<string, string>)}
      )
      RETURNING version
    `;
    return row!.version as number;
  }

  async loadLatestModule(): Promise<ModuleRow | null> {
    const rows = await this.sql`
      SELECT version, name, ktri_binary, agent_name_map, schemas, servers, external_agents
      FROM modules
      ORDER BY version DESC
      LIMIT 1
    `;

    if (rows.length === 0) return null;

    const row = rows[0]!;
    return {
      version: row.version as number,
      name: row.name as string,
      ktriBinary: row.ktri_binary as Buffer,
      agentNameMap: row.agent_name_map as Record<string, number>,
      schemas: row.schemas as Record<string, unknown>,
      servers: row.servers as Record<string, string>,
      externalAgents: row.external_agents as Record<string, string>,
    };
  }

  // =========================================================================
  // Toplevel agents
  // =========================================================================

  async saveToplevelAgent(
    id: string,
    agentDefId: number,
    agentDefName: string,
    input: JsonValue | null
  ): Promise<void> {
    await this.sql`
      INSERT INTO toplevel_agents (id, agent_def_id, agent_def_name, input)
      VALUES (${id}, ${agentDefId}, ${agentDefName}, ${this.sql.json(input)})
    `;
  }

  async updateToplevelAgent(
    id: string,
    status: string,
    result: JsonValue | null
  ): Promise<void> {
    await this.sql`
      UPDATE toplevel_agents
      SET status = ${status},
          result = ${this.sql.json(result)},
          finished_at = NOW()
      WHERE id = ${id}
    `;
  }

  async listToplevelAgents(): Promise<ToplevelAgentRow[]> {
    const rows = await this.sql`
      SELECT id, agent_def_id, agent_def_name, input, status, result, started_at, finished_at
      FROM toplevel_agents
      ORDER BY started_at DESC
    `;
    return rows.map((r) => ({
      id: r.id as string,
      agentDefId: r.agent_def_id as number,
      agentDefName: r.agent_def_name as string,
      input: r.input as JsonValue | null,
      status: r.status as ToplevelAgentRow["status"],
      result: r.result as JsonValue | null,
      startedAt: (r.started_at as Date).toISOString(),
      finishedAt: r.finished_at ? (r.finished_at as Date).toISOString() : null,
    }));
  }

  async getToplevelAgent(id: string): Promise<ToplevelAgentRow | null> {
    const rows = await this.sql`
      SELECT id, agent_def_id, agent_def_name, input, status, result, started_at, finished_at
      FROM toplevel_agents
      WHERE id = ${id}
    `;
    if (rows.length === 0) return null;
    const r = rows[0]!;
    return {
      id: r.id as string,
      agentDefId: r.agent_def_id as number,
      agentDefName: r.agent_def_name as string,
      input: r.input as JsonValue | null,
      status: r.status as ToplevelAgentRow["status"],
      result: r.result as JsonValue | null,
      startedAt: (r.started_at as Date).toISOString(),
      finishedAt: r.finished_at ? (r.finished_at as Date).toISOString() : null,
    };
  }
}
