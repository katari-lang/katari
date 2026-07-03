import type { JSONSchema, Json, SchemaInfo } from "@katari-lang/types";
import { db } from "../../db/client.js";
import { BadRequestError, NotFoundError } from "../../lib/errors.js";
import { decodeClientJson, facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";
import { conformValue, renderConformFailures } from "../../runtime/value/validation.js";
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

  /** Answer an open escalation. The answer is validated against the request's answer schema *here*, at
   *  the acceptance surface: the answering party is a live external counterparty who can retry, so a
   *  mismatch is a 400 and the escalation stays open — never a panic, which would fail the run for the
   *  answerer's mistake. (Internal answers — a handler's resume value — are statically typed by the
   *  compiler, so this surface is the only unchecked entry for answers.) */
  async answer(projectId: string, escalationId: string, value: Json): Promise<void> {
    const view = await escalationRepository.findOpen(db, projectId, escalationId);
    if (view === undefined) {
      throw new NotFoundError(`Escalation ${escalationId} not found (or already answered).`);
    }
    validateAnswer(value, await answerSchemaOf(projectId, view));
    return facade.answerEscalation({ projectId, escalationId, value });
  },
};

/** The answer schema for one escalation, resolved from its run's pinned snapshot. Degrades to null
 *  (unvalidated) exactly like `listOpen` advertises — an answer must never be held to a schema stricter
 *  than the one the client was shown, or an escalation with an unresolvable schema could never be
 *  answered at all. */
async function answerSchemaOf(
  projectId: string,
  view: OpenEscalationView,
): Promise<JSONSchema | null> {
  try {
    const { modules } = await loadSnapshotModules(projectId, view.snapshotId ?? undefined);
    return deriveAnswerSchema(collectEntries(modules), view.request);
  } catch {
    return null;
  }
}

/** Reject (400) an answer that does not conform to the request's answer schema. A null schema means no
 *  schema could be advertised (no snapshot entry for the request); the answer passes unvalidated, matching
 *  the client's fallback. The decode mirrors the engine's own (`facade.answerEscalation` re-decodes the
 *  same Json), so what is checked is exactly what the raiser will resume with. */
export function validateAnswer(value: Json, schema: JSONSchema | null): void {
  if (schema === null) return;
  const check = conformValue(decodeClientJson(value, "the answer"), schema);
  if (!check.ok) {
    throw new BadRequestError(
      `the answer does not conform to the request's answer schema — ${renderConformFailures(check.failures)}`,
    );
  }
}
