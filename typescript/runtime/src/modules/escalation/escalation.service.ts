import type { Json } from "@katari-lang/types";
import { and, eq } from "drizzle-orm";
import { db } from "../../db/client.js";
import { escalations } from "../../db/tables/execution.js";
import { facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";

export const escalationService = {
  /** The open (user-facing) escalations awaiting an answer for a project. Empty until the engine keeps a
   *  run-root request open (rather than failing the run) — answering is the matching follow-up. */
  async listOpen(projectId: string) {
    const rows = await db
      .select()
      .from(escalations)
      .where(and(eq(escalations.projectId, projectId), eq(escalations.state, "open")));
    return rows.map((row) => ({
      id: row.id,
      request: row.request,
      argument: row.argument === null ? null : valueToJson(row.argument),
      createdAt: row.createdAt,
    }));
  },

  answer(projectId: string, escalationId: string, value: Json): Promise<void> {
    return facade.answerEscalation({ projectId, escalationId, value });
  },
};
