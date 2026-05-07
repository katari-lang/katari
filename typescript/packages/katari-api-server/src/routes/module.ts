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
      // Don't dump the full IR + schema bundle by default — they can be
      // large. Return metadata only; clients that need the IR can hit a
      // dedicated route in the future.
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

  return app;
}
