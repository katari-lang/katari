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

  /** Settle a run: `done` with its result, or `error` with its message. */
  async settle(
    executor: Executor,
    runId: string,
    outcome: { state: "done"; result: Value | null } | { state: "error"; errorMessage: string },
  ): Promise<void> {
    await executor
      .update(runs)
      .set(
        outcome.state === "done"
          ? { state: "done", result: outcome.result, completedAt: new Date() }
          : { state: "error", errorMessage: outcome.errorMessage, completedAt: new Date() },
      )
      .where(eq(runs.id, runId));
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
