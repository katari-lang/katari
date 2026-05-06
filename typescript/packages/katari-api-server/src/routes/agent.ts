// Agent routes: start, list, get, cancel.

import { Hono } from "hono";
import type { Value } from "katari-runtime";
import {
  AgentNotFound,
  type AgentService,
} from "../services/agent-service.js";
import { MachineNotFound } from "../registry.js";
import type { AgentId, VersionId } from "../storage/types.js";

export function buildAgentRoutes(agents: AgentService): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const body = (await c.req.json()) as {
      versionId?: string;
      qualifiedName?: string;
      args?: Record<string, Value>;
    };
    if (
      body.versionId === undefined ||
      body.qualifiedName === undefined ||
      body.args === undefined
    ) {
      return c.json(
        { error: "versionId, qualifiedName, args are required" },
        400,
      );
    }
    try {
      const { agentId } = await agents.startAgent({
        versionId: body.versionId as VersionId,
        qualifiedName: body.qualifiedName,
        args: body.args,
      });
      return c.json({ agentId }, 201);
    } catch (err) {
      if (err instanceof MachineNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/", async (c) => {
    const versionId = c.req.query("versionId") as VersionId | undefined;
    const rows = await agents.listAgents(
      versionId !== undefined ? { versionId } : undefined,
    );
    return c.json({ agents: rows });
  });

  app.get("/:id", async (c) => {
    const agentId = c.req.param("id") as AgentId;
    try {
      const row = await agents.getAgent(agentId);
      return c.json(row);
    } catch (err) {
      if (err instanceof AgentNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.post("/:id/cancel", async (c) => {
    const agentId = c.req.param("id") as AgentId;
    try {
      const row = await agents.cancelAgent(agentId);
      return c.json(row);
    } catch (err) {
      if (err instanceof AgentNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  return app;
}
