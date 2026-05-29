// Flat "by id" single-entity run routes.
//
// Mounted at `/run` alongside the project-scoped routes at
// `/project/:projectId/run`. Runs (= root delegations) have globally-
// unique UUIDs, so the CLI (`katari status <id>` / `katari cancel <id>`)
// doesn't need to know which project owns a run — it just hands the id
// over. The hierarchical routes stay primary for list / create (= where
// project context matters for navigation); these are siblings for
// single-entity lookups.

import { Hono } from "hono";
import type { ApiServerOrchestrator } from "../orchestrator.js";
import type { Storage } from "../storage/types.js";
import { runAuditRowToWire } from "../wire/agent-wire.js";
import { RunIdSchema } from "./middleware/validation.js";

export function buildRunByIdRoutes(orchestrator: ApiServerOrchestrator, storage: Storage): Hono {
  const app = new Hono();

  app.get("/:runId", async (c) => {
    const runId = RunIdSchema.parse(c.req.param("runId"));
    const row = await storage.runsAudit.get(runId);
    if (row === null) {
      return c.json({ error: `run ${runId} not found` }, 404);
    }
    return c.json({ run: runAuditRowToWire(row) });
  });

  app.post("/:runId/cancel", async (c) => {
    const runId = RunIdSchema.parse(c.req.param("runId"));
    const row = await storage.runsAudit.get(runId);
    if (row === null) {
      return c.json({ error: `run ${runId} not found` }, 404);
    }
    if (row.state === "cancelled" || row.state === "succeeded" || row.state === "error") {
      return c.json({ run: runAuditRowToWire(row) });
    }
    const refreshed = await orchestrator.tick(row.snapshotId, async (ctx) => {
      const result = await ctx.api.cancelRun({ bus: ctx.bus, runId });
      return result.row;
    });
    return c.json({ run: runAuditRowToWire(refreshed ?? row) });
  });

  return app;
}
