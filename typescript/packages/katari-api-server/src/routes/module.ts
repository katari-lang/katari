// Module routes: upload, list, get.

import { Hono } from "hono";
import type { IRModule, SchemaBundle } from "katari-runtime";
import {
  ModuleNotFound,
  type ModuleService,
} from "../services/module-service.js";
import type { VersionId } from "../storage/types.js";

export function buildModuleRoutes(modules: ModuleService): Hono {
  const app = new Hono();

  app.post("/", async (c) => {
    const body = (await c.req.json()) as {
      irModule?: IRModule;
      schemaBundle?: SchemaBundle;
    };
    if (body.irModule === undefined || body.schemaBundle === undefined) {
      return c.json({ error: "irModule and schemaBundle are required" }, 400);
    }
    const { versionId } = await modules.upload({
      irModule: body.irModule,
      schemaBundle: body.schemaBundle,
    });
    return c.json({ versionId }, 201);
  });

  app.get("/", async (c) => {
    const summaries = await modules.list();
    return c.json({ modules: summaries });
  });

  app.get("/:versionId", async (c) => {
    const versionId = c.req.param("versionId") as VersionId;
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
