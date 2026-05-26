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
import type { SnapshotId, Storage } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  orchestrator: Orchestrator,
  logger: Logger,
): Promise<void> {
  await orchestrator.recoverOnBoot();

  // Re-issue terminate for runs in `cancelling`. Group by snapshotId so
  // all runs for the same snapshot are processed in a single tick (= one
  // lock acquisition + one checkpoint round-trip instead of N).
  const cancellingRuns = await storage.runsAudit.list({
    state: "cancelling",
    limit: 500,
  });
  const bySnapshot = new Map<SnapshotId, typeof cancellingRuns>();
  for (const run of cancellingRuns) {
    const existing = bySnapshot.get(run.snapshotId) ?? [];
    existing.push(run);
    bySnapshot.set(run.snapshotId, existing);
  }
  for (const [snapshotId, runs] of bySnapshot) {
    try {
      await orchestrator.tick(snapshotId, async (ctx) => {
        for (const run of runs) {
          await ctx.api.cancelRun({ bus: ctx.bus, runId: run.id });
        }
      });
    } catch (err) {
      const runIds = runs.map((r) => r.id);
      logger.log("warn", "recovery: failed to re-issue terminate", {
        snapshotId,
        runIds,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }
}
