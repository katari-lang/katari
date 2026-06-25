// Open-escalation queries. An open escalation a user can answer is a run-root request the engine could not
// handle: an `escalations` row in the `open` state whose raiser is a run root (its instance's delegation is
// the api root's run delegation). Core opens an escalation row only for a user-facing request (a panic /
// control escape that reaches the run root fails the run, it is never an open row), so selecting the open
// run-root escalations needs no further request filter. This reads the Layer 1 `escalations` table directly —
// the same source the warm actor rebuilds its in-memory view from on recovery — so the API and the engine
// always agree.

import { and, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { delegations, escalations, instances } from "../../db/tables/execution.js";
import { apiRootIdOf, type ProjectId } from "../../runtime/ids.js";
import type { Value } from "../../runtime/value/types.js";

/** An open escalation as the API presents it (its `argument` rendered to Json by the service). */
export interface OpenEscalationView {
  id: string;
  request: string;
  argument: Value | null;
}

export const escalationRepository = {
  /** The open escalations awaiting an answer for a project. Joins each open escalation to its raiser instance
   *  and that instance's summoning delegation, keeping only those raised by a run root (the delegation's
   *  caller is the api root). No request filter is needed — core opens a row only for a user-facing request. */
  async listOpen(executor: Executor, projectId: string): Promise<OpenEscalationView[]> {
    const apiRoot = apiRootIdOf(projectId as ProjectId);
    return executor
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
  },
};
