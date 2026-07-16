import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { credentialParamSchema } from "./credential.schema.js";
import { credentialService } from "./credential.service.js";

export const credentialRoutes = new Hono<AppEnv>()
  .get("/projects/:projectId/credentials", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await credentialService.list(projectId)));
  })
  .delete(
    "/projects/:projectId/credentials/:name",
    zValidator("param", credentialParamSchema),
    async (c) => {
      const { projectId, name } = c.req.valid("param");
      await credentialService.delete(projectId, name);
      return c.body(null, 204);
    },
  );
