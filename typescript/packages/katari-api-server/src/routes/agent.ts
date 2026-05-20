// Agent routes: start / list / get / cancel.
//
// Thin shim that translates HTTP into orchestrator ticks. The actual
// state changes happen inside `ApiModule` methods invoked through
// `orchestrator.tick(...)`.

import { Hono } from "hono";
import { valueFromRaw } from "@katari-lang/runtime";
import type { Value } from "@katari-lang/runtime";
import {
  AgentIdSchema,
  PaginationQuerySchema,
  ProjectIdSchema,
  SnapshotIdSchema,
  StartAgentSchema,
} from "./middleware/validation.js";
import { agentRowToWire } from "../wire/agent-wire.js";
import type { Orchestrator } from "../orchestrator.js";
import type { SnapshotService } from "../services/snapshot-service.js";
import { z } from "zod";

const AgentListQuerySchema = z
  .object({
    projectId: ProjectIdSchema.optional(),
    snapshotId: SnapshotIdSchema.optional(),
  })
  .merge(PaginationQuerySchema);

export function buildAgentRoutes(
  orchestrator: Orchestrator,
  snapshots: SnapshotService,
  storage: import("../storage/types.js").Storage,
): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const body = StartAgentSchema.parse(await c.req.json());
    const snapshotId = await snapshots.resolve({
      projectId: body.projectId,
      snapshotId: body.snapshotId,
    });
    const argsValue: Record<string, Value> = {};
    for (const [k, v] of Object.entries(body.args)) {
      argsValue[k] = valueFromRaw(v);
    }
    const result = await orchestrator.tick(snapshotId, async (ctx) => {
      return ctx.api.startAgent({
        bus: ctx.bus,
        qualifiedName: body.qualifiedName,
        args: argsValue,
      });
    });
    return c.json({ agentId: result.agentId }, 201);
  });

  app.get("/", async (c) => {
    const query = AgentListQuerySchema.parse(c.req.query());
    let snapshotId = query.snapshotId;
    if (snapshotId === undefined && query.projectId !== undefined) {
      const latest = await storage.snapshots.latest(query.projectId);
      snapshotId = latest ?? undefined;
    }
    const rows = await storage.agents.list({
      snapshotId,
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
    const refreshed = await orchestrator.tick(row.snapshotId, async (ctx) => {
      const result = await ctx.api.cancelAgent({ bus: ctx.bus, agentId });
      return result.row;
    });
    return c.json({ agent: agentRowToWire(refreshed ?? row) });
  });

  return app;
}
