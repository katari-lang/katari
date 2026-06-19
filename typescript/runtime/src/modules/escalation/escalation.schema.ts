// HTTP contract for the escalation resource: user-facing capability requests raised by a run.
// Behaviour is engine-backed (frozen here; see runtime/facade.ts).

import type { Json } from "@katari-lang/types";
import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export { projectIdParamSchema };

export const answerEscalationSchema = z.object({ value: z.custom<Json>() });

export const escalationParamSchema = projectIdParamSchema.extend({
  escalationId: z.uuid(),
});
