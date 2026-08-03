import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { pagedList, success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import {
  cancelRunSchema,
  listRunEventsQuerySchema,
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
      return c.json(pagedList(c, await runService.list(projectId, c.req.valid("query"))));
    },
  )
  .get("/projects/:projectId/runs/:runId", zValidator("param", runParamSchema), async (c) => {
    const { projectId, runId } = c.req.valid("param");
    return c.json(success(await runService.getById(projectId, runId)));
  })
  .get(
    "/projects/:projectId/runs/:runId/escalations",
    zValidator("param", runParamSchema),
    async (c) => {
      const { projectId, runId } = c.req.valid("param");
      return c.json(success(await runService.listEscalationAudit(projectId, runId)));
    },
  )
  .get("/projects/:projectId/runs/:runId/tree", zValidator("param", runParamSchema), async (c) => {
    const { projectId, runId } = c.req.valid("param");
    return c.json(success(await runService.getDelegationTree(projectId, runId)));
  })
  .get(
    "/projects/:projectId/runs/:runId/events",
    zValidator("param", runParamSchema),
    zValidator("query", listRunEventsQuerySchema),
    async (c) => {
      const { projectId, runId } = c.req.valid("param");
      return c.json(success(await runService.listEvents(projectId, runId, c.req.valid("query"))));
    },
  )
  // Sweep the run's trace. The journal only ever feeds the GET above, so dropping it costs no execution
  // state — and a resident run never reaches a terminal state at which its trace would be reclaimed for
  // it, so the sweep is offered while the run is live. `deleted` rides beside the identity so the caller
  // can report what it reclaimed.
  .delete(
    "/projects/:projectId/runs/:runId/events",
    zValidator("param", runParamSchema),
    async (c) => {
      const { projectId, runId } = c.req.valid("param");
      const deleted = await runService.clearEvents(projectId, runId);
      return c.json(success({ id: runId, deleted }));
    },
  )
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
