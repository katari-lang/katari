import Database from "better-sqlite3";

export interface ModuleRow {
  version: number;
  name: string;
  ktriBinary: Buffer;
  agentNameMap: Record<string, number>;
  schemas: Record<string, unknown>;
  servers: Record<string, string>;
  externalAgents: Record<string, string>;
}

export class Db {
  private db: Database.Database;

  constructor(path: string) {
    this.db = new Database(path);
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS modules (
        version INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        ktri_binary BLOB NOT NULL,
        agent_name_map TEXT NOT NULL,
        schemas TEXT NOT NULL,
        servers TEXT NOT NULL DEFAULT '{}',
        external_agents TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    `);
  }

  saveModule(
    name: string,
    ktriBinary: Buffer,
    agentNameMap: Record<string, number>,
    schemas: Record<string, unknown>,
    servers: Record<string, string> = {},
    externalAgents: Record<string, string> = {}
  ): number {
    const stmt = this.db.prepare(`
      INSERT INTO modules (name, ktri_binary, agent_name_map, schemas, servers, external_agents)
      VALUES (?, ?, ?, ?, ?, ?)
    `);
    const result = stmt.run(
      name,
      ktriBinary,
      JSON.stringify(agentNameMap),
      JSON.stringify(schemas),
      JSON.stringify(servers),
      JSON.stringify(externalAgents)
    );
    return Number(result.lastInsertRowid);
  }

  loadLatestModule(): ModuleRow | null {
    const row = this.db.prepare(
      "SELECT * FROM modules ORDER BY version DESC LIMIT 1"
    ).get() as {
      version: number;
      name: string;
      ktri_binary: Buffer;
      agent_name_map: string;
      schemas: string;
      servers: string;
      external_agents: string;
    } | undefined;

    if (!row) return null;

    return {
      version: row.version,
      name: row.name,
      ktriBinary: row.ktri_binary,
      agentNameMap: JSON.parse(row.agent_name_map),
      schemas: JSON.parse(row.schemas),
      servers: JSON.parse(row.servers),
      externalAgents: JSON.parse(row.external_agents),
    };
  }
}
