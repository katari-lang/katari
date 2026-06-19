import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import { createProjectSchema } from "./project.schema.js";
import { projectService } from "./project.service.js";

export const projectRoutes = new Hono<AppEnv>()
  .post("/projects", requireJsonBody, zValidator("json", createProjectSchema), async (c) => {
    const project = await projectService.create(c.req.valid("json"));
    return c.json(success(project), 201);
  })
  .get("/projects", async (c) => {
    return c.json(success(await projectService.list()));
  })
  .get("/projects/:projectId", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await projectService.getById(projectId)));
  })
  .delete("/projects/:projectId", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    await projectService.delete(projectId);
    return c.json(success({ id: projectId }));
  });
