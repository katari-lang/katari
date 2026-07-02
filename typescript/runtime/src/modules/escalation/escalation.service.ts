import type { JSONSchema, Json, SchemaInfo } from "@katari-lang/types";
import { db } from "../../db/client.js";
import { facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";
import { collectEntries, deriveAnswerSchema, loadSnapshotModules } from "../agent/agent.reader.js";
import { escalationRepository, type OpenEscalationView } from "./escalation.repository.js";

/** The wire shape of an open escalation: its `argument` `Value` rendered back to Json, plus the schema
 *  an answer must satisfy (null when the request has no entry in the run's snapshot — the client falls
 *  back to unvalidated input). */
function toEscalationResponse(view: OpenEscalationView, answerSchema: JSONSchema | null) {
  return {
    id: view.id,
    request: view.request,
    // The user-facing boundary: a secret in an escalation's question is redacted, never observed.
    argument: view.argument === null ? null : valueToJson(view.argument, "redact"),
    runId: view.runId,
    createdAt: view.createdAt,
    answerSchema,
  };
}

export const escalationService = {
  /** The open (user-facing) escalations awaiting an answer for a project — read directly from the Layer 1
   *  `escalations` table (the durable source of truth), like the runs list reads from `delegations`. Each
   *  view carries the request's answer schema, derived from the raising run's snapshot IR; snapshots are
   *  loaded once per distinct id (not once per escalation). */
  async listOpen(projectId: string) {
    const views = await escalationRepository.listOpen(db, projectId);
    const entriesBySnapshot = new Map<string | null, Map<string, SchemaInfo>>();
    const responses = [];
    for (const view of views) {
      let entries = entriesBySnapshot.get(view.snapshotId);
      if (entries === undefined) {
        // A schema is an enrichment, not the resource: an unloadable snapshot (e.g. a defensive null pin
        // on a project whose head moved on) degrades that row to `answerSchema: null` rather than failing
        // the whole listing.
        try {
          entries = collectEntries(
            (await loadSnapshotModules(projectId, view.snapshotId ?? undefined)).modules,
          );
        } catch {
          entries = new Map();
        }
        entriesBySnapshot.set(view.snapshotId, entries);
      }
      responses.push(toEscalationResponse(view, deriveAnswerSchema(entries, view.request)));
    }
    return responses;
  },

  answer(projectId: string, escalationId: string, value: Json): Promise<void> {
    return facade.answerEscalation({ projectId, escalationId, value });
  },
};
