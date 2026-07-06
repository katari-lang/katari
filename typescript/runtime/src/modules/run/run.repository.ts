// Run queries. The `runs` row — the run instance's extension record (`id` = that instance's id) — is the
// single source of truth for a run: its launch metadata and its durable state / outcome (state / result /
// error / completedAt), written by the api reactor as the run advances. The run delegation row is pure live
// routing (deleted on terminal), so the read side never touches it; the API reads `runs` directly, and a
// run reflects the engine's durable state even after a crash + recovery.

import { and, asc, desc, eq, type SQL } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { type RunState, runEscalationsAudit, runs } from "../../db/tables/execution.js";
import { unsealFromStorage } from "../../runtime/actor/seal.js";
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
 *  is meaningful only for `done`, `errorMessage` only for `error`. The row's `argument` / `result` are the
 *  decrypted Values (the query unseals them before projecting); the service then redacts secrets at the wire. */
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

  async list(
    executor: Executor,
    projectId: string,
    filter: { state?: RunState; limit?: number } = {},
  ): Promise<RunView[]> {
    const conditions: SQL[] = [eq(runs.projectId, projectId)];
    if (filter.state !== undefined) {
      conditions.push(eq(runs.state, filter.state));
    }
    const query = executor
      .select(projectionColumns)
      .from(runs)
      .where(and(...conditions))
      .orderBy(desc(runs.createdAt));
    const rows = await (filter.limit === undefined ? query : query.limit(filter.limit));
    return rows.map((row) => projectRun(unsealRow(row)));
  },

  async get(executor: Executor, projectId: string, runId: string): Promise<RunView | undefined> {
    const [row] = await executor
      .select(projectionColumns)
      .from(runs)
      .where(and(eq(runs.projectId, projectId), eq(runs.id, runId)))
      .limit(1);
    return row === undefined ? undefined : projectRun(unsealRow(row));
  },

  /** A run's answered-escalation history, oldest first (a Q&A transcript). The caller scopes the run to
   *  its project first (the audit table keys by run alone), and the at-rest seal is undone here like a
   *  run's own argument / result. */
  async listEscalationAudit(executor: Executor, runId: string): Promise<RunEscalationAuditView[]> {
    const rows = await executor
      .select({
        escalationId: runEscalationsAudit.escalationId,
        question: runEscalationsAudit.question,
        answer: runEscalationsAudit.answer,
        answeredAt: runEscalationsAudit.answeredAt,
      })
      .from(runEscalationsAudit)
      .where(eq(runEscalationsAudit.runId, runId))
      .orderBy(asc(runEscalationsAudit.answeredAt));
    return rows.map((row) => ({
      escalationId: row.escalationId,
      question: unsealFromStorage(row.question),
      answer: unsealFromStorage(row.answer),
      answeredAt: row.answeredAt,
    }));
  },
};

/** One answered escalation of a run, as the API presents it. */
export interface RunEscalationAuditView {
  escalationId: string;
  question: Value | null;
  answer: Value | null;
  answeredAt: Date;
}

/** Decrypt a row's at-rest `argument` / `result` before projection (the inverse of the engine's seal-on-write). */
function unsealRow(row: RunRow): RunRow {
  return {
    ...row,
    argument: unsealFromStorage(row.argument),
    result: unsealFromStorage(row.result),
  };
}
