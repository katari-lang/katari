// Agent definition routes — JSON Schemas for AI tool calling.

import { Hono } from "hono";
import {
  AgentDefinitionNotFound,
  ModuleNotFound,
  type ModuleService,
} from "../services/module-service.js";
import { VersionIdSchema } from "./middleware/validation.js";

export function buildAgentDefinitionRoutes(modules: ModuleService): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const queryVersionId = c.req.query("versionId");
    if (queryVersionId === undefined) {
      return c.json({ error: "versionId query parameter is required" }, 400);
    }
    const versionId = VersionIdSchema.parse(queryVersionId);
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
    const versionId = VersionIdSchema.parse(c.req.param("versionId"));
    // Hono's `:qualifiedName` is delivered raw (un-decoded); we decode
    // exactly once so the user-supplied "test.main" pattern works whether
    // the client sent it raw or as "test%2Emain".
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
