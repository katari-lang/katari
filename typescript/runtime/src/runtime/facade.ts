// Engine façade: the single entry from the stateless HTTP services into the stateful, per-project
// engine/actor (see docs/2026-06-15-runtime-domain-model.md §5). v0.1 freezes the signatures so the
// engine-backed resources (run / escalation) compile against a fixed boundary; the bodies arrive with
// the engine (implementation plan Phase 2+). Until then every call throws, so those resources return
// a clean 501 instead of pretending to work.
//
// Boundary note: the wire carries raw `Json` (`argument` / `value`), but the engine and its persisted
// columns speak the tagged `Value` model (e.g. `{ kind: "integer", value: 5 }`, not bare `5`). This
// façade is where that `Json → Value` conversion (and `Value → Json` on the way out) must happen when
// the engine lands; the raw `Json` must NOT be written straight into a `Value`-typed column.

import type { Json } from "@katari-lang/types";
import { NotImplementedError } from "../lib/errors.js";

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

export const facade: RuntimeFacade = {
  startRun() {
    throw new NotImplementedError("Run execution is not implemented yet (engine pending).");
  },
  cancel() {
    throw new NotImplementedError("Run cancellation is not implemented yet (engine pending).");
  },
  answerEscalation() {
    throw new NotImplementedError("Escalation answering is not implemented yet (engine pending).");
  },
};
