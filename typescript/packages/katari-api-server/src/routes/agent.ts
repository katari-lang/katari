// Agent routes: start, list, get, cancel.
//
// All input goes through Zod schemas; validation failures are caught by
// the top-level `app.onError` in routes/app.ts and rendered as 400 with
// structured `issues`. Route handlers therefore never see a malformed
// payload.

import { Hono } from "hono";
import type { Value } from "katari-runtime";
import {
  AgentNotFound,
  EntryNotFoundError,
  type AgentService,
} from "../services/agent-service.js";
import { MachineNotFound } from "../registry.js";
import {
  AgentIdSchema,
  PaginationQuerySchema,
  StartAgentSchema,
  VersionIdSchema,
} from "./middleware/validation.js";

export function buildAgentRoutes(agents: AgentService): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const body = StartAgentSchema.parse(await c.req.json());
    try {
      const { agentId } = await agents.startAgent({
        versionId: body.versionId,
        qualifiedName: body.qualifiedName,
        // Zod's structural ValueSchema produces `unknown`-typed leaves; the
        // runtime treats `Value` opaquely until it reaches a prim, so this
        // cast carries no extra risk over the previous `as Value` shape.
        args: body.args as Record<string, Value>,
      });
      return c.json({ agentId }, 201);
    } catch (err) {
      if (err instanceof EntryNotFoundError) {
        return c.json({ error: err.message }, 400);
      }
      if (err instanceof MachineNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/", async (c) => {
    const queryVersionId = c.req.query("versionId");
    const versionId =
      queryVersionId !== undefined
        ? VersionIdSchema.parse(queryVersionId)
        : undefined;
    const { limit, offset } = PaginationQuerySchema.parse(c.req.query());
    const rows = await agents.listAgents({ versionId, limit, offset });
    return c.json({ agents: rows });
  });

  app.get("/:id", async (c) => {
    const agentId = AgentIdSchema.parse(c.req.param("id"));
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
    const agentId = AgentIdSchema.parse(c.req.param("id"));
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
