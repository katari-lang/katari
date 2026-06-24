// Engine façade: the single entry from the stateless HTTP services into the stateful, per-project
// engine. It owns the warm `RuntimeHost` (module scope, so a project's actor stays warm across requests),
// converts the wire's raw `Json` to/from the engine's tagged `Value`, and orchestrates the run lifecycle:
// resolve the snapshot, open a `runs` row, kick the run off on the host, and settle the row when it
// completes (done / error) in the background — the HTTP call returns the run id immediately.

import { createAgentName, type Json } from "@katari-lang/types";
import { eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { projects } from "../db/tables/projects.js";
import { NotFoundError } from "../lib/errors.js";
import { runRepository } from "../modules/run/run.repository.js";
import { DbIrSource } from "./actor/db-ir-source.js";
import { DbPersistence } from "./actor/db-persistence.js";
import { type OpenEscalation, RunCancelledError } from "./actor/project-actor.js";
import { PrimRegistry } from "./engine/prims.js";
import { StubExternalRunner } from "./external/runner.js";
import { RuntimeHost } from "./host.js";
import type { EscalationId, ProjectId, SnapshotId } from "./ids.js";
import { jsonToValue, valueToJson } from "./value/codec.js";

export interface StartRunInput {
  projectId: string;
  /** The agent to run; resolved against the chosen snapshot's manifest. */
  qualifiedName: string;
  /** The snapshot to pin the run to. Defaults to the project head when omitted. */
  snapshotId?: string;
  argument?: Json;
  /** A human label for the run record; defaults to `qualifiedName`. */
  name?: string;
}

export interface CancelRunInput {
  projectId: string;
  runId: string;
  reason?: string;
}

export interface AnswerEscalationInput {
  projectId: string;
  escalationId: string;
  value: Json;
}

/** A run-root escalation awaiting an answer, in the wire's `Json` shape. */
export interface OpenEscalationView {
  id: string;
  request: string;
  argument: Json | null;
}

/** The stateful core, behind a thin async interface the HTTP layer depends on. */
export interface RuntimeFacade {
  /** Summon the run's root instance and return its durable run record id. */
  startRun(input: StartRunInput): Promise<{ runId: string }>;
  /** Request cancellation of a running run (terminate cascade). */
  cancel(input: CancelRunInput): Promise<void>;
  /** Answer a user-facing escalation, resuming the raiser. */
  answerEscalation(input: AnswerEscalationInput): Promise<void>;
  /** The run-root escalations on a project awaiting an answer. */
  listOpenEscalations(projectId: string): OpenEscalationView[];
}

// The warm host: one per process, backed by the DB (IR module store + engine-graph persistence). A
// project's actor is created lazily and kept warm. FFI / env are not wired yet (stub runner, pure prims).
const host = new RuntimeHost({
  ir: new DbIrSource(db),
  persistence: new DbPersistence(db),
  prims: new PrimRegistry(),
  externalFactory: () => new StubExternalRunner(),
});

/** Resolve the snapshot a run pins: the explicit one, or the project's live head. */
async function resolveSnapshot(projectId: string, snapshotId?: string): Promise<string> {
  if (snapshotId !== undefined) return snapshotId;
  const [project] = await db
    .select({ head: projects.headSnapshotId })
    .from(projects)
    .where(eq(projects.id, projectId))
    .limit(1);
  if (project?.head == null) {
    throw new NotFoundError("project has no live snapshot to run; deploy one or pass snapshotId");
  }
  return project.head;
}

export const facade: RuntimeFacade = {
  async startRun(input) {
    const snapshotId = await resolveSnapshot(input.projectId, input.snapshotId);
    const argument = input.argument !== undefined ? jsonToValue(input.argument) : null;
    const run = await runRepository.start(db, {
      projectId: input.projectId,
      name: input.name ?? input.qualifiedName,
      qualifiedName: input.qualifiedName,
      snapshotId,
      argument,
    });
    // Execute on the host and settle the run row when it finishes; the HTTP call does not wait. A cancel
    // surfaces as a `RunCancelledError` rejection, settled as `cancelled` (vs a genuine `error`).
    void host
      .startRun(
        input.projectId as ProjectId,
        run.id,
        createAgentName(input.qualifiedName),
        snapshotId as SnapshotId,
        argument,
      )
      .then((result) => runRepository.settle(db, run.id, { state: "done", result }))
      .catch((error: unknown) =>
        error instanceof RunCancelledError
          ? runRepository.settle(db, run.id, { state: "cancelled", cancelReason: error.reason })
          : runRepository.settle(db, run.id, {
              state: "error",
              errorMessage: error instanceof Error ? error.message : String(error),
            }),
      );
    return { runId: run.id };
  },

  async cancel(input) {
    // Mark the run cancelling, then ask the host to terminate its root instance. The terminate cascade
    // confirms back as a `RunCancelledError`, which the run's background settler records as `cancelled`.
    await runRepository.markCancelling(db, input.runId, input.reason);
    host.cancelRun(input.projectId as ProjectId, input.runId, input.reason);
  },

  async answerEscalation(input) {
    host.answerEscalation(
      input.projectId as ProjectId,
      input.escalationId as EscalationId,
      jsonToValue(input.value),
    );
  },

  listOpenEscalations(projectId) {
    return host.listOpenEscalations(projectId as ProjectId).map((open: OpenEscalation) => ({
      id: open.escalation,
      request: open.request,
      argument: open.argument === null ? null : valueToJson(open.argument),
    }));
  },
};
