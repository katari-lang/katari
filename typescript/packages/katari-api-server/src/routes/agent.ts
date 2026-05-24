// Project-scoped agent routes.
//
// Mounted at `/project/:projectId/agent`. Agents are project-scoped
// entities — `snapshotId` is metadata recording which snapshot was the
// "deploy target" when the agent started, but the listing axis is the
// project. A long-running agent stays visible after newer snapshots
// land, which it wouldn't if we keyed by latest snapshot.

import { Hono } from "hono";
import { valueFromRaw } from "@katari-lang/runtime";
import type { Value } from "@katari-lang/runtime";
import {
  AgentIdSchema,
  AgentStateSchema,
  PaginationQuerySchema,
  ProjectIdSchema,
  SnapshotIdSchema,
  StartAgentSchema,
} from "./middleware/validation.js";
import { agentRowToWire } from "../wire/agent-wire.js";
import type { Orchestrator } from "../orchestrator.js";
import { z } from "zod";

const AgentListQuerySchema = z
  .object({
    snapshotId: SnapshotIdSchema.optional(),
    state: AgentStateSchema.optional(),
  })
  .merge(PaginationQuerySchema);

export function buildAgentRoutes(
  orchestrator: Orchestrator,
  storage: import("../storage/types.js").Storage,
): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const body = StartAgentSchema.parse(await c.req.json());
    const argsValue: Record<string, Value> = {};
    for (const [k, v] of Object.entries(body.args)) {
      argsValue[k] = valueFromRaw(v);
    }
    // tickResolved performs the (projectId, snapshotId?) → SnapshotId
    // resolution INSIDE the transaction so the snapshot can't be
    // deleted between resolve and the tick acquiring its lock.
    const result = await orchestrator.tickResolved(
      { projectId, snapshotId: body.snapshotId },
      async (ctx) => {
        return ctx.api.startAgent({
          bus: ctx.bus,
          qualifiedName: body.qualifiedName,
          args: argsValue,
        });
      },
    );
    return c.json({ agentId: result.agentId }, 201);
  });

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const query = AgentListQuerySchema.parse(c.req.query());
    const rows = await storage.agents.list({
      projectId,
      snapshotId: query.snapshotId,
      state: query.state,
      limit: query.limit,
      offset: query.offset,
    });
    return c.json({ agents: rows.map(agentRowToWire) });
  });

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
    // Short-circuit terminal states: re-running the orchestrator tick
    // on an already-finished agent would needlessly allocate a tx,
    // spin up the sidecar, and reload engine state. The state already
    // reflects the answer.
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
