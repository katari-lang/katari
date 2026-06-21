// Engine façade: the single entry from the stateless HTTP services into the stateful, per-project
// engine. It owns the warm `RuntimeHost` (module scope, so a project's actor stays warm across requests),
// converts the wire's raw `Json` to/from the engine's tagged `Value`, and orchestrates the run lifecycle:
// resolve the snapshot, open a `runs` row, kick the run off on the host, and settle the row when it
// completes (done / error) in the background — the HTTP call returns the run id immediately.

import { createAgentName, type Json } from "@katari-lang/types";
import { eq } from "drizzle-orm";
import { db } from "../db/client.js";
import { projects } from "../db/tables/projects.js";
import { NotFoundError, NotImplementedError } from "../lib/errors.js";
import { runRepository } from "../modules/run/run.repository.js";
import { DbIrSource } from "./actor/db-ir-source.js";
import { DbPersistence } from "./actor/db-persistence.js";
import { PrimRegistry } from "./engine/prims.js";
import { StubExternalRunner } from "./external/runner.js";
import { RuntimeHost } from "./host.js";
import type { ProjectId, SnapshotId } from "./ids.js";
import { jsonToValue } from "./value/codec.js";

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

/** The stateful core, behind a thin async interface the HTTP layer depends on. */
export interface RuntimeFacade {
  /** Summon the run's root instance and return its durable run record id. */
  startRun(input: StartRunInput): Promise<{ runId: string }>;
  /** Request cancellation of a running run (terminate cascade). */
  cancel(input: CancelRunInput): Promise<void>;
  /** Answer a user-facing escalation, resuming the raiser. */
  answerEscalation(input: AnswerEscalationInput): Promise<void>;
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
    // Execute on the host and settle the run row when it finishes; the HTTP call does not wait.
    void host
      .startRun(
        input.projectId as ProjectId,
        createAgentName(input.qualifiedName),
        snapshotId as SnapshotId,
        argument,
      )
      .then((result) => runRepository.settle(db, run.id, { state: "done", result }))
      .catch((error: unknown) =>
        runRepository.settle(db, run.id, {
          state: "error",
          errorMessage: error instanceof Error ? error.message : String(error),
        }),
      );
    return { runId: run.id };
  },

  cancel() {
    // Cancellation routes a `terminate` to the run's root instance; the host does not yet expose a run
    // handle for it (the run delegation is internal). Wired with run-handle support.
    throw new NotImplementedError("Run cancellation is not wired yet.");
  },

  answerEscalation() {
    // Answering routes an `escalateAck` to the run's suspended escalation; this needs the engine to keep
    // an unhandled run-root request open (rather than failing the run) — a follow-up.
    throw new NotImplementedError("Escalation answering is not wired yet.");
  },
};
