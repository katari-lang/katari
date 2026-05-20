// Boot recovery wrapper.
//
// 大半は `Orchestrator.recoverOnBoot()` がやる: running agent を持つ
// snapshot を列挙して subprocess を re-spawn し、`restored` IPC で
// in-flight delegationId を通知。
//
// 加えて: `cancelling` 状態で停止していた agent に対して terminate を
// 再投入する。これは ApiModule.cancelAgent と同じ振る舞いを Orchestrator
// に呼び戻させるだけ。

import type { Logger } from "@katari-lang/runtime";
import type { Orchestrator } from "./orchestrator.js";
import type { Storage } from "./storage/types.js";

export async function recoverOnBoot(
  storage: Storage,
  orchestrator: Orchestrator,
  logger: Logger,
): Promise<void> {
  await orchestrator.recoverOnBoot();

  // Re-issue terminate for cancelling agents. Filter by `state` in SQL
  // so a snapshot with millions of succeeded rows doesn't drag the
  // recovery loop through them just to find the handful in cancelling.
  const snapshotIds = await storage.agents.listRunningSnapshotIds();
  for (const snapshotId of snapshotIds) {
    let afterId: import("./storage/types.js").AgentId | undefined;
    while (true) {
      const rows = await storage.agents.list({
        snapshotId,
        state: "cancelling",
        afterId,
        limit: 500,
      });
      if (rows.length === 0) break;
      for (const row of rows) {
        try {
          await orchestrator.tick(snapshotId, async (ctx) => {
            await ctx.api.cancelAgent({ bus: ctx.bus, agentId: row.id });
          });
        } catch (err) {
          logger.log("warn", "recovery: failed to re-issue terminate", {
            agentId: row.id,
            err: err instanceof Error ? err.message : String(err),
          });
        }
      }
      if (rows.length < 500) break;
      afterId = rows[rows.length - 1]!.id;
    }
  }
}
