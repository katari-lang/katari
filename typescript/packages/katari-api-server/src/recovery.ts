// On-boot recovery.
//
// For every version that still owns running/cancelling agents:
//   1. If no snapshot exists, the machine died before persisting — flip
//      every running/cancelling agent on that version to `error`.
//   2. If a snapshot exists but deserialization throws, the snapshot is
//      corrupt — delete it (so the next boot doesn't repeat the failure)
//      and mark the agents as error.
//   3. If a snapshot exists and loads, warm the cache.
//   4. For each `cancelling` agent on that version, re-issue a terminate
//      via `MachineHandle.cancelAgent` so the cancellation that was
//      in-flight when the previous process died can run to completion
//      and the agent moves to `cancelled`.
//
// All three error paths are atomic at the storage level (single
// `withTransaction` per versionId).

import { type Logger } from "katari-runtime";
import { AgentService } from "./services/agent-service.js";
import type { MachineRegistry } from "./registry.js";
import type { Storage, VersionId } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  registry: MachineRegistry,
  logger: Logger,
  agents?: AgentService,
): Promise<void> {
  const versionIds = await storage.agents.listRunningVersionIds();
  for (const versionId of versionIds) {
    await recoverOneVersion(storage, registry, logger, agents, versionId);
  }
}

async function recoverOneVersion(
  storage: Storage,
  registry: MachineRegistry,
  logger: Logger,
  agents: AgentService | undefined,
  versionId: VersionId,
): Promise<void> {
  const snap = await storage.snapshots.get(versionId);
  if (snap === null) {
    await storage.withTransaction(async (tx) => {
      logger.log(
        "warn",
        "no snapshot for version with running agents — marking them error",
        { versionId },
      );
      await tx.agents.markAllRunningAsError(
        versionId,
        "machine snapshot missing on restart",
      );
    });
    return;
  }
  try {
    await registry.acquire(versionId);
    logger.log("info", "warmed up machine on boot", { versionId });
  } catch (err) {
    logger.log("error", "failed to acquire machine on boot", {
      versionId,
      err: err instanceof Error ? err.message : String(err),
    });
    // Corrupt snapshot: delete it so the next boot doesn't loop on the
    // same deserialization error, then mark the agents as error.
    await storage.withTransaction(async (tx) => {
      await tx.snapshots.delete(versionId);
      await tx.agents.markAllRunningAsError(
        versionId,
        "machine failed to load on restart (snapshot deleted)",
      );
    });
    return;
  }

  // Re-issue terminates for any agents that were mid-cancel when the
  // previous process died. Without this, those agents stay `cancelling`
  // forever — the engine knows they're being cancelled (the snapshot
  // captured that), but it has no event to drive the cleanup forward.
  //
  // Use `resumeCancellingOnBoot` (not `cancelAgent`) — the latter has an
  // expectedState=running gate that no-ops on `cancelling` rows
  // (BUG-01 fixed in 2026-05).
  //
  // We page through `agents.list` with the largest allowed page size so
  // a version with hundreds of cancelling agents doesn't get partially
  // recovered. The implementation cap is 500 (see storage list options).
  if (agents !== undefined) {
    const PAGE_SIZE = 500;
    let afterId: import("./storage/types.js").AgentId | undefined = undefined;
    while (true) {
      const rows = await storage.agents.list({ versionId, limit: PAGE_SIZE, afterId });
      if (rows.length === 0) break;
      for (const row of rows) {
        if (row.state !== "cancelling") continue;
        try {
          await agents.resumeCancellingOnBoot(row.id);
          logger.log("info", "re-issued terminate for cancelling agent", {
            versionId,
            agentId: row.id,
          });
        } catch (err) {
          logger.log("error", "failed to re-issue terminate on boot", {
            versionId,
            agentId: row.id,
            err: err instanceof Error ? err.message : String(err),
          });
        }
      }
      if (rows.length < PAGE_SIZE) break;
      afterId = rows[rows.length - 1]!.id;
    }
  }
}
