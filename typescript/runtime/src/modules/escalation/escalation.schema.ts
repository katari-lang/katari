// HTTP contract for the escalation resource: user-facing capability requests raised by a run.
// Behaviour is engine-backed (frozen here; see runtime/facade.ts).

import type { Json } from "@katari-lang/types";
import { z } from "zod";

export const answerEscalationSchema = z.object({ value: z.custom<Json>() });

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
export const escalationParamSchema = z.object({
  projectId: z.uuid(),
  escalationId: z.uuid(),
});
