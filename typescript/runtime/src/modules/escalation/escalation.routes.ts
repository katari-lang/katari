import { Hono } from "hono";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import {
  answerEscalationSchema,
  escalationParamSchema,
  projectIdParamSchema,
} from "./escalation.schema.js";
import { escalationService } from "./escalation.service.js";

export const escalationRoutes = new Hono<AppEnv>()
  .get("/projects/:projectId/escalations", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await escalationService.listOpen(projectId)));
  })
  .post(
    "/projects/:projectId/escalations/:escalationId/answer",
    requireJsonBody,
    zValidator("param", escalationParamSchema),
    zValidator("json", answerEscalationSchema),
    async (c) => {
      const { projectId, escalationId } = c.req.valid("param");
      const { value } = c.req.valid("json");
      await escalationService.answer(projectId, escalationId, value);
      return c.json(success({ id: escalationId }));
    },
  );
