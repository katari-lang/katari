// The `oauth_clients` registry's admin routes: register / replace (PUT), list (GET, secret write-only),
// forget (DELETE). Mounted under the bearer-authenticated `/api/v1`.

import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { oauthClientBodySchema, oauthClientParamSchema } from "./oauth-client.schema.js";
import { oauthClientService } from "./oauth-client.service.js";

export const oauthClientRoutes = new Hono<AppEnv>()
  .get(
    "/projects/:projectId/oauth-clients",
    zValidator("param", projectIdParamSchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      return c.json(success(await oauthClientService.list(projectId)));
    },
  )
  .put(
    "/projects/:projectId/oauth-clients/:name",
    zValidator("param", oauthClientParamSchema),
    zValidator("json", oauthClientBodySchema),
    async (c) => {
      const { projectId, name } = c.req.valid("param");
      await oauthClientService.upsert(projectId, name, c.req.valid("json"));
      return c.body(null, 204);
    },
  )
  .delete(
    "/projects/:projectId/oauth-clients/:name",
    zValidator("param", oauthClientParamSchema),
    async (c) => {
      const { projectId, name } = c.req.valid("param");
      await oauthClientService.delete(projectId, name);
      return c.body(null, 204);
    },
  );
