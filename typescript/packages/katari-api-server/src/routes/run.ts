// Project-scoped run routes.
//
// Mounted at `/project/:projectId/run`. A "run" in operator terms is an
// ApiModule-launched root delegation (= what was previously called an
// "agent"). The audit log lives in `runs_audit` so the row survives the
// live `delegations` entity being deleted on terminal ack — i.e. the
// UI can show "succeeded with result X" or "cancelled (error)" after
// the engine has cleared its in-flight state.

import type { Value } from "@katari-lang/runtime";
import { valueFromRaw } from "@katari-lang/runtime";
import { Hono } from "hono";
import { z } from "zod";
import type { ApiServerActorHost } from "../actor-host.js";
import { runRowToWire } from "../wire/agent-wire.js";
import {
  PaginationQuerySchema,
  ProjectIdSchema,
  RunIdSchema,
  RunStateSchema,
  SnapshotIdSchema,
  StartRunSchema,
} from "./middleware/validation.js";

const RunListQuerySchema = z
  .object({
    snapshotId: SnapshotIdSchema.optional(),
    state: RunStateSchema.optional(),
  })
  .extend(PaginationQuerySchema.shape);

export function buildRunRoutes(
  host: ApiServerActorHost,
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
    // startRun resolves (projectId, snapshotId?) → SnapshotId inside its own
    // tx, so the snapshot can't be deleted between resolve and the insert.
    const result = await host.runForProject(projectId, ({ bus, modules }) =>
      modules.api.startRun({
        bus,
        snapshotId: body.snapshotId,
        qualifiedName: body.qualifiedName,
        name: body.name,
        args: argsValue,
      }),
    );
    return c.json({ runId: result.runId }, 201);
  });

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const query = RunListQuerySchema.parse(c.req.query());
    const result = await storage.runs.list({
      projectId,
      snapshotId: query.snapshotId,
      state: query.state,
      limit: query.limit,
      offset: query.offset,
      cursor: query.cursor,
    });
    return c.json({
      runs: result.items.map(runRowToWire),
      nextCursor: result.nextCursor,
    });
  });

  app.get("/:runId", async (c) => {
    const runId = RunIdSchema.parse(c.req.param("runId"));
    const row = await storage.runs.get(runId);
    if (row === null) {
      return c.json({ error: `run ${runId} not found` }, 404);
    }
    return c.json({ run: runRowToWire(row) });
  });

  app.post("/:runId/cancel", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const runId = RunIdSchema.parse(c.req.param("runId"));
    const row = await storage.runs.get(runId);
    if (row === null) {
      return c.json({ error: `run ${runId} not found` }, 404);
    }
    // Short-circuit terminal states: re-running a quantum on a finished run
    // would needlessly reload engine state. The Run record already has the answer.
    if (row.state === "done" || row.state === "error") {
      return c.json({ run: runRowToWire(row) });
    }
    const refreshed = await host.runForProject(projectId, async ({ bus, modules }) => {
      const result = await modules.api.cancelRun({ bus, runId });
      return result.row;
    });
    return c.json({ run: runRowToWire(refreshed ?? row) });
  });

  return app;
}
