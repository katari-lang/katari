import type { Json } from "@katari-lang/types";
import { facade } from "../../runtime/facade.js";

export const escalationService = {
  /** The open (user-facing) escalations awaiting an answer for a project — run-root requests the engine
   *  could not handle internally, held by the warm actor until answered. */
  listOpen(projectId: string) {
    return facade.listOpenEscalations(projectId);
  },

  answer(projectId: string, escalationId: string, value: Json): Promise<void> {
    return facade.answerEscalation({ projectId, escalationId, value });
  },
};
