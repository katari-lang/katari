// On-boot recovery.
//
// 1. For every version that still owns running/cancelling agents, check
//    whether a snapshot exists.
// 2. Versions with snapshots get acquired immediately (warm cache).
// 3. Versions without snapshots had their machine die before persisting —
//    flip every running/cancelling agent on those versions to `error`.

import type { Logger } from "katari-runtime";
import type { MachineRegistry } from "./registry.js";
import type { Storage } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  registry: MachineRegistry,
  logger: Logger,
): Promise<void> {
  const versionIds = await storage.agents.listRunningVersionIds();
  for (const versionId of versionIds) {
    const snap = await storage.snapshots.get(versionId);
    if (snap === null) {
      logger.log(
        "warn",
        "no snapshot for version with running agents — marking them error",
        { versionId },
      );
      await storage.agents.markAllRunningAsError(
        versionId,
        "machine snapshot missing on restart",
      );
      continue;
    }
    try {
      await registry.acquire(versionId);
      logger.log("info", "warmed up machine on boot", { versionId });
    } catch (err) {
      logger.log("error", "failed to acquire machine on boot", {
        versionId,
        err,
      });
      await storage.agents.markAllRunningAsError(
        versionId,
        "machine failed to load on restart",
      );
    }
  }
}
