// Drizzle queries for the `runs` management record (1:1 with a run's root instance). The engine
// executes the run; this row tracks its lifecycle (running -> done / error) and its result for the API.

import { and, desc, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { runs } from "../../db/tables/execution.js";
import type { Value } from "../../runtime/value/types.js";

export const runRepository = {
  /** Open a run row in the `running` state; returns its id. */
  async start(
    executor: Executor,
    input: {
      projectId: string;
      name: string;
      qualifiedName: string;
      snapshotId: string;
      argument: Value | null;
    },
  ): Promise<{ id: string }> {
    const [row] = await executor
      .insert(runs)
      .values({
        projectId: input.projectId,
        name: input.name,
        qualifiedName: input.qualifiedName,
        snapshotId: input.snapshotId,
        argument: input.argument,
        state: "running",
      })
      .returning({ id: runs.id });
    if (row === undefined) {
      throw new Error("failed to insert run row");
    }
    return row;
  },

  /** Settle a run terminally: `done` with its result, `error` with its message, or `cancelled` with its
   *  reason (the engine confirmed the terminate cascade). */
  async settle(
    executor: Executor,
    runId: string,
    outcome:
      | { state: "done"; result: Value | null }
      | { state: "error"; errorMessage: string }
      | { state: "cancelled"; cancelReason?: string },
  ): Promise<void> {
    const completedAt = new Date();
    const patch =
      outcome.state === "done"
        ? { state: "done" as const, result: outcome.result, completedAt }
        : outcome.state === "error"
          ? { state: "error" as const, errorMessage: outcome.errorMessage, completedAt }
          : {
              state: "cancelled" as const,
              cancelReason: outcome.cancelReason ?? null,
              completedAt,
            };
    await executor.update(runs).set(patch).where(eq(runs.id, runId));
  },

  /** Mark a still-running run as `cancelling` (its terminate was requested). A no-op on an already-settled
   *  run, so a late cancel cannot resurrect it. */
  async markCancelling(executor: Executor, runId: string, reason?: string): Promise<void> {
    await executor
      .update(runs)
      .set({ state: "cancelling", cancelReason: reason ?? null })
      .where(and(eq(runs.id, runId), eq(runs.state, "running")));
  },

  list(executor: Executor, projectId: string) {
    return executor
      .select()
      .from(runs)
      .where(eq(runs.projectId, projectId))
      .orderBy(desc(runs.createdAt));
  },

  get(executor: Executor, projectId: string, runId: string) {
    return executor
      .select()
      .from(runs)
      .where(and(eq(runs.projectId, projectId), eq(runs.id, runId)))
      .limit(1);
  },
};
