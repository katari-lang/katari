import { db } from "../../db/client.js";
import type { runs } from "../../db/tables/execution.js";
import { NotFoundError } from "../../lib/errors.js";
import { facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";
import { runRepository } from "./run.repository.js";
import type { StartRunBody } from "./run.schema.js";

type RunRow = typeof runs.$inferSelect;

/** The wire shape of a run record: the tagged `argument` / `result` `Value`s are rendered back to Json. */
function toRunResponse(row: RunRow) {
  return {
    id: row.id,
    name: row.name,
    qualifiedName: row.qualifiedName,
    snapshotId: row.snapshotId,
    state: row.state,
    argument: row.argument === null ? null : valueToJson(row.argument),
    result: row.result === null ? null : valueToJson(row.result),
    errorMessage: row.errorMessage,
    cancelReason: row.cancelReason,
    createdAt: row.createdAt,
    completedAt: row.completedAt,
  };
}

export const runService = {
  start(projectId: string, body: StartRunBody): Promise<{ runId: string }> {
    return facade.startRun({ projectId, ...body });
  },

  cancel(projectId: string, runId: string, reason?: string): Promise<void> {
    return facade.cancel({ projectId, runId, reason });
  },

  async list(projectId: string) {
    const rows = await runRepository.list(db, projectId);
    return rows.map(toRunResponse);
  },

  async getById(projectId: string, runId: string) {
    const [row] = await runRepository.get(db, projectId, runId);
    if (row === undefined) {
      throw new NotFoundError(`run ${runId} not found`);
    }
    return toRunResponse(row);
  },
};
