// Agent definition routes — JSON Schemas for AI tool calling.

import { Hono } from "hono";
import {
  AgentDefinitionNotFound,
  ModuleNotFound,
  type ModuleService,
} from "../services/module-service.js";
import type { VersionId } from "../storage/types.js";

export function buildAgentDefinitionRoutes(modules: ModuleService): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const versionId = c.req.query("versionId") as VersionId | undefined;
    if (versionId === undefined) {
      return c.json({ error: "versionId query parameter is required" }, 400);
    }
    try {
      const defs = await modules.listAgentDefinitions(versionId);
      return c.json({ agents: defs });
    } catch (err) {
      if (err instanceof ModuleNotFound) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  app.get("/:versionId/:qualifiedName", async (c) => {
    const versionId = c.req.param("versionId") as VersionId;
    const qualifiedName = decodeURIComponent(c.req.param("qualifiedName"));
    try {
      const def = await modules.getAgentDefinition(versionId, qualifiedName);
      return c.json(def);
    } catch (err) {
      if (
        err instanceof ModuleNotFound ||
        err instanceof AgentDefinitionNotFound
      ) {
        return c.json({ error: err.message }, 404);
      }
      throw err;
    }
  });

  return app;
}
