// Open-escalation queries. An open escalation a user can answer is a run-root request the engine could not
// handle: an `escalations` row in the `open` state whose raiser is a run root (its instance's delegation is
// the api root's run delegation). Core opens an escalation row only for a user-facing request (a panic /
// control escape that reaches the run root fails the run, it is never an open row), so selecting the open
// run-root escalations needs no further request filter. This reads the Layer 1 `escalations` table directly —
// the same source the warm actor rebuilds its in-memory view from on recovery — so the API and the engine
// always agree.

import { and, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { escalations, runs } from "../../db/tables/execution.js";
import { unsealFromStorage } from "../../runtime/actor/seal.js";
import type { Value } from "../../runtime/value/types.js";

/** An open escalation as the API presents it (its `argument` rendered to Json by the service). For a
 *  user-facing escalation the raiser's delegation IS the run, so `runId` links back to the run that is
 *  waiting; `snapshotId` is that run's pinned snapshot, carried so the service can resolve the request's
 *  answer schema from the right IR (null defensively means "the project head"). */
export interface OpenEscalationView {
  id: string;
  request: string;
  argument: Value | null;
  runId: string;
  snapshotId: string | null;
  createdAt: Date;
}

export const escalationRepository = {
  /** The open escalations awaiting an answer for a project — the ones addressed to the api root
   *  (`to_reactor = 'api'`), which are exactly the user-facing run-root escalations (core opens a row only for a
   *  user-facing request, and stamps its `to`). An escalation row exists only while open, so presence alone
   *  selects the open ones — no state filter. The left join picks up the raising run's snapshot pin; the
   *  run row always exists for a user-facing escalation, so a missing one just degrades `snapshotId` to null. */
  async listOpen(executor: Executor, projectId: string): Promise<OpenEscalationView[]> {
    const rows = await executor
      .select({
        id: escalations.id,
        request: escalations.request,
        argument: escalations.argument,
        runId: escalations.delegationId,
        snapshotId: runs.snapshotId,
        createdAt: escalations.createdAt,
      })
      .from(escalations)
      .leftJoin(runs, eq(runs.id, escalations.delegationId))
      .where(and(eq(escalations.projectId, projectId), eq(escalations.toReactor, "api")));
    // Decrypt the at-rest question before the service redacts it for the wire (the inverse of seal-on-write).
    return rows.map((row) => ({ ...row, argument: unsealFromStorage(row.argument) }));
  },
};
