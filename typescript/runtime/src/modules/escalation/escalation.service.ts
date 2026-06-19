import type { Json } from "@katari-lang/types";
import { NotImplementedError } from "../../lib/errors.js";
import { facade } from "../../runtime/facade.js";

export const escalationService = {
  async listOpen(_projectId: string) {
    throw new NotImplementedError("Listing escalations is not implemented yet.");
  },

  answer(projectId: string, escalationId: string, value: Json) {
    return facade.answerEscalation({ projectId, escalationId, value });
  },
};
