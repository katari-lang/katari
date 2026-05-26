// Project-scoped run routes.
//
// Mounted at `/project/:projectId/run`. A "run" in operator terms is an
// ApiModule-launched root delegation (= what was previously called an
// "agent"). The audit log lives in `runs_audit` so the row survives the
// live `delegations` entity being deleted on terminal ack — i.e. the
// UI can show "succeeded with result X" or "cancelled (error)" after
// the engine has cleared its in-flight state.

import { Hono } from "hono";
import { valueFromRaw } from "@katari-lang/runtime";
import type { Value } from "@katari-lang/runtime";
import {
  PaginationQuerySchema,
  ProjectIdSchema,
  RunIdSchema,
  RunStateSchema,
  SnapshotIdSchema,
  StartRunSchema,
} from "./middleware/validation.js";
import { runAuditRowToWire } from "../wire/agent-wire.js";
import type { ApiServerOrchestrator } from "../orchestrator.js";
import { z } from "zod";

const RunListQuerySchema = z
  .object({
    snapshotId: SnapshotIdSchema.optional(),
    state: RunStateSchema.optional(),
  })
  .extend(PaginationQuerySchema.shape);

export function buildRunRoutes(
  orchestrator: ApiServerOrchestrator,
  storage: import("../storage/types.js").Storage,
): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const body = StartRunSchema.parse(await c.req.json());
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
        return ctx.api.startRun({
          bus: ctx.bus,
          qualifiedName: body.qualifiedName,
          name: body.name,
          args: argsValue,
        });
      },
    );
    return c.json({ runId: result.runId }, 201);
  });

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const query = RunListQuerySchema.parse(c.req.query());
    const result = await storage.runsAudit.list({
      projectId,
      snapshotId: query.snapshotId,
      state: query.state,
      limit: query.limit,
      offset: query.offset,
      cursor: query.cursor,
    });
    return c.json({
      runs: result.items.map(runAuditRowToWire),
      nextCursor: result.nextCursor,
    });
  });

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
    // Short-circuit terminal states: re-running the orchestrator tick on
    // a finished run would needlessly allocate a tx, spin up the sidecar,
    // and reload engine state. The audit state already reflects the answer.
    if (
      row.state === "cancelled" ||
      row.state === "succeeded" ||
      row.state === "error"
    ) {
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
