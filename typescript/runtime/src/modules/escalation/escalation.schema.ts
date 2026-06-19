// HTTP contract for the escalation resource: user-facing capability requests raised by a run.
// Behaviour is engine-backed (frozen here; see runtime/facade.ts).

import type { Json } from "@katari-lang/types";
import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export { projectIdParamSchema };

// `z.custom<Json>()` with no predicate accepts anything — including a missing key (parsed as
// `undefined`) — so an answer payload could silently arrive empty. Require the key to be present.
export const answerEscalationSchema = z.object({
  value: z.custom<Json>((value) => value !== undefined, {
    message: "An answer value is required.",
  }),
});

export const escalationParamSchema = projectIdParamSchema.extend({
  escalationId: z.uuid(),
});
