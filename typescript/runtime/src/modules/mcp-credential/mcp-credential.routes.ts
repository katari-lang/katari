import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { mcpCredentialParamSchema } from "./mcp-credential.schema.js";
import { mcpCredentialService } from "./mcp-credential.service.js";

export const mcpCredentialRoutes = new Hono<AppEnv>()
  .get(
    "/projects/:projectId/mcp-credentials",
    zValidator("param", projectIdParamSchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      return c.json(success(await mcpCredentialService.list(projectId)));
    },
  )
  .delete(
    "/projects/:projectId/mcp-credentials/:name",
    zValidator("param", mcpCredentialParamSchema),
    async (c) => {
      const { projectId, name } = c.req.valid("param");
      await mcpCredentialService.delete(projectId, name);
      return c.body(null, 204);
    },
  );
