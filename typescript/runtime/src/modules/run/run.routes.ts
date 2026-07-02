import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import {
  cancelRunSchema,
  listRunsQuerySchema,
  runParamSchema,
  startRunSchema,
} from "./run.schema.js";
import { runService } from "./run.service.js";

export const runRoutes = new Hono<AppEnv>()
  .post(
    "/projects/:projectId/runs",
    requireJsonBody,
    zValidator("param", projectIdParamSchema),
    zValidator("json", startRunSchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      // Surface the run id as `id`, matching every other resource's create/identity envelope.
      const { runId } = await runService.start(projectId, c.req.valid("json"));
      return c.json(success({ id: runId }), 201);
    },
  )
  .get(
    "/projects/:projectId/runs",
    zValidator("param", projectIdParamSchema),
    zValidator("query", listRunsQuerySchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      return c.json(success(await runService.list(projectId, c.req.valid("query"))));
    },
  )
  .get("/projects/:projectId/runs/:runId", zValidator("param", runParamSchema), async (c) => {
    const { projectId, runId } = c.req.valid("param");
    return c.json(success(await runService.getById(projectId, runId)));
  })
  .post(
    "/projects/:projectId/runs/:runId/cancel",
    requireJsonBody,
    zValidator("param", runParamSchema),
    zValidator("json", cancelRunSchema),
    async (c) => {
      const { projectId, runId } = c.req.valid("param");
      const { reason } = c.req.valid("json");
      await runService.cancel(projectId, runId, reason);
      return c.json(success({ id: runId }));
    },
  );
