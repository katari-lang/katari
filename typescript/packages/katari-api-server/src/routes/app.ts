// Top-level Hono app. Composed in `bin.ts` with concrete services and
// reused by integration tests via `app.fetch(req)`.

import { Hono } from "hono";
import type { AgentService } from "../services/agent-service.js";
import type { ModuleService } from "../services/module-service.js";
import { buildAgentRoutes } from "./agent.js";
import { buildAgentDefinitionRoutes } from "./agent-definition.js";
import { buildModuleRoutes } from "./module.js";

export type AppDeps = {
  agents: AgentService;
  modules: ModuleService;
};

export function buildApp(deps: AppDeps): Hono {
  const app = new Hono();
  app.route("/module", buildModuleRoutes(deps.modules));
  app.route("/agent", buildAgentRoutes(deps.agents));
  app.route("/agent-definition", buildAgentDefinitionRoutes(deps.modules));
  return app;
}
