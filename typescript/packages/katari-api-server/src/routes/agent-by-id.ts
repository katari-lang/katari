// Flat "by id" single-entity agent routes.
//
// Mounted at `/agent` alongside the project-scoped routes at
// `/project/:projectId/agent`. Agents have globally-unique UUIDs, so
// the CLI (`katari status <id>` / `katari cancel <id>`) doesn't need
// to know which project owns an agent — it just hands the id over.
// The hierarchical routes stay primary for list/create (= where
// project context matters for navigation); these are siblings for
// single-entity lookups.

import { Hono } from "hono";
import { AgentIdSchema } from "./middleware/validation.js";
import { agentRowToWire } from "../wire/agent-wire.js";
import type { Orchestrator } from "../orchestrator.js";
import type { Storage } from "../storage/types.js";

export function buildAgentByIdRoutes(
  orchestrator: Orchestrator,
  storage: Storage,
): Hono {
  const app = new Hono();

  app.get("/:agentId", async (c) => {
    const agentId = AgentIdSchema.parse(c.req.param("agentId"));
    const row = await storage.agents.get(agentId);
    if (row === null) {
      return c.json({ error: `agent ${agentId} not found` }, 404);
    }
    return c.json({ agent: agentRowToWire(row) });
  });

  app.post("/:agentId/cancel", async (c) => {
    const agentId = AgentIdSchema.parse(c.req.param("agentId"));
    const row = await storage.agents.get(agentId);
    if (row === null) {
      return c.json({ error: `agent ${agentId} not found` }, 404);
    }
    if (
      row.state === "cancelled" ||
      row.state === "succeeded" ||
      row.state === "error"
    ) {
      return c.json({ agent: agentRowToWire(row) });
    }
    const refreshed = await orchestrator.tick(row.snapshotId, async (ctx) => {
      const result = await ctx.api.cancelAgent({ bus: ctx.bus, agentId });
      return result.row;
    });
    return c.json({ agent: agentRowToWire(refreshed ?? row) });
  });

  return app;
}
