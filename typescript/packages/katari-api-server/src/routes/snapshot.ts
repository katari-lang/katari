// Snapshot routes: upload / list / get / latest / schema. All scoped to
// a project (= mounted under `/project/:projectId/snapshot`).

import { Hono } from "hono";
import type { IRModule, SchemaBundle } from "@katari-lang/runtime";
import {
  PaginationQuerySchema,
  ProjectIdSchema,
  SnapshotIdSchema,
  UploadSnapshotSchema,
} from "./middleware/validation.js";
import {
  NoSnapshotForProject,
  SnapshotNotFound,
  type SnapshotService,
} from "../services/snapshot-service.js";
import { buildAgentRoutes } from "./agent.js";

export function buildSnapshotRoutes(snapshots: SnapshotService): Hono {
  const app = new Hono();

  // Mount nested agent router FIRST so longer paths like
  // `/:snapshotId/agent` win over the shorter `/:snapshotId`
  // catch-all below. Hono matches in registration order.
  app.route("/:snapshotId/agent", buildAgentRoutes(snapshots));

  app.post("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const body = UploadSnapshotSchema.parse(await c.req.json());
    const { snapshotId } = await snapshots.upload({
      projectId,
      irModule: body.irModule as IRModule,
      sidecarBundle: body.sidecarBundle ?? null,
      schemaBundle: body.schemaBundle as SchemaBundle,
    });
    return c.json({ snapshotId }, 201);
  });

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const query = PaginationQuerySchema.parse(c.req.query());
    const list = await snapshots.list({ projectId, ...query });
    return c.json({ snapshots: list });
  });

  app.get("/latest", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    try {
      const snapshotId = await snapshots.resolve({ projectId });
      const snapshot = await snapshots.get(snapshotId);
      return c.json({ snapshot });
    } catch (err) {
      if (
        err instanceof NoSnapshotForProject ||
        err instanceof SnapshotNotFound
      ) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:snapshotId", async (c) => {
    const snapshotId = SnapshotIdSchema.parse(c.req.param("snapshotId"));
    try {
      const snapshot = await snapshots.get(snapshotId);
      return c.json({ snapshot });
    } catch (err) {
      if (err instanceof SnapshotNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:snapshotId/schema", async (c) => {
    const snapshotId = SnapshotIdSchema.parse(c.req.param("snapshotId"));
    try {
      const snapshot = await snapshots.get(snapshotId);
      return c.json({ schemaBundle: snapshot.schemaBundle });
    } catch (err) {
      if (err instanceof SnapshotNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  return app;
}
