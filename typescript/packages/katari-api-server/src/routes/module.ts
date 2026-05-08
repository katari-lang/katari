// Module routes: upload, list, get.

import { Hono } from "hono";
import type { IRModule, SchemaBundle } from "katari-runtime";
import {
  ModuleNotFound,
  type ModuleService,
} from "../services/module-service.js";
import {
  PaginationQuerySchema,
  UploadModuleSchema,
  VersionIdSchema,
} from "./middleware/validation.js";

export function buildModuleRoutes(modules: ModuleService): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const body = UploadModuleSchema.parse(await c.req.json());
    const { versionId } = await modules.upload({
      // Schema validates only that the values are objects — the deep IR
      // structure is the compiler's contract, not the HTTP layer's.
      irModule: body.irModule as IRModule,
      schemaBundle: body.schemaBundle as SchemaBundle,
    });
    return c.json({ versionId }, 201);
  });

  app.get("/", async (c) => {
    const { limit, offset } = PaginationQuerySchema.parse(c.req.query());
    const summaries = await modules.list({ limit, offset });
    return c.json({ modules: summaries });
  });

  app.get("/:versionId", async (c) => {
    const versionId = VersionIdSchema.parse(c.req.param("versionId"));
    try {
      const row = await modules.get(versionId);
      // Default response: metadata only — IR + schema bundle can be
      // large, and most clients want to list / probe versions, not
      // download the IR. The /ir and /schema sub-routes return them.
      return c.json({
        id: row.id,
        name: row.name,
        createdAt: row.createdAt,
      });
    } catch (err) {
      if (err instanceof ModuleNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:versionId/ir", async (c) => {
    const versionId = VersionIdSchema.parse(c.req.param("versionId"));
    try {
      const row = await modules.get(versionId);
      return c.json(row.irModule);
    } catch (err) {
      if (err instanceof ModuleNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:versionId/schema", async (c) => {
    const versionId = VersionIdSchema.parse(c.req.param("versionId"));
    try {
      const row = await modules.get(versionId);
      return c.json(row.schemaBundle);
    } catch (err) {
      if (err instanceof ModuleNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.delete("/:versionId", async (c) => {
    const versionId = VersionIdSchema.parse(c.req.param("versionId"));
    try {
      await modules.delete(versionId);
      return c.body(null, 204);
    } catch (err) {
      if (err instanceof ModuleNotFound) {
        return c.json({ error: err.message }, 404);
      }
      // Postgres FK violations from `agents.version_id` surface here as
      // "update or delete on table ... violates foreign key constraint".
      // Map to 409 so clients distinguish "still in use" from server errors.
      if (err instanceof Error && /foreign key/i.test(err.message)) {
        return c.json(
          { error: "module version still has agents — cancel/delete them first" },
          409,
        );
      }
      throw err;
    }
  });

  return app;
}
