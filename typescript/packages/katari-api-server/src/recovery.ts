// Boot recovery.
//
//   1. host.recoverOnBoot() — respawn sidecars + notify in-flight ext
//      delegations for every snapshot that still owns FFI work.
//   2. Re-issue terminate for runs left in the `cancelling` state, so the
//      cancel cascade resumes across a process restart (same effect as
//      ApiModule.cancelRun being called again).

import type { Logger } from "@katari-lang/runtime";
import type { ApiServerActorHost } from "./actor-host.js";
import type { Storage } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  host: ApiServerActorHost,
  logger: Logger,
): Promise<void> {
  await host.recoverOnBoot();

  const { items: cancellingRuns } = await storage.runsAudit.list({
    state: "cancelling",
    limit: 500,
  });
  for (const run of cancellingRuns) {
    try {
      // A run is bound to a snapshot in runs_audit; resolve its project.
      const snap = await storage.snapshots.get(run.snapshotId);
      if (snap === null) continue;
      await host.runForProject(snap.projectId, ({ bus, modules }) =>
        modules.api.cancelRun({ bus, runId: run.id }),
      );
    } catch (err) {
      logger.log("warn", "recovery: failed to re-issue terminate", {
        runId: run.id,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  }
}
