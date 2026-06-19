import { Hono } from "hono";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { envKeyParamSchema, projectIdParamSchema, setEnvSchema } from "./env.schema.js";
import { envService } from "./env.service.js";

export const envRoutes = new Hono<AppEnv>()
  .get("/projects/:projectId/env", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await envService.list(projectId)));
  })
  .get("/projects/:projectId/env/:key", zValidator("param", envKeyParamSchema), async (c) => {
    const { projectId, key } = c.req.valid("param");
    return c.json(success(await envService.get(projectId, key)));
  })
  .put(
    "/projects/:projectId/env/:key",
    zValidator("param", envKeyParamSchema),
    zValidator("json", setEnvSchema),
    async (c) => {
      const { projectId, key } = c.req.valid("param");
      await envService.set(projectId, key, c.req.valid("json"));
      return c.json(success({ key }));
    },
  )
  .delete("/projects/:projectId/env/:key", zValidator("param", envKeyParamSchema), async (c) => {
    const { projectId, key } = c.req.valid("param");
    await envService.delete(projectId, key);
    return c.json(success({ key }));
  });
