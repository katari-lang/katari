// Boot recovery.
//
//   1. host.recoverOnBoot() — respawn sidecars + notify in-flight ext
//      delegations for every snapshot that still owns FFI work.
//   2. Re-issue terminate for runs left in the `cancelling` state, so the
//      cancel cascade resumes across a process restart (same effect as
//      ApiModule.cancelRun being called again).

import type { Logger } from "@katari-lang/runtime";
import type { ApiServerActorHost } from "./actor-host.js";
import { GcService } from "./services/gc-service.js";
import type { Storage } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  host: ApiServerActorHost,
  logger: Logger,
): Promise<void> {
  await host.recoverOnBoot();

  // Backstop blob GC: reclaim ephemeral refs whose owning entity is gone (a
  // single-owner release lost to a crash). Safe here — boot runs before the
  // server accepts traffic, so nothing is concurrently producing refs.
  await new GcService(storage, logger).sweepAllProjects();

  const { items: cancellingRuns } = await storage.runs.list({
    state: "cancelling",
    limit: 500,
  });
  for (const run of cancellingRuns) {
    try {
      // The Run record carries its project directly.
      await host.runForProject(run.projectId, ({ bus, modules }) =>
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
