// Run queries. The `runs` row is the single source of truth for a run — its launch metadata and its durable
// state / outcome (state / result / error / completedAt), written by the api root as the run advances. The
// run delegation row is pure live routing (deleted on terminal), so the read side never touches it; the API
// reads `runs` directly, and a run reflects the engine's durable state even after a crash + recovery.

import { and, desc, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { type RunState, runs } from "../../db/tables/execution.js";
import type { Value } from "../../runtime/value/types.js";

/** A run as the API presents it — its metadata plus its durable state / outcome. */
export interface RunView {
  id: string;
  name: string;
  qualifiedName: string;
  snapshotId: string | null;
  state: RunState;
  argument: Value | null;
  result: Value | null;
  errorMessage: string | null;
  cancelReason: string | null;
  createdAt: Date;
  completedAt: Date | null;
}

/** One `runs` row, as the projection reads it. */
export interface RunRow {
  id: string;
  name: string;
  qualifiedName: string;
  snapshotId: string | null;
  state: RunState;
  argument: Value | null;
  result: Value | null;
  errorMessage: string | null;
  cancelReason: string | null;
  createdAt: Date;
  completedAt: Date | null;
}

/** Project a `runs` row into the API view (a pure function — the testable heart of the read path). `result`
 *  is meaningful only for `done`, `errorMessage` only for `error`. */
export function projectRun(row: RunRow): RunView {
  return {
    id: row.id,
    name: row.name,
    qualifiedName: row.qualifiedName,
    snapshotId: row.snapshotId,
    state: row.state,
    argument: row.argument,
    result: row.state === "done" ? row.result : null,
    errorMessage: row.state === "error" ? row.errorMessage : null,
    cancelReason: row.cancelReason,
    createdAt: row.createdAt,
    completedAt: row.completedAt,
  };
}

/** The columns one run projection reads. */
const projectionColumns = {
  id: runs.id,
  name: runs.name,
  qualifiedName: runs.qualifiedName,
  snapshotId: runs.snapshotId,
  state: runs.state,
  argument: runs.argument,
  result: runs.result,
  errorMessage: runs.errorMessage,
  cancelReason: runs.cancelReason,
  createdAt: runs.createdAt,
  completedAt: runs.completedAt,
};

export const runRepository = {
  // The `runs` row (launch metadata, state / outcome, cancel reason) is written by the engine, atomically
  // with the run's events (see `ApiReactor` / `PersistenceTx.putRun` / `setRunOutcome`), not here — this
  // module is the read side only (the projection + the list / get queries).

  async list(executor: Executor, projectId: string): Promise<RunView[]> {
    const rows = await executor
      .select(projectionColumns)
      .from(runs)
      .where(eq(runs.projectId, projectId))
      .orderBy(desc(runs.createdAt));
    return rows.map(projectRun);
  },

  async get(executor: Executor, projectId: string, runId: string): Promise<RunView | undefined> {
    const [row] = await executor
      .select(projectionColumns)
      .from(runs)
      .where(and(eq(runs.projectId, projectId), eq(runs.id, runId)))
      .limit(1);
    return row === undefined ? undefined : projectRun(row);
  },
};
