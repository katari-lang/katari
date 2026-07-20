import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import { setStoreEntrySchema, storeKeyParamSchema } from "./store.schema.js";
import { storeService } from "./store.service.js";

export const storeRoutes = new Hono<AppEnv>()
  .get("/projects/:projectId/store", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await storeService.list(projectId)));
  })
  .get("/projects/:projectId/store/:key", zValidator("param", storeKeyParamSchema), async (c) => {
    const { projectId, key } = c.req.valid("param");
    return c.json(success(await storeService.get(projectId, key)));
  })
  .put(
    "/projects/:projectId/store/:key",
    requireJsonBody,
    zValidator("param", storeKeyParamSchema),
    zValidator("json", setStoreEntrySchema),
    async (c) => {
      const { projectId, key } = c.req.valid("param");
      return c.json(success(await storeService.set(projectId, key, c.req.valid("json").value)));
    },
  )
  .delete(
    "/projects/:projectId/store/:key",
    zValidator("param", storeKeyParamSchema),
    async (c) => {
      const { projectId, key } = c.req.valid("param");
      await storeService.delete(projectId, key);
      return c.json(success({ key }));
    },
  );
