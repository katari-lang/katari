import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { buildKatariRouter, sendOutgoingMessages } from "katari-protocol";
import type { OutgoingMessage, JsonValue } from "katari-protocol";
import type { Value } from "./value.js";
import { Runtime } from "./runtime/index.js";
import { decodeModule } from "./ir.js";
import { Db } from "./db.js";

// ===========================================================================
// Request/Response types
// ===========================================================================

interface ApplyRequest {
  ir_binary: string; // base64
  agents: Record<string, number>;
  schemas?: Record<string, unknown>;
  servers?: Record<string, string>;
  external_agents?: Record<string, string>;
}

interface ApplyResponse {
  ok: boolean;
  error?: string;
  module_name?: string;
  agents?: { id: number; name: string }[];
  requests?: { id: number; name: string }[];
}

// ===========================================================================
// Build server app
// ===========================================================================

export function buildApp(runtime: Runtime, db: Db): Hono {
  const app = new Hono();
  app.use("*", cors());
  app.use("*", logger());

  const handleMessages = (msgs: OutgoingMessage[]) => {
    if (msgs.length > 0) {
      sendOutgoingMessages(msgs).then((spawnResults) => {
        for (const r of spawnResults) {
          runtime.registerRemoteChild(
            r.parentAgentId,
            r.provisionalChildId,
            r.actualAgentId,
            r.actualAgentWhere
          );
        }
      });
    }
  };

  // ==========================================================================
  // POST /apply
  // ==========================================================================

  app.post("/apply", async (c) => {
    const body = (await c.req.json()) as ApplyRequest;

    try {
      const binary = Buffer.from(body.ir_binary, "base64");
      const module = decodeModule(binary);

      const nameMap = new Map(Object.entries(body.agents));
      const schemas = new Map(Object.entries(body.schemas ?? {})) as Map<string, JsonValue>;
      const servers = body.servers ? new Map(Object.entries(body.servers)) : undefined;
      const externalAgents = body.external_agents
        ? new Map(
            Object.entries(body.external_agents).map(([k, v]) => [parseInt(k, 10), v])
          )
        : undefined;

      runtime.applyModule(module, nameMap, schemas, servers, externalAgents);

      // Save to DB
      await db.saveModule(
        module.name,
        binary,
        body.agents,
        body.schemas ?? {},
        body.servers ?? {},
        body.external_agents ?? {}
      );

      const response: ApplyResponse = {
        ok: true,
        module_name: module.name,
        agents: module.agents.map((a) => ({ id: a.id, name: a.name })),
        requests: module.requests.map((r) => ({ id: r.id, name: r.name })),
      };
      return c.json(response);
    } catch (e) {
      return c.json(
        { ok: false, error: String(e) } satisfies ApplyResponse,
        400
      );
    }
  });

  // ==========================================================================
  // GET /schema/agents — agent defs with schemas (for CLI run selection)
  // ==========================================================================

  app.get("/schema/agents", (c) => {
    const module = runtime.module;
    if (!module) return c.json({ agents: [] });

    const agents = module.agents.map((a) => ({
      id: a.id,
      name: a.name,
      schema: runtime.schemas.get(a.name) ?? null,
    }));
    return c.json({ agents });
  });

  // ==========================================================================
  // /agents — toplevel agent management (sub-router to avoid Hono type depth)
  // ==========================================================================

  const agentsRouter = new Hono();

  // GET /agents
  agentsRouter.get("/", async (c) => {
    const rows = await db.listToplevelAgents();
    return c.json({ agents: rows });
  });

  // POST /agents
  agentsRouter.post("/", async (c) => {
    const body = (await c.req.json()) as { agent_name: string; args?: JsonValue[] };

    try {
      const agentId = runtime.runAgent(body.agent_name, (body.args ?? []) as Value[]);

      const agentDefId = runtime.agentNameMap.get(body.agent_name);
      await db.saveToplevelAgent(
        agentId,
        agentDefId ?? 0,
        body.agent_name,
        body.args ?? null
      );

      const msgs = runtime.drainMessages();
      handleMessages(msgs);

      const status = runtime.getAgentStatus(agentId);
      return c.json({
        ok: true,
        agent_id: agentId,
        status: status?.status ?? "running",
        result: (status?.result as JsonValue) ?? null,
      });
    } catch (e) {
      return c.json({ ok: false, error: String(e) }, 400);
    }
  });

  // GET /agents/:id
  // @ts-expect-error Hono deep type instantiation with /:id + /:id/stop
  agentsRouter.get("/:id", async (c) => {
    const id = c.req.param("id") as string;

    const memStatus = runtime.getAgentStatus(id);
    if (memStatus) {
      return c.json({
        id,
        status: memStatus.status,
        result: (memStatus.result as JsonValue) ?? null,
      });
    }

    const row = await db.getToplevelAgent(id);
    if (!row) return c.json({ error: "not found" }, 404);
    return c.json(row);
  });

  // POST /agents/:id/stop
  agentsRouter.post("/:id/stop", async (c) => {
    const id = c.req.param("id");
    const agent = runtime.agents.get(id);
    if (!agent) return c.json({ error: "agent not running" }, 404);

    runtime.eventQueue.push({
      agentId: id,
      kind: {
        tag: "TerminateAgent",
        agentId: id,
        fromAgentId: "cli",
        fromAgentWhere: "",
      },
    });
    runtime.runEventLoop();
    const msgs = runtime.drainMessages();
    handleMessages(msgs);

    await db.updateToplevelAgent(id, "stopped", null);
    return c.json({ ok: true });
  });

  app.route("/agents", agentsRouter);

  // ==========================================================================
  // Legacy /run endpoints (deprecated)
  // ==========================================================================

  app.post("/run", async (c) => {
    c.header("X-Deprecated", "Use POST /agents instead");
    const body = (await c.req.json()) as { agent_name: string; args: JsonValue[] };
    try {
      const agentId = runtime.runAgent(body.agent_name, body.args as Value[]);
      const status = runtime.getAgentStatus(agentId);
      const msgs = runtime.drainMessages();
      handleMessages(msgs);
      return c.json({
        ok: true,
        agent_id: agentId,
        status: status?.status ?? "running",
        result: status?.result as JsonValue,
      });
    } catch (e) {
      return c.json({ ok: false, status: "error", error: String(e) }, 400);
    }
  });

  app.get("/run/:agentId", (c) => {
    c.header("X-Deprecated", "Use GET /agents/:id instead");
    const agentId = c.req.param("agentId");
    const status = runtime.getAgentStatus(agentId);
    if (!status) return c.json({ agent_id: agentId, status: "not_found", error: "agent not found" }, 404);
    return c.json({ agent_id: agentId, status: status.status, result: status.result as JsonValue });
  });

  app.get("/run", (c) => {
    c.header("X-Deprecated", "Use GET /agents and GET /schema/agents instead");
    const module = runtime.module;
    return c.json({
      agent_defs: module?.agents.map((a) => ({ id: a.id, name: a.name })) ?? [],
      requests: module?.requests.map((r) => ({ id: r.id, name: r.name })) ?? [],
      running_agents: Array.from(runtime.agents.entries()).map(([id, a]) => ({
        agent_id: id,
        agent_def_id: a.agentDefId,
        status: runtime.getAgentStatus(id)?.status ?? "unknown",
      })),
    });
  });

  // ==========================================================================
  // Katari Protocol routes
  // ==========================================================================

  const katariRouter = buildKatariRouter(
    () => runtime,
    (msgs) => handleMessages(msgs)
  );
  app.route("/katari", katariRouter);

  return app;
}
