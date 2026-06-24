// Run queries. A run *is* the api root's delegation; the Layer 1 `delegations` row is the single source of
// truth for its outcome (state / result / error). The `runs` table is only a metadata sidecar (id = run
// delegation id, name, launch metadata, cancel reason). The API projects the two together — this row LEFT
// JOIN its delegation — so a run reflects the engine's durable state, even after a crash + recovery (the
// recovered actor drives the delegation to its terminal state; no in-actor promise is involved).

import { and, desc, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import {
  type DelegationState,
  delegations,
  type RunState,
  runs,
} from "../../db/tables/execution.js";
import type { Value } from "../../runtime/value/types.js";

/** A run as the API presents it — its metadata plus the outcome projected from its delegation. */
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

/** One run's metadata row LEFT JOIN its delegation (delegation columns are `null` until the run's root
 *  instance is created — a brief window right after launch — in which the run is simply still `running`). */
export interface RunProjectionRow {
  id: string;
  name: string;
  qualifiedName: string;
  snapshotId: string | null;
  argument: Value | null;
  cancelReason: string | null;
  createdAt: Date;
  delegationState: DelegationState | null;
  delegationResult: Value | null;
  delegationError: string | null;
  delegationUpdatedAt: Date | null;
}

/** Map a delegation's Layer 1 state to the API run state: a cancelled run is a `gone` delegation, a failed
 *  run a `failed` one; the rest coincide. */
export function delegationToRunState(state: DelegationState): RunState {
  switch (state) {
    case "running":
      return "running";
    case "cancelling":
      return "cancelling";
    case "done":
      return "done";
    case "gone":
      return "cancelled";
    case "failed":
      return "error";
  }
}

/** Project a run's metadata + its delegation outcome into the API view (a pure function — the testable
 *  heart of the read path). `result` is meaningful only for `done`, `errorMessage` only for `failed`, and
 *  `completedAt` only once the delegation reached a terminal state. */
export function projectRun(row: RunProjectionRow): RunView {
  const state =
    row.delegationState === null ? "running" : delegationToRunState(row.delegationState);
  const terminal = state === "done" || state === "error" || state === "cancelled";
  return {
    id: row.id,
    name: row.name,
    qualifiedName: row.qualifiedName,
    snapshotId: row.snapshotId,
    state,
    argument: row.argument,
    result: row.delegationState === "done" ? row.delegationResult : null,
    errorMessage: row.delegationState === "failed" ? row.delegationError : null,
    cancelReason: row.cancelReason,
    createdAt: row.createdAt,
    completedAt: terminal ? row.delegationUpdatedAt : null,
  };
}

/** The metadata + delegation columns one run projection reads (runs LEFT JOIN its delegation by id). */
const projectionColumns = {
  id: runs.id,
  name: runs.name,
  qualifiedName: runs.qualifiedName,
  snapshotId: runs.snapshotId,
  argument: runs.argument,
  cancelReason: runs.cancelReason,
  createdAt: runs.createdAt,
  delegationState: delegations.state,
  delegationResult: delegations.result,
  delegationError: delegations.errorMessage,
  delegationUpdatedAt: delegations.updatedAt,
};

export const runRepository = {
  /** Record a run's metadata sidecar. `id` is the run delegation id (the engine writes the delegation row
   *  itself, asynchronously, as the run's root instance is created). */
  async start(
    executor: Executor,
    input: {
      id: string;
      projectId: string;
      name: string;
      qualifiedName: string;
      snapshotId: string;
      argument: Value | null;
    },
  ): Promise<void> {
    await executor.insert(runs).values(input);
  },

  /** Record the user's cancel reason (the delegation records only the `gone` state, not the reason). */
  async setCancelReason(
    executor: Executor,
    projectId: string,
    runId: string,
    reason?: string,
  ): Promise<void> {
    await executor
      .update(runs)
      .set({ cancelReason: reason ?? null })
      .where(and(eq(runs.projectId, projectId), eq(runs.id, runId)));
  },

  async list(executor: Executor, projectId: string): Promise<RunView[]> {
    const rows = await executor
      .select(projectionColumns)
      .from(runs)
      .leftJoin(delegations, eq(delegations.id, runs.id))
      .where(eq(runs.projectId, projectId))
      .orderBy(desc(runs.createdAt));
    return rows.map(projectRun);
  },

  async get(executor: Executor, projectId: string, runId: string): Promise<RunView | undefined> {
    const [row] = await executor
      .select(projectionColumns)
      .from(runs)
      .leftJoin(delegations, eq(delegations.id, runs.id))
      .where(and(eq(runs.projectId, projectId), eq(runs.id, runId)))
      .limit(1);
    return row === undefined ? undefined : projectRun(row);
  },
};
