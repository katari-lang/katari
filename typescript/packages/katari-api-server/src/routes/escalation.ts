// Project-scoped escalation routes.
//
// Mounted at `/project/:projectId/escalation`. The operator-facing escalations
// (the ones that reached the API awaiting an answer) live in the API's per-run
// `run_escalations_audit` view (pending = `answer` null, answered otherwise) —
// the API records them from the bus `escalate` (mapping `D_core` → run on its
// OWN tables). The live `escalations` table is CORE's (raiser-owned, for
// cascade) and is not surfaced here. Answering pushes an `escalateAck` on the
// bus and the raiser resumes.

import { valueFromRaw } from "@katari-lang/runtime";
import { Hono } from "hono";
import { z } from "zod";
import type { ApiServerActorHost } from "../actor-host.js";
import type { Storage } from "../storage/types.js";
import { runEscalationToWire } from "../wire/agent-wire.js";
import {
  AnswerEscalationSchema,
  EscalationIdSchema,
  ProjectIdSchema,
  RunIdSchema,
} from "./middleware/validation.js";

const ListQuerySchema = z.object({
  runId: RunIdSchema.optional(),
  state: z.enum(["open", "answered"]).optional(),
});

export function buildEscalationRoutes(host: ApiServerActorHost, storage: Storage): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const query = ListQuerySchema.parse(c.req.query());
    // The operator-facing view is per-run. With no runId, aggregate across the
    // project's runs (local, aggregator-side). State filter: open = pending.
    let runIds: string[];
    if (query.runId !== undefined) {
      runIds = [query.runId];
    } else {
      const runs = await storage.runs.list({ projectId, limit: 500 });
      runIds = runs.items.map((r) => r.id);
    }
    const rows = (
      await Promise.all(runIds.map((id) => storage.runEscalationsAudit.list(id as never)))
    ).flat();
    const wire = rows
      .map(runEscalationToWire)
      .filter((e) => query.state === undefined || e.state === query.state);
    return c.json({ escalations: wire, nextCursor: null });
  });

  app.get("/:escalationId", async (c) => {
    const escalationId = EscalationIdSchema.parse(c.req.param("escalationId"));
    const escalation = await storage.runEscalationsAudit.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    return c.json({ escalation: runEscalationToWire(escalation) });
  });

  app.post("/:escalationId/ack", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const escalationId = EscalationIdSchema.parse(c.req.param("escalationId"));
    const body = AnswerEscalationSchema.parse(await c.req.json());
    const escalation = await storage.runEscalationsAudit.get(escalationId);
    if (escalation === null) {
      return c.json({ error: "escalation not found" }, 404);
    }
    if (escalation.answer !== undefined) {
      return c.json({ error: "escalation already answered" }, 409);
    }
    const decoded = valueFromRaw(body.value);
    const result = await host.runForProject(projectId, ({ bus, modules }) =>
      modules.api.answerEscalation({ bus, escalationId, value: decoded }),
    );
    return c.json({ ok: result.ok });
  });

  return app;
}
