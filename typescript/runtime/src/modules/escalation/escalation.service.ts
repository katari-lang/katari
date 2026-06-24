import type { Json } from "@katari-lang/types";
import { db } from "../../db/client.js";
import { facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";
import { escalationRepository, type OpenEscalationView } from "./escalation.repository.js";

/** The wire shape of an open escalation: its `argument` `Value` rendered back to Json. */
function toEscalationResponse(view: OpenEscalationView) {
  return {
    id: view.id,
    request: view.request,
    argument: view.argument === null ? null : valueToJson(view.argument),
  };
}

export const escalationService = {
  /** The open (user-facing) escalations awaiting an answer for a project — read directly from the Layer 1
   *  `escalations` table (the durable source of truth), like the runs list reads from `delegations`. */
  async listOpen(projectId: string) {
    const views = await escalationRepository.listOpen(db, projectId);
    return views.map(toEscalationResponse);
  },

  answer(projectId: string, escalationId: string, value: Json): Promise<void> {
    return facade.answerEscalation({ projectId, escalationId, value });
  },
};
