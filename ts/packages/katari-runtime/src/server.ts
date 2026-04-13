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

interface ExternalAgentEntry {
  agent_def_id: string;
  agent_def_where: string;
}

interface ApplyRequest {
  ir_binary: string; // base64
  agents: Record<string, number>;
  schemas?: Record<string, unknown>;
  servers?: Record<string, string>;
  external_agents?: Record<string, ExternalAgentEntry>;
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
      sendOutgoingMessages(msgs).then(({ spawns, failures }) => {
        for (const r of spawns) {
          runtime.registerRemoteChild(
            r.parentAgentId,
            r.provisionalChildId,
            r.actualAgentId,
            r.actualAgentWhere
          );
        }
        for (const f of failures) {
          // Spawn failed — terminate the parent agent
          console.error(`Spawn failed for parent ${f.parentAgentId}: ${f.error}`);
          runtime.eventQueue.push({
            agentId: f.parentAgentId,
            kind: {
              tag: "TerminateAgent",
              agentId: f.parentAgentId,
              fromAgentId: "system",
              fromAgentWhere: "",
            },
          });
          runtime.runEventLoop();
          const followUp = runtime.drainMessages();
          if (followUp.length > 0) handleMessages(followUp);

          // Update DB status
          db.updateToplevelAgent(f.parentAgentId, "error", f.error as JsonValue);
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
      const externalAgents = body.external_agents
        ? new Map(
            Object.entries(body.external_agents).map(([k, v]) => [parseInt(k, 10), v])
          )
        : undefined;
      const servers = body.servers
        ? new Map(Object.entries(body.servers))
        : undefined;

      runtime.applyModule(module, nameMap, schemas, externalAgents, servers);

      // Save to DB
      await db.saveModule(
        module.name,
        binary,
        body.agents,
        body.schemas ?? {},
        body.external_agents ?? {},
        body.servers ?? {}
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
    const body = (await c.req.json()) as { agent_name: string; args?: Record<string, JsonValue> };

    try {
      const agentId = runtime.runAgent(body.agent_name, (body.args ?? {}) as Record<string, Value>);

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

    if (agent) {
      // Agent is in runtime memory — terminate it
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
    }

    // Agent not in runtime memory — check DB (stale from previous runtime session)
    const row = await db.getToplevelAgent(id);
    if (!row) return c.json({ error: "agent not found" }, 404);

    if (row.status === "running") {
      // Stale "running" entry — mark as stopped
      await db.updateToplevelAgent(id, "stopped", null);
      return c.json({ ok: true, note: "agent was stale (not in runtime memory)" });
    }

    return c.json({ error: `agent already ${row.status}` }, 400);
  });

  app.route("/agents", agentsRouter);

  // ==========================================================================
  // Legacy /run endpoints (deprecated)
  // ==========================================================================

  app.post("/run", async (c) => {
    c.header("X-Deprecated", "Use POST /agents instead");
    const body = (await c.req.json()) as { agent_name: string; args: Record<string, JsonValue> };
    try {
      const agentId = runtime.runAgent(body.agent_name, body.args as Record<string, Value>);
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
