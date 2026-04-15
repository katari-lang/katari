import type {
  AgentDefinition,
  Agent,
  Delegation,
  Template,
  Capability,
  Escalation,
  AgentRef,
  AgentStatus,
} from "./types.js";
import type { JsonValue } from "./json.js";

// ===========================================================================
// KatariStore — abstract storage interface for protocol resources
// ===========================================================================

export interface KatariStore {
  // Agent Definition
  listAgentDefinitions(): Promise<AgentDefinition[]>;
  getAgentDefinition(id: string): Promise<AgentDefinition | null>;
  getAgentDefinitionByName(name: string): Promise<AgentDefinition | null>;
  createAgentDefinition(def: AgentDefinition): Promise<void>;
  deleteAgentDefinition(id: string): Promise<void>;

  // Agent
  listAgents(): Promise<Agent[]>;
  getAgent(id: string): Promise<Agent | null>;
  createAgent(agent: Agent): Promise<void>;
  updateAgentStatus(id: string, status: AgentStatus): Promise<void>;
  deleteAgent(id: string): Promise<void>;

  // Delegation
  listDelegations(): Promise<Delegation[]>;
  getDelegation(id: string): Promise<Delegation | null>;
  createDelegation(delegation: Delegation): Promise<void>;
  deleteDelegation(id: string): Promise<void>;

  // Template
  listTemplates(): Promise<Template[]>;
  getTemplate(id: string): Promise<Template | null>;
  getTemplateByName(name: string): Promise<Template | null>;
  createTemplate(template: Template): Promise<void>;
  deleteTemplate(id: string): Promise<void>;

  // Capability
  listCapabilities(): Promise<Capability[]>;
  getCapability(id: string): Promise<Capability | null>;
  createCapability(capability: Capability): Promise<void>;
  deleteCapability(id: string): Promise<void>;
  deleteCapabilitiesByAgent(agentRef: AgentRef): Promise<void>;

  // Escalation
  listEscalations(): Promise<Escalation[]>;
  getEscalation(id: string): Promise<Escalation | null>;
  createEscalation(escalation: Escalation): Promise<void>;
  deleteEscalation(id: string): Promise<void>;
}

// ===========================================================================
// InMemoryKatariStore — for testing and simple external servers
// ===========================================================================

export class InMemoryKatariStore implements KatariStore {
  private agentDefinitions = new Map<string, AgentDefinition>();
  private agents = new Map<string, Agent>();
  private delegations = new Map<string, Delegation>();
  private templates = new Map<string, Template>();
  private capabilities = new Map<string, Capability>();
  private escalations = new Map<string, Escalation>();

  // Agent Definition
  async listAgentDefinitions(): Promise<AgentDefinition[]> {
    return Array.from(this.agentDefinitions.values());
  }
  async getAgentDefinition(id: string): Promise<AgentDefinition | null> {
    return this.agentDefinitions.get(id) ?? null;
  }
  async getAgentDefinitionByName(name: string): Promise<AgentDefinition | null> {
    for (const d of this.agentDefinitions.values()) {
      if (d.name === name) return d;
    }
    return null;
  }
  async createAgentDefinition(def: AgentDefinition): Promise<void> {
    this.agentDefinitions.set(def.id, def);
  }
  async deleteAgentDefinition(id: string): Promise<void> {
    this.agentDefinitions.delete(id);
  }

  // Agent
  async listAgents(): Promise<Agent[]> {
    return Array.from(this.agents.values());
  }
  async getAgent(id: string): Promise<Agent | null> {
    return this.agents.get(id) ?? null;
  }
  async createAgent(agent: Agent): Promise<void> {
    this.agents.set(agent.id, agent);
  }
  async updateAgentStatus(id: string, status: AgentStatus): Promise<void> {
    const agent = this.agents.get(id);
    if (agent) agent.status = status;
  }
  async deleteAgent(id: string): Promise<void> {
    this.agents.delete(id);
  }

  // Delegation
  async listDelegations(): Promise<Delegation[]> {
    return Array.from(this.delegations.values());
  }
  async getDelegation(id: string): Promise<Delegation | null> {
    return this.delegations.get(id) ?? null;
  }
  async createDelegation(delegation: Delegation): Promise<void> {
    this.delegations.set(delegation.id, delegation);
  }
  async deleteDelegation(id: string): Promise<void> {
    this.delegations.delete(id);
  }

  // Template
  async listTemplates(): Promise<Template[]> {
    return Array.from(this.templates.values());
  }
  async getTemplate(id: string): Promise<Template | null> {
    return this.templates.get(id) ?? null;
  }
  async getTemplateByName(name: string): Promise<Template | null> {
    for (const t of this.templates.values()) {
      if (t.name === name) return t;
    }
    return null;
  }
  async createTemplate(template: Template): Promise<void> {
    this.templates.set(template.id, template);
  }
  async deleteTemplate(id: string): Promise<void> {
    this.templates.delete(id);
  }

  // Capability
  async listCapabilities(): Promise<Capability[]> {
    return Array.from(this.capabilities.values());
  }
  async getCapability(id: string): Promise<Capability | null> {
    return this.capabilities.get(id) ?? null;
  }
  async createCapability(capability: Capability): Promise<void> {
    this.capabilities.set(capability.id, capability);
  }
  async deleteCapability(id: string): Promise<void> {
    this.capabilities.delete(id);
  }
  async deleteCapabilitiesByAgent(agentRef: AgentRef): Promise<void> {
    for (const [id, cap] of this.capabilities) {
      if (
        cap.agent_ref.id === agentRef.id &&
        cap.agent_ref.endpoint === agentRef.endpoint
      ) {
        this.capabilities.delete(id);
      }
    }
  }

  // Escalation
  async listEscalations(): Promise<Escalation[]> {
    return Array.from(this.escalations.values());
  }
  async getEscalation(id: string): Promise<Escalation | null> {
    return this.escalations.get(id) ?? null;
  }
  async createEscalation(escalation: Escalation): Promise<void> {
    this.escalations.set(escalation.id, escalation);
  }
  async deleteEscalation(id: string): Promise<void> {
    this.escalations.delete(id);
  }
}

// ===========================================================================
// SqlAdapter — abstracts postgres / neon driver differences
// ===========================================================================

export interface SqlAdapter {
  query(text: string, params?: unknown[]): Promise<Record<string, unknown>[]>;
  lastCount: number;
}

// ===========================================================================
// PostgresKatariStore — persistent store backed by PostgreSQL
// ===========================================================================

export class PostgresKatariStore implements KatariStore {
  constructor(private sql: SqlAdapter) {}

  async initialize(): Promise<void> {
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS katari_agent_definitions (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        input_schema JSONB,
        output_schema JSONB,
        template_refs JSONB
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS katari_agents (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        input JSONB,
        definition_ref JSONB NOT NULL,
        delegation_ref JSONB,
        status TEXT NOT NULL DEFAULT 'RUNNING'
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS katari_delegations (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        agent_def_ref JSONB NOT NULL,
        input JSONB,
        capability_refs JSONB NOT NULL DEFAULT '[]'
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS katari_templates (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        input_schema JSONB,
        output_schema JSONB
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS katari_capabilities (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        template_ref JSONB NOT NULL,
        agent_ref JSONB NOT NULL
      )
    `);
    await this.sql.query(`
      CREATE TABLE IF NOT EXISTS katari_escalations (
        id TEXT PRIMARY KEY,
        endpoint TEXT NOT NULL,
        capability_ref JSONB NOT NULL,
        input JSONB
      )
    `);
  }

  // Agent Definition
  async listAgentDefinitions(): Promise<AgentDefinition[]> {
    const rows = await this.sql.query(`SELECT * FROM katari_agent_definitions`);
    return rows.map(rowToAgentDef);
  }
  async getAgentDefinition(id: string): Promise<AgentDefinition | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_agent_definitions WHERE id = $1`,
      [id],
    );
    return rows.length > 0 ? rowToAgentDef(rows[0]!) : null;
  }
  async getAgentDefinitionByName(name: string): Promise<AgentDefinition | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_agent_definitions WHERE name = $1 LIMIT 1`,
      [name],
    );
    return rows.length > 0 ? rowToAgentDef(rows[0]!) : null;
  }
  async createAgentDefinition(def: AgentDefinition): Promise<void> {
    await this.sql.query(
      `INSERT INTO katari_agent_definitions (id, endpoint, name, description, input_schema, output_schema, template_refs)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (id) DO UPDATE SET endpoint=EXCLUDED.endpoint, name=EXCLUDED.name,
         description=EXCLUDED.description, input_schema=EXCLUDED.input_schema,
         output_schema=EXCLUDED.output_schema, template_refs=EXCLUDED.template_refs`,
      [
        def.id,
        def.endpoint,
        def.name,
        def.description ?? null,
        JSON.stringify(def.input_schema),
        JSON.stringify(def.output_schema),
        JSON.stringify(def.template_refs ?? null),
      ],
    );
  }
  async deleteAgentDefinition(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM katari_agent_definitions WHERE id = $1`, [
      id,
    ]);
  }

  // Agent
  async listAgents(): Promise<Agent[]> {
    const rows = await this.sql.query(`SELECT * FROM katari_agents`);
    return rows.map(rowToAgent);
  }
  async getAgent(id: string): Promise<Agent | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_agents WHERE id = $1`,
      [id],
    );
    return rows.length > 0 ? rowToAgent(rows[0]!) : null;
  }
  async createAgent(agent: Agent): Promise<void> {
    await this.sql.query(
      `INSERT INTO katari_agents (id, endpoint, input, definition_ref, delegation_ref, status)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [
        agent.id,
        agent.endpoint,
        JSON.stringify(agent.input),
        JSON.stringify(agent.definition_ref),
        JSON.stringify(agent.delegation_ref),
        agent.status,
      ],
    );
  }
  async updateAgentStatus(id: string, status: AgentStatus): Promise<void> {
    await this.sql.query(`UPDATE katari_agents SET status = $1 WHERE id = $2`, [
      status,
      id,
    ]);
  }
  async deleteAgent(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM katari_agents WHERE id = $1`, [id]);
  }

  // Delegation
  async listDelegations(): Promise<Delegation[]> {
    const rows = await this.sql.query(`SELECT * FROM katari_delegations`);
    return rows.map(rowToDelegation);
  }
  async getDelegation(id: string): Promise<Delegation | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_delegations WHERE id = $1`,
      [id],
    );
    return rows.length > 0 ? rowToDelegation(rows[0]!) : null;
  }
  async createDelegation(delegation: Delegation): Promise<void> {
    await this.sql.query(
      `INSERT INTO katari_delegations (id, endpoint, agent_def_ref, input, capability_refs)
       VALUES ($1, $2, $3, $4, $5)`,
      [
        delegation.id,
        delegation.endpoint,
        JSON.stringify(delegation.agent_def_ref),
        JSON.stringify(delegation.input),
        JSON.stringify(delegation.capability_refs),
      ],
    );
  }
  async deleteDelegation(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM katari_delegations WHERE id = $1`, [id]);
  }

  // Template
  async listTemplates(): Promise<Template[]> {
    const rows = await this.sql.query(`SELECT * FROM katari_templates`);
    return rows.map(rowToTemplate);
  }
  async getTemplate(id: string): Promise<Template | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_templates WHERE id = $1`,
      [id],
    );
    return rows.length > 0 ? rowToTemplate(rows[0]!) : null;
  }
  async getTemplateByName(name: string): Promise<Template | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_templates WHERE name = $1 LIMIT 1`,
      [name],
    );
    return rows.length > 0 ? rowToTemplate(rows[0]!) : null;
  }
  async createTemplate(template: Template): Promise<void> {
    await this.sql.query(
      `INSERT INTO katari_templates (id, endpoint, name, description, input_schema, output_schema)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (id) DO UPDATE SET endpoint=EXCLUDED.endpoint, name=EXCLUDED.name,
         description=EXCLUDED.description, input_schema=EXCLUDED.input_schema,
         output_schema=EXCLUDED.output_schema`,
      [
        template.id,
        template.endpoint,
        template.name,
        template.description ?? null,
        JSON.stringify(template.input_schema),
        JSON.stringify(template.output_schema),
      ],
    );
  }
  async deleteTemplate(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM katari_templates WHERE id = $1`, [id]);
  }

  // Capability
  async listCapabilities(): Promise<Capability[]> {
    const rows = await this.sql.query(`SELECT * FROM katari_capabilities`);
    return rows.map(rowToCapability);
  }
  async getCapability(id: string): Promise<Capability | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_capabilities WHERE id = $1`,
      [id],
    );
    return rows.length > 0 ? rowToCapability(rows[0]!) : null;
  }
  async createCapability(capability: Capability): Promise<void> {
    await this.sql.query(
      `INSERT INTO katari_capabilities (id, endpoint, template_ref, agent_ref)
       VALUES ($1, $2, $3, $4)`,
      [
        capability.id,
        capability.endpoint,
        JSON.stringify(capability.template_ref),
        JSON.stringify(capability.agent_ref),
      ],
    );
  }
  async deleteCapability(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM katari_capabilities WHERE id = $1`, [id]);
  }
  async deleteCapabilitiesByAgent(agentRef: AgentRef): Promise<void> {
    await this.sql.query(
      `DELETE FROM katari_capabilities WHERE agent_ref->>'id' = $1 AND agent_ref->>'endpoint' = $2`,
      [agentRef.id, agentRef.endpoint],
    );
  }

  // Escalation
  async listEscalations(): Promise<Escalation[]> {
    const rows = await this.sql.query(`SELECT * FROM katari_escalations`);
    return rows.map(rowToEscalation);
  }
  async getEscalation(id: string): Promise<Escalation | null> {
    const rows = await this.sql.query(
      `SELECT * FROM katari_escalations WHERE id = $1`,
      [id],
    );
    return rows.length > 0 ? rowToEscalation(rows[0]!) : null;
  }
  async createEscalation(escalation: Escalation): Promise<void> {
    await this.sql.query(
      `INSERT INTO katari_escalations (id, endpoint, capability_ref, input)
       VALUES ($1, $2, $3, $4)`,
      [
        escalation.id,
        escalation.endpoint,
        JSON.stringify(escalation.capability_ref),
        JSON.stringify(escalation.input),
      ],
    );
  }
  async deleteEscalation(id: string): Promise<void> {
    await this.sql.query(`DELETE FROM katari_escalations WHERE id = $1`, [id]);
  }
}

// ===========================================================================
// Row conversion helpers
// ===========================================================================

function toJson(val: unknown): unknown {
  if (typeof val === "string") return JSON.parse(val);
  return val;
}

// ===========================================================================
// createPostgresAdapter — Node.js postgres driver adapter
// ===========================================================================

export async function createPostgresAdapter(
  databaseUrl: string,
): Promise<SqlAdapter> {
  const pg = (await import("postgres")).default as unknown as (
    url: string,
  ) => any;
  const sql = pg(databaseUrl);
  let lastCount = 0;
  return {
    async query(
      text: string,
      params?: unknown[],
    ): Promise<Record<string, unknown>[]> {
      const result = params?.length
        ? await sql.unsafe(text, params as any[])
        : await sql.unsafe(text);
      lastCount = result.count ?? 0;
      return result as unknown as Record<string, unknown>[];
    },
    get lastCount() {
      return lastCount;
    },
    set lastCount(v) {
      lastCount = v;
    },
  };
}

// ===========================================================================
// Row conversion helpers
// ===========================================================================

function rowToAgentDef(row: Record<string, unknown>): AgentDefinition {
  return {
    id: row.id as string,
    endpoint: row.endpoint as string,
    name: row.name as string,
    description: row.description as string | undefined,
    input_schema: toJson(row.input_schema) as JsonValue,
    output_schema: toJson(row.output_schema) as JsonValue,
    template_refs: toJson(
      row.template_refs,
    ) as AgentDefinition["template_refs"],
  };
}

function rowToAgent(row: Record<string, unknown>): Agent {
  return {
    id: row.id as string,
    endpoint: row.endpoint as string,
    input: toJson(row.input) as JsonValue,
    definition_ref: toJson(row.definition_ref) as Agent["definition_ref"],
    delegation_ref: toJson(row.delegation_ref) as Agent["delegation_ref"],
    status: row.status as AgentStatus,
  };
}

function rowToDelegation(row: Record<string, unknown>): Delegation {
  return {
    id: row.id as string,
    endpoint: row.endpoint as string,
    agent_def_ref: toJson(row.agent_def_ref) as Delegation["agent_def_ref"],
    input: toJson(row.input) as JsonValue,
    capability_refs: toJson(
      row.capability_refs,
    ) as Delegation["capability_refs"],
  };
}

function rowToTemplate(row: Record<string, unknown>): Template {
  return {
    id: row.id as string,
    endpoint: row.endpoint as string,
    name: row.name as string,
    description: row.description as string | undefined,
    input_schema: toJson(row.input_schema) as JsonValue,
    output_schema: toJson(row.output_schema) as JsonValue,
  };
}

function rowToCapability(row: Record<string, unknown>): Capability {
  return {
    id: row.id as string,
    endpoint: row.endpoint as string,
    template_ref: toJson(row.template_ref) as Capability["template_ref"],
    agent_ref: toJson(row.agent_ref) as Capability["agent_ref"],
  };
}

function rowToEscalation(row: Record<string, unknown>): Escalation {
  return {
    id: row.id as string,
    endpoint: row.endpoint as string,
    capability_ref: toJson(row.capability_ref) as Escalation["capability_ref"],
    input: toJson(row.input) as JsonValue,
  };
}
