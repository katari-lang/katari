import { db } from "../../db/client.js";
import { NotFoundError } from "../../lib/errors.js";
import { facade } from "../../runtime/facade.js";
import { valueToJson } from "../../runtime/value/codec.js";
import { type RunView, runRepository } from "./run.repository.js";
import type { ListRunEventsQuery, ListRunsQuery, StartRunBody } from "./run.schema.js";
import {
  projectRunEvent,
  runEventsRepository,
  type TraceCursor,
  type TraceFilter,
} from "./run-events.repository.js";
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

  /** A project's runs, newest first, one page at a time. Returns the page plus the filtered `total` so
   *  the caller (the route) can advertise it (the `X-Total-Count` header the console's pager reads). */
  async list(projectId: string, query: ListRunsQuery = {}) {
    const { rows, total } = await runRepository.list(db, projectId, query);
    return { items: rows.map(toRunResponse), total };
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

  /** A run's execution trace, in one of two paging modes decided here, once: an `after` keyset means
   *  the tail a watcher / the CLI polls (no `total` — the hot path never reads it), anything else is
   *  the console's offset browse, whose response carries the filtered `total` for the pager. `state`
   *  rides along so one poll both extends the trace and tells the watcher whether the run is still
   *  live (mirroring the delegation tree's `{ state, tree }`). */
  async listEvents(projectId: string, runId: string, query: ListRunEventsQuery = {}) {
    const view = await runRepository.get(db, projectId, runId);
    if (view === undefined) {
      throw new NotFoundError(`run ${runId} not found`);
    }
    const { after, offset, limit, ...narrowing } = query;
    const filter: TraceFilter = { ...narrowing, limit: limit ?? 500 };
    const cursor: TraceCursor =
      after !== undefined ? { mode: "tail", after } : { mode: "browse", offset: offset ?? 0 };
    if (cursor.mode === "tail") {
      const rows = await runEventsRepository.tail(db, projectId, runId, cursor.after, filter);
      return { state: view.state, events: rows.map(projectRunEvent) };
    }
    const { rows, total } = await runEventsRepository.browse(
      db,
      projectId,
      runId,
      cursor.offset,
      filter,
    );
    return { state: view.state, events: rows.map(projectRunEvent), total };
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
