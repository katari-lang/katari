// Project-scoped escalation routes.
//
// Mounted at `/project/:projectId/escalation`. Escalations are project-
// scoped (= the deploy unit), even though each one carries the snapshot
// of the delegation that raised it. AI → user questions are recorded as
// open in `escalations` (receiver=API) via the `escalate` branch of
// ApiModule.feed; when the operator views this list and answers, an
// `escalateAck` flows on the bus and the delegation thread resumes.

import type { EscalationId } from "@katari-lang/runtime";
import { API_ENDPOINT, valueFromRaw } from "@katari-lang/runtime";
import { Hono } from "hono";
import { z } from "zod";
import type { ApiServerOrchestrator } from "../orchestrator.js";
import type { Storage } from "../storage/types.js";
import { escalationRowToWire } from "../wire/agent-wire.js";
import {
  AnswerEscalationSchema,
  EscalationIdSchema,
  PaginationQuerySchema,
  ProjectIdSchema,
  RunIdSchema,
  SnapshotIdSchema,
} from "./middleware/validation.js";

const ListQuerySchema = z
  .object({
    snapshotId: SnapshotIdSchema.optional(),
    runId: RunIdSchema.optional(),
    state: z.enum(["open", "answered", "cancelled"]).optional(),
  })
  .extend(PaginationQuerySchema.shape);

export function buildEscalationRoutes(orchestrator: ApiServerOrchestrator, storage: Storage): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const query = ListQuerySchema.parse(c.req.query());
    // Filter by `receiverEndpoint = API_ENDPOINT` so the operator-facing
    // list never accidentally surfaces FFI-relay escalations (= those
    // are internal plumbing, not questions a human should answer).
    const result = await storage.escalations.list({
      projectId,
      snapshotId: query.snapshotId,
      rootDelegationId: query.runId,
      state: query.state,
      receiverEndpoint: API_ENDPOINT,
      limit: query.limit,
      offset: query.offset,
      cursor: query.cursor,
    });
    return c.json({
      escalations: result.items.map(escalationRowToWire),
      nextCursor: result.nextCursor,
    });
  });

  app.get("/:escalationId", async (c) => {
    const escalationId = EscalationIdSchema.parse(c.req.param("escalationId")) as EscalationId;
    const escalation = await storage.escalations.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    return c.json({ escalation: escalationRowToWire(escalation) });
  });

  app.post("/:escalationId/ack", async (c) => {
    const escalationId = EscalationIdSchema.parse(c.req.param("escalationId")) as EscalationId;
    const body = AnswerEscalationSchema.parse(await c.req.json());
    const escalation = await storage.escalations.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    if (escalation.state !== "open") {
      return c.json({ error: `escalation already ${escalation.state}` }, 409);
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
