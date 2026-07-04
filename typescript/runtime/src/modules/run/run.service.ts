import { db } from "../../db/client.js";
import { NotFoundError } from "../../lib/errors.js";
import { facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";
import { type RunView, runRepository } from "./run.repository.js";
import type { ListRunsQuery, StartRunBody } from "./run.schema.js";
import { runTreeRepository } from "./run-tree.repository.js";

/** The wire shape of a run: its projected view with the tagged `argument` / `result` `Value`s rendered
 *  back to Json. (The view's state / result / error are projected from the run's Layer 1 delegation.) */
function toRunResponse(view: RunView) {
  return {
    id: view.id,
    name: view.name,
    qualifiedName: view.qualifiedName,
    snapshotId: view.snapshotId,
    state: view.state,
    // The user-facing boundary: a secret in a run argument / result is redacted, never observed.
    argument: view.argument === null ? null : valueToJson(view.argument, "redact"),
    result: view.result === null ? null : valueToJson(view.result, "redact"),
    errorMessage: view.errorMessage,
    cancelReason: view.cancelReason,
    createdAt: view.createdAt,
    completedAt: view.completedAt,
  };
}

export const runService = {
  start(projectId: string, body: StartRunBody): Promise<{ runId: string }> {
    return facade.startRun({ projectId, ...body });
  },

  cancel(projectId: string, runId: string, reason?: string): Promise<void> {
    return facade.cancel({ projectId, runId, reason });
  },

  async list(projectId: string, query: ListRunsQuery = {}) {
    const views = await runRepository.list(db, projectId, query);
    return views.map(toRunResponse);
  },

  async getById(projectId: string, runId: string) {
    const view = await runRepository.get(db, projectId, runId);
    if (view === undefined) {
      throw new NotFoundError(`run ${runId} not found`);
    }
    return toRunResponse(view);
  },

  /** A run's live delegation tree — `null` once the run is terminal (the routing rows are deleted with
   *  it). The nodes carry no argument / result values, so there is nothing to redact at this boundary. */
  async getDelegationTree(projectId: string, runId: string) {
    const view = await runRepository.get(db, projectId, runId);
    if (view === undefined) {
      throw new NotFoundError(`run ${runId} not found`);
    }
    return { state: view.state, tree: await runTreeRepository.get(db, projectId, runId) };
  },

  /** A run's answered-escalation transcript. Open escalations are the escalation resource's concern;
   *  this is the durable history the audit table keeps after each answer. */
  async listEscalationAudit(projectId: string, runId: string) {
    const view = await runRepository.get(db, projectId, runId);
    if (view === undefined) {
      throw new NotFoundError(`run ${runId} not found`);
    }
    const entries = await runRepository.listEscalationAudit(db, runId);
    return entries.map((entry) => ({
      escalationId: entry.escalationId,
      // The user-facing boundary: a secret in a question / answer is redacted, never observed.
      question: entry.question === null ? null : valueToJson(entry.question, "redact"),
      answer: entry.answer === null ? null : valueToJson(entry.answer, "redact"),
      answeredAt: entry.answeredAt,
    }));
  },
};
