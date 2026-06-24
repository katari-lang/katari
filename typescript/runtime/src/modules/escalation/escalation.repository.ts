// Open-escalation queries. An open escalation a user can answer is a run-root request the engine could not
// handle: an `escalations` row in the `open` state whose raiser is a run root (its instance's delegation is
// the api root's run delegation), and whose `request` is a genuine capability (not a panic / control
// escape). This reads the Layer 1 `escalations` table directly — the same source, and the same filter, the
// warm actor rebuilds its in-memory view from on recovery — so the API and the engine always agree.

import { and, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { delegations, escalations, instances } from "../../db/tables/execution.js";
import { isUserFacingRequest } from "../../runtime/escalation-filter.js";
import { apiRootIdOf, type ProjectId } from "../../runtime/ids.js";
import type { Value } from "../../runtime/value/types.js";

/** An open escalation as the API presents it (its `argument` rendered to Json by the service). */
export interface OpenEscalationView {
  id: string;
  request: string;
  argument: Value | null;
}

export const escalationRepository = {
  /** The open, user-facing escalations awaiting an answer for a project. Joins each open escalation to its
   *  raiser instance and that instance's summoning delegation, keeping only those raised by a run root (the
   *  delegation's caller is the api root); the genuine-request filter then drops any transient panic /
   *  control escape (which fails the run rather than waits). */
  async listOpen(executor: Executor, projectId: string): Promise<OpenEscalationView[]> {
    const apiRoot = apiRootIdOf(projectId as ProjectId);
    const rows = await executor
      .select({
        id: escalations.id,
        request: escalations.request,
        argument: escalations.argument,
      })
      .from(escalations)
      .innerJoin(instances, eq(instances.id, escalations.raiserInstanceId))
      .innerJoin(delegations, eq(delegations.id, instances.delegationId))
      .where(
        and(
          eq(escalations.projectId, projectId),
          eq(escalations.state, "open"),
          eq(delegations.callerInstanceId, apiRoot),
        ),
      );
    return rows.filter((row) => isUserFacingRequest(row.request));
  },
};
