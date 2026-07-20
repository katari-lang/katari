// Open-escalation queries. An open escalation a user can answer is a run-root request the engine could not
// handle: an `escalations` row in the `open` state, addressed to the api root (`to_reactor = 'api'`), whose
// `request` names a genuine user-facing capability. The base now opens a durable row for EVERY escalate
// uniformly — a failure (panic / throw) and a control escape reaching the run root are `to = api` rows too
// (the api fails the run on them) — so `to_reactor = 'api'` alone no longer selects the answerable set; the
// user-facing classification is applied HERE, at the read (`isUserFacingRequest`), not in the base. This
// reads the Layer 1 `escalations` table directly — the same source the warm actor rebuilds its in-memory
// view from on recovery — so the API and the engine always agree.

import { and, eq, type SQL } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { escalations, runs } from "../../db/tables/execution.js";
import { unsealFromStorage } from "../../runtime/actor/seal.js";
import { isUserFacingRequest } from "../../runtime/escalation-filter.js";
import type { Value } from "../../runtime/value/types.js";

/** An open escalation as the API presents it (its `argument` rendered to Json by the service). For a
 *  `runId` is the row's own run attribution (the escalate event's `run` stamp — the run instance id),
 *  linking back to the run that is waiting; `snapshotId` is that run's pinned snapshot, carried so the
 *  service can resolve the request's answer schema from the right IR (null defensively means "the project
 *  head"). */
export interface OpenEscalationView {
  id: string;
  request: string;
  argument: Value | null;
  runId: string;
  snapshotId: string | null;
  createdAt: Date;
}

/** The shared open-escalation select: rows addressed to the api root (`to_reactor = 'api'`) whose `request`
 *  is a genuine user-facing capability — the base opens a `to = api` row for a run-root FAILURE too (a panic /
 *  throw / control escape), so the `isUserFacingRequest` post-filter is what excludes those. An escalation
 *  row exists only while open, so presence alone selects the open ones — no state filter. The left join picks
 *  up the raising run's snapshot pin; the run row always exists for a user-facing escalation, so a missing
 *  one just degrades `snapshotId` to null. */
async function selectOpen(executor: Executor, conditions: SQL[]): Promise<OpenEscalationView[]> {
  const rows = await executor
    .select({
      id: escalations.id,
      request: escalations.request,
      argument: escalations.argument,
      runId: escalations.runId,
      snapshotId: runs.snapshotId,
      createdAt: escalations.createdAt,
    })
    .from(escalations)
    .leftJoin(runs, eq(runs.id, escalations.runId))
    .where(and(eq(escalations.toReactor, "api"), ...conditions));
  // Keep only the user-facing (answerable) rows, then decrypt the at-rest question before the service
  // redacts it for the wire (the inverse of seal-on-write). A failure row (panic / throw / control) is a
  // `to = api` row too, so this filter — not the `to_reactor` predicate — is what makes it un-answerable.
  return rows
    .filter((row) => isUserFacingRequest(row.request))
    .map((row) => ({ ...row, argument: unsealFromStorage(row.argument) }));
}

export const escalationRepository = {
  /** The open escalations awaiting an answer for a project. */
  listOpen(executor: Executor, projectId: string): Promise<OpenEscalationView[]> {
    return selectOpen(executor, [eq(escalations.projectId, projectId)]);
  },

  /** One open escalation by id, or undefined when it does not exist (or is already answered — the row
   *  is deleted on answer, so absence covers both). The answer surface reads this to resolve the schema
   *  the answer must satisfy. */
  async findOpen(
    executor: Executor,
    projectId: string,
    escalationId: string,
  ): Promise<OpenEscalationView | undefined> {
    const rows = await selectOpen(executor, [
      eq(escalations.projectId, projectId),
      eq(escalations.id, escalationId),
    ]);
    return rows[0];
  },
};
