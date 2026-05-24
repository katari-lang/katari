// Snapshot-scoped agent-definition routes.
//
// Mounted at `/project/:projectId/snapshot/:snapshotId/agent-definition`.
// Definitions live inside a specific snapshot's schema bundle, so the
// URL hierarchy mirrors the data model. The path segment `:snapshotId`
// accepts the literal string `"latest"` as an alias that resolves to the
// project's most-recent snapshot — kept for ergonomic admin / IDE
// lookups that don't want to make two requests.

import { Hono } from "hono";
import {
  ProjectIdSchema,
  SnapshotIdSchema,
} from "./middleware/validation.js";
import {
  AgentDefinitionNotFound,
  NoSnapshotForProject,
  SnapshotNotFound,
  type SnapshotService,
} from "../services/snapshot-service.js";
import type { ProjectId, SnapshotId } from "../storage/types.js";
import { z } from "zod";

// QualifiedName wire format: dotted module path + leaf identifier
// (e.g. "tools.http.fetch"). We accept letters, digits, underscores,
// and dots only — anything else (including empty) is rejected at the
// route boundary before it reaches storage.
const QualifiedNameSchema = z
  .string()
  .min(1)
  .max(256)
  .regex(/^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$/, {
    message:
      "qualifiedName must be a dotted identifier path (e.g. 'tools.http.fetch')",
  });

function parseQualifiedName(raw: string | undefined): string {
  return QualifiedNameSchema.parse(raw === undefined ? "" : decodeURIComponent(raw));
}

/**
 * Resolve a `:snapshotId` path segment to a concrete `SnapshotId`.
 * Accepts the literal `"latest"` as a project-relative alias.
 */
async function resolveSnapshotId(
  snapshots: SnapshotService,
  projectId: ProjectId,
  raw: string,
): Promise<SnapshotId> {
  if (raw === "latest") {
    return await snapshots.resolve({ projectId });
  }
  return SnapshotIdSchema.parse(raw);
}

export function buildAgentDefinitionRoutes(snapshots: SnapshotService): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const rawSnapshotId = c.req.param("snapshotId") ?? "latest";
    try {
      const snapshotId = await resolveSnapshotId(snapshots, projectId, rawSnapshotId);
      const definitions = await snapshots.listAgentDefinitions(snapshotId);
      return c.json({ definitions, snapshotId });
    } catch (err) {
      if (err instanceof NoSnapshotForProject || err instanceof SnapshotNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:qualifiedName", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const rawSnapshotId = c.req.param("snapshotId") ?? "latest";
    const qualifiedName = parseQualifiedName(c.req.param("qualifiedName"));
    try {
      const snapshotId = await resolveSnapshotId(snapshots, projectId, rawSnapshotId);
      const definition = await snapshots.getAgentDefinition(
        snapshotId,
        qualifiedName,
      );
      return c.json({ definition, snapshotId });
    } catch (err) {
      if (
        err instanceof NoSnapshotForProject ||
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
