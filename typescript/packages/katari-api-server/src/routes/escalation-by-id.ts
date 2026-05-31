// Flat "by id" single-entity escalation routes.
//
// Mounted at `/escalation` alongside the project-scoped routes at
// `/project/:projectId/escalation`. Same rationale as agent-by-id: the
// CLI knows escalation ids without context, and a UUID is sufficient
// for lookups / ack. List endpoints stay project-scoped.

import { valueFromRaw } from "@katari-lang/runtime";
import { Hono } from "hono";
import type { ApiServerActorHost } from "../actor-host.js";
import type { Storage } from "../storage/types.js";
import { runEscalationToWire } from "../wire/agent-wire.js";
import { AnswerEscalationSchema, EscalationIdSchema } from "./middleware/validation.js";

export function buildEscalationByIdRoutes(host: ApiServerActorHost, storage: Storage): Hono {
  const app = new Hono();

  app.get("/:escalationId", async (c) => {
    const escalationId = EscalationIdSchema.parse(c.req.param("escalationId"));
    const escalation = await storage.runEscalationsAudit.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    return c.json({ escalation: runEscalationToWire(escalation) });
  });

  app.post("/:escalationId/ack", async (c) => {
    const escalationId = EscalationIdSchema.parse(c.req.param("escalationId"));
    const body = AnswerEscalationSchema.parse(await c.req.json());
    const escalation = await storage.runEscalationsAudit.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    if (escalation.answer !== undefined) {
      return c.json({ error: "escalation already answered" }, 409);
    }
    // The flat route has no project in the URL — derive it from the run.
    const run = await storage.runs.get(escalation.runId);
    if (run === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    const decoded = valueFromRaw(body.value);
    const result = await host.runForProject(run.projectId, ({ bus, modules }) =>
      modules.api.answerEscalation({ bus, escalationId, value: decoded }),
    );
    return c.json({ ok: result.ok });
  });

  return app;
}
