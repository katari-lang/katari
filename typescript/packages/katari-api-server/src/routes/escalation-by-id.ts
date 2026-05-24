// Flat "by id" single-entity escalation routes.
//
// Mounted at `/escalation` alongside the project-scoped routes at
// `/project/:projectId/escalation`. Same rationale as agent-by-id: the
// CLI knows escalation ids without context, and a UUID is sufficient
// for lookups / ack. List endpoints stay project-scoped.

import { Hono } from "hono";
import { valueFromRaw } from "@katari-lang/runtime";
import type { EscalationId } from "@katari-lang/runtime";
import {
  AnswerEscalationSchema,
  EscalationIdSchema,
} from "./middleware/validation.js";
import { escalationRowToWire } from "../wire/agent-wire.js";
import type { Orchestrator } from "../orchestrator.js";
import type { Storage } from "../storage/types.js";

export function buildEscalationByIdRoutes(
  orchestrator: Orchestrator,
  storage: Storage,
): Hono {
  const app = new Hono();

  app.get("/:escalationId", async (c) => {
    const escalationId = EscalationIdSchema.parse(
      c.req.param("escalationId"),
    ) as EscalationId;
    const escalation = await storage.escalations.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    return c.json({ escalation: escalationRowToWire(escalation) });
  });

  app.post("/:escalationId/ack", async (c) => {
    const escalationId = EscalationIdSchema.parse(
      c.req.param("escalationId"),
    ) as EscalationId;
    const body = AnswerEscalationSchema.parse(await c.req.json());
    const escalation = await storage.escalations.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    if (escalation.state !== "open") {
      return c.json(
        { error: `escalation already ${escalation.state}` },
        409,
      );
    }
    const decoded = valueFromRaw(body.value);
    const result = await orchestrator.tick(escalation.snapshotId, async (ctx) => {
      return ctx.api.answerEscalation({
        bus: ctx.bus,
        escalationId,
        value: decoded,
      });
    });
    return c.json({ ok: result.ok });
  });

  return app;
}
