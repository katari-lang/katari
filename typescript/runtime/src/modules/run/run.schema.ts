// HTTP contract for the run resource: a user-started agent activation and its lifecycle.
// Behaviour is engine-backed (frozen here; see runtime/facade.ts).

import type { Json } from "@katari-lang/types";
import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export const startRunSchema = z.object({
  qualifiedName: z.string().min(1),
  name: z.string().optional(),
  /** Pin the run to a specific snapshot; defaults to the project head when omitted. */
  snapshotId: z.uuid().optional(),
  argument: z.custom<Json>().optional(),
});
export type StartRunBody = z.infer<typeof startRunSchema>;

export const cancelRunSchema = z.object({ reason: z.string().optional() });

export const runParamSchema = projectIdParamSchema.extend({ runId: z.uuid() });
