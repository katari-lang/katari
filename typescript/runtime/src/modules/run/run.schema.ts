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

/** List filters, all optional so the bare list stays the full (unbounded, newest-first) history.
 *  `limit` + `offset` page it (the console shows one page at a time); `search` matches an ILIKE over the
 *  run name / qualified name / id. `limit` is capped well above any interactive page size. */
export const listRunsQuerySchema = z.object({
  state: z.enum(["running", "cancelling", "done", "error", "cancelled"]).optional(),
  search: z.string().trim().min(1).max(200).optional(),
  limit: z.coerce.number().int().positive().max(500).optional(),
  offset: z.coerce.number().int().nonnegative().optional(),
});
export type ListRunsQuery = z.infer<typeof listRunsQuerySchema>;

export const runParamSchema = projectIdParamSchema.extend({ runId: z.uuid() });

/** The six external-event kinds a trace is made of — the `kind` filter's domain. */
export const runEventKinds = [
  "delegate",
  "delegateAck",
  "escalate",
  "escalateAck",
  "terminate",
  "terminateAck",
] as const;

/** Trace query. Two paging modes share one endpoint:
 *   - keyset tail (`after` = the last seq the client already has, exclusive) — a watcher / the CLI polls
 *     with the growing `after` to stream new events; no total is computed on this hot path.
 *   - offset paging (`offset` + `limit`) — the console browses a long trace one page at a time, with a
 *     `total` for the page math. `after` wins if both are given.
 *  `kind` filters to one event kind; `search` is a case-insensitive substring over the whole event
 *  (its ids, targets, request names, and any public payload text — sealed private values never match).
 *  `order` is the seq direction (default `asc`, oldest first; the console defaults to `desc`). */
export const listRunEventsQuerySchema = z.object({
  after: z.coerce.number().int().nonnegative().optional(),
  offset: z.coerce.number().int().nonnegative().optional(),
  limit: z.coerce.number().int().positive().max(1000).optional(),
  kind: z.enum(runEventKinds).optional(),
  search: z.string().trim().min(1).max(200).optional(),
  order: z.enum(["asc", "desc"]).optional(),
});
export type ListRunEventsQuery = z.infer<typeof listRunEventsQuerySchema>;
