// Boot recovery wrapper.
//
// Most of this is done by `Orchestrator.recoverOnBoot()`: enumerate the
// snapshots that have running runs, re-spawn subprocesses, and notify
// in-flight delegationIds via `restored` IPC.
//
// In addition: re-inject terminate for runs that were stopped in the
// `cancelling` state. This makes the Orchestrator invoke the same
// behaviour as ApiModule.cancelRun again so the cancel cascade resumes
// even across a process restart.

import type { Logger } from "@katari-lang/runtime";
import type { Orchestrator } from "./orchestrator.js";
import type { Storage } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  orchestrator: Orchestrator,
  logger: Logger,
): Promise<void> {
  await orchestrator.recoverOnBoot();

  // Re-issue terminate for runs in `cancelling`. These rows live in
  // `runs_audit` (ApiModule's persistent log). Page through them snapshot
  // by snapshot so a long backlog doesn't all land on one tick.
  const cancellingRuns = await storage.runsAudit.list({
    state: "cancelling",
    limit: 500,
  });
  for (const run of cancellingRuns) {
    try {
      await orchestrator.tick(run.snapshotId, async (ctx) => {
        await ctx.api.cancelRun({ bus: ctx.bus, runId: run.id });
      });
    } catch (err) {
      logger.log("warn", "recovery: failed to re-issue terminate", {
        runId: run.id,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }
}
