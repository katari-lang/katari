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

/** List filters: both optional so the bare list stays the full (unbounded) history. `limit` is capped
 *  well above any interactive page size — a client wanting "everything" pages by createdAt instead. */
export const listRunsQuerySchema = z.object({
  state: z.enum(["running", "cancelling", "done", "error", "cancelled"]).optional(),
  limit: z.coerce.number().int().positive().max(500).optional(),
});
export type ListRunsQuery = z.infer<typeof listRunsQuerySchema>;

export const runParamSchema = projectIdParamSchema.extend({ runId: z.uuid() });
