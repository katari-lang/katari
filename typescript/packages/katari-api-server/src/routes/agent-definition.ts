// Agent-definition routes: schema lookup for AI tool calling consumers.
// Project-aware with `latest` fallback.

import { Hono } from "hono";
import {
  ProjectIdSchema,
  SnapshotIdSchema,
} from "./middleware/validation.js";
import {
  AgentDefinitionNotFound,
  SnapshotNotFound,
  type SnapshotService,
} from "../services/snapshot-service.js";
import { z } from "zod";

const ListQuerySchema = z.object({
  projectId: ProjectIdSchema,
  snapshotId: SnapshotIdSchema.optional(),
});

export function buildAgentDefinitionRoutes(snapshots: SnapshotService): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const query = ListQuerySchema.parse(c.req.query());
    const snapshotId = await snapshots.resolve(query);
    const definitions = await snapshots.listAgentDefinitions(snapshotId);
    return c.json({ definitions, snapshotId });
  });

  app.get("/:projectId/latest/:qualifiedName", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const qualifiedName = c.req.param("qualifiedName");
    try {
      const snapshotId = await snapshots.resolve({ projectId });
      const definition = await snapshots.getAgentDefinition(
        snapshotId,
        qualifiedName,
      );
      return c.json({ definition, snapshotId });
    } catch (err) {
      if (
        err instanceof SnapshotNotFound ||
        err instanceof AgentDefinitionNotFound
      ) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:projectId/:snapshotId/:qualifiedName", async (c) => {
    const snapshotId = SnapshotIdSchema.parse(c.req.param("snapshotId"));
    const qualifiedName = c.req.param("qualifiedName");
    try {
      const definition = await snapshots.getAgentDefinition(
        snapshotId,
        qualifiedName,
      );
      return c.json({ definition, snapshotId });
    } catch (err) {
      if (
        err instanceof SnapshotNotFound ||
        err instanceof AgentDefinitionNotFound
      ) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  return app;
}
