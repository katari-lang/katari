// Escalation routes: list pending user-facing escalations and answer them.
//
// AI -> user questions are recorded as open in `api_pending_escalations`
// via the `escalate` branch of ApiModule.feed. When the CLI / GUI views
// this list and answers, an `escalateAck` flows on the bus and the agent
// thread resumes.

import { Hono } from "hono";
import { valueFromRaw } from "@katari-lang/runtime";
import type { EscalationId } from "@katari-lang/runtime";
import {
  AnswerEscalationSchema,
  EscalationIdSchema,
  PaginationQuerySchema,
  ProjectIdSchema,
  SnapshotIdSchema,
} from "./middleware/validation.js";
import { apiEscalationToWire } from "../wire/agent-wire.js";
import type { Orchestrator } from "../orchestrator.js";
import type { Storage } from "../storage/types.js";
import { z } from "zod";

const ListQuerySchema = z
  .object({
    projectId: ProjectIdSchema.optional(),
    snapshotId: SnapshotIdSchema.optional(),
    state: z.enum(["open", "answered", "cancelled"]).optional(),
  })
  .merge(PaginationQuerySchema);

export function buildEscalationRoutes(
  orchestrator: Orchestrator,
  storage: Storage,
): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const query = ListQuerySchema.parse(c.req.query());
    let snapshotId = query.snapshotId;
    if (snapshotId === undefined && query.projectId !== undefined) {
      const latest = await storage.snapshots.latest(query.projectId);
      snapshotId = latest ?? undefined;
    }
    const list = await storage.apiEscalations.list({
      snapshotId,
      state: query.state,
      limit: query.limit,
      offset: query.offset,
    });
    return c.json({ escalations: list.map(apiEscalationToWire) });
  });

  app.post("/:escalationId/ack", async (c) => {
    const escalationId = EscalationIdSchema.parse(
      c.req.param("escalationId"),
    ) as EscalationId;
    const body = AnswerEscalationSchema.parse(await c.req.json());
    const escalation = await storage.apiEscalations.get(escalationId);
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
