import { Hono } from "hono";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { agentParamSchema, listAgentsQuerySchema, projectIdParamSchema } from "./agent.schema.js";
import { agentService } from "./agent.service.js";

export const agentRoutes = new Hono<AppEnv>()
  .get(
    "/projects/:projectId/agents",
    zValidator("param", projectIdParamSchema),
    zValidator("query", listAgentsQuerySchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      const { snapshotId } = c.req.valid("query");
      return c.json(success(await agentService.list(projectId, snapshotId)));
    },
  )
  .get(
    "/projects/:projectId/agents/:qualifiedName",
    zValidator("param", agentParamSchema),
    async (c) => {
      const { projectId, qualifiedName } = c.req.valid("param");
      return c.json(success(await agentService.getByName(projectId, qualifiedName)));
    },
  );
