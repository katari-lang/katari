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
// Request/Response types for /apply and /run
// ===========================================================================

interface ApplyRequest {
  ir_binary: string; // base64
  agents: Record<string, number>;
  schemas?: Record<string, unknown>;
  servers?: Record<string, string>;
  external_agents?: Record<string, string>; // agent_def_id → "server:name"
}

interface ApplyResponse {
  ok: boolean;
  error?: string;
  module_name?: string;
  agents?: { id: number; name: string }[];
  requests?: { id: number; name: string }[];
}

interface RunRequest {
  agent_name: string;
  args: JsonValue[];
}

interface RunResponse {
  ok: boolean;
  agent_id?: string;
  status: string;
  result?: JsonValue;
  error?: string;
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

  // POST /apply
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
      db.saveModule(
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

  // POST /run
  app.post("/run", async (c) => {
    const body = (await c.req.json()) as RunRequest;

    try {
      const agentId = runtime.runAgent(body.agent_name, body.args as Value[]);
      const status = runtime.getAgentStatus(agentId);

      const msgs = runtime.drainMessages();
      handleMessages(msgs);

      const response: RunResponse = {
        ok: true,
        agent_id: agentId,
        status: status?.status ?? "running",
        result: status?.result as JsonValue,
      };
      return c.json(response);
    } catch (e) {
      return c.json(
        {
          ok: false,
          status: "error",
          error: String(e),
        } satisfies RunResponse,
        400
      );
    }
  });

  // GET /run/:agentId
  app.get("/run/:agentId", (c) => {
    const agentId = c.req.param("agentId");
    const status = runtime.getAgentStatus(agentId);

    if (!status) {
      return c.json(
        {
          agent_id: agentId,
          status: "not_found",
          error: "agent not found",
        },
        404
      );
    }

    return c.json({
      agent_id: agentId,
      status: status.status,
      result: status.result as JsonValue,
    });
  });

  // GET /run
  app.get("/run", (c) => {
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

  // Katari Protocol routes
  const katariRouter = buildKatariRouter(
    () => runtime,
    (msgs) => handleMessages(msgs)
  );
  app.route("/katari", katariRouter);

  return app;
}
