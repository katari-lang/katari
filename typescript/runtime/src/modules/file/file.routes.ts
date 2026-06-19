import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { fileParamSchema } from "./file.schema.js";
import { fileService } from "./file.service.js";

export const fileRoutes = new Hono<AppEnv>()
  .post("/projects/:projectId/files", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await fileService.upload(projectId)), 201);
  })
  .get("/projects/:projectId/files", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await fileService.list(projectId)));
  })
  .get("/projects/:projectId/files/:fileId", zValidator("param", fileParamSchema), async (c) => {
    const { projectId, fileId } = c.req.valid("param");
    return c.json(success(await fileService.download(projectId, fileId)));
  })
  .delete("/projects/:projectId/files/:fileId", zValidator("param", fileParamSchema), async (c) => {
    const { projectId, fileId } = c.req.valid("param");
    await fileService.delete(projectId, fileId);
    return c.json(success({ id: fileId }));
  });
