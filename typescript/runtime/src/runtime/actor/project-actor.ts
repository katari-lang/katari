// ProjectActor: the warm, per-project composition root. It wires three siblings together: the `Substrate`
// (the transactional bus — serial mailbox + the one atomic commit per turn, routing by `to`), the
// `CoreReactor` (the engine — instances, the delegation graph, the IR turns), and the `ApiReactor` (the
// user-facing management root — runs and escalations). It owns no engine state itself; it supplies the
// substrate's reactor registry and the domain half of reactivation, and bridges the out-of-loop entry points
// (in-process api commands, FFI completions) onto the serial bus. Everything is serial; concurrency is the
// ack model (a parent that fanned out several delegates resumes each branch as its delegateAck lands).

import type { QualifiedName } from "@katari-lang/types";
import type { PrimRunner } from "../engine/context.js";
import type { ReactorName } from "../event/types.js";
import type { ExternalRunner } from "../external/runner.js";
import {
  apiRootIdOf,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
} from "../ids.js";
import type { IrSource } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import { ApiReactor, type OpenEscalation } from "./api-reactor.js";
import { CoreReactor } from "./core-reactor.js";
import type { Persistence } from "./persistence.js";
import type { Reactor } from "./reactor.js";
import { Substrate } from "./substrate.js";

// The api root's run-result error and open-escalation shape live with the ApiReactor now; re-exported here
// so existing importers (tests, callers) keep their entry point.
export { type OpenEscalation, RunCancelledError } from "./api-reactor.js";

export interface ProjectActorDependencies {
  projectId: ProjectId;
  ir: IrSource;
  prims: PrimRunner;
  blobs: BlobStore;
  external: ExternalRunner;
  persistence: Persistence;
}

export class ProjectActor {
  private readonly projectId: ProjectId;
  /** The project's permanent `api` management root id (the issuer of run delegations / the sink of
   *  user-facing escalations). Derived from the project id — deterministic and stable across restarts. */
  private readonly apiRootId: InstanceId;
  private readonly persistence: Persistence;

  /** The engine reactor: instances, the delegation routing graph, the IR turns. */
  private readonly core: CoreReactor;
  /** The api management root reactor: the user-facing run / escalation logic. */
  private readonly api: ApiReactor;
  /** The bus: the serial mailbox + the one atomic commit per turn, routing inbound events by their `to`. */
  private readonly substrate: Substrate;

  constructor(dependencies: ProjectActorDependencies) {
    this.projectId = dependencies.projectId;
    this.apiRootId = apiRootIdOf(this.projectId);
    this.persistence = dependencies.persistence;
    this.core = new CoreReactor(
      this.projectId,
      dependencies.ir,
      dependencies.prims,
      dependencies.blobs,
      dependencies.external,
    );
    // The api root schedules each command (start / cancel / answer) onto the bus as a serial command turn;
    // the closure reads `this.substrate`, assigned just below, only when a command actually runs.
    this.api = new ApiReactor(this.apiRootId, {
      enqueue: (thunk) => this.substrate.enqueueCommand(this.api, thunk),
    });
    const registry: Record<ReactorName, Reactor> = { core: this.core, api: this.api };
    this.substrate = new Substrate(this.projectId, this.persistence, registry, {
      reactivate: () => this.reactivate(),
    });
    // FFI completions re-enter through the same serial mailbox as every other turn, as a core FFI turn.
    dependencies.external.onResult((result) =>
      this.substrate.submit(this.core, () => this.core.reactFfi(result)),
    );
  }

  // ─── api root commands (exposed for in-process callers; the logic lives in the ApiReactor) ──────────

  /** Start a run on the api root. The run id is the run delegation id (the durable handle), the `result`
   *  promise an in-process convenience. */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): { run: DelegationId; result: Promise<Value> } {
    return this.api.startRun(qualifiedName, snapshot, argument);
  }

  /** Request a run's cancellation (terminate cascade). A no-op in the engine if the run already finished. */
  cancelRun(run: DelegationId, reason?: string): void {
    this.api.cancelRun(run, reason);
  }

  /** Answer an open run-root escalation, resuming its suspended raiser. */
  answerEscalation(escalation: EscalationId, value: Value): Promise<void> {
    return this.api.answerEscalation(escalation, value);
  }

  /** The run-root escalations currently awaiting an answer. */
  listOpenEscalations(): OpenEscalation[] {
    return this.api.listOpenEscalations();
  }

  /** Activate a (possibly recovered) actor: reload persisted state and re-dispatch in-flight external work,
   *  without an inbound message to trigger it. Idempotent — the warm actor also self-activates on its first
   *  command; a host calls this on boot to resume a project whose process went down mid-flight. */
  async activate(): Promise<void> {
    await this.substrate.activate();
  }

  // ─── reactivation (the substrate's domain half) ─────────────────────────────────────────────────

  /** Lazily reload the project's persisted state on first use, splitting the snapshot across the reactors:
   *  the core reactor rebuilds its store + routing + the Layer 1 rows it owns; the api reactor rehydrates its
   *  user-facing open escalations and its live run delegations; the durable api root row is ensured; the
   *  undrained outbox is replayed into the mailbox; and in-flight external calls are re-dispatched. */
  private async reactivate(): Promise<void> {
    const snapshot = await this.persistence.loadProject(this.projectId);
    this.core.loadState(snapshot);
    // The core reactor decides which open escalations are user-facing (raised by a run root); the api reactor
    // rehydrates those so a run suspended awaiting a user's answer survives a restart.
    for (const open of this.core.userFacingOpenEscalations(snapshot.openEscalations)) {
      this.api.rehydrateOpenEscalation(open);
    }
    this.api.loadRuns(snapshot.liveDelegations);
    // The api management root is a permanent per-project fixture (not an engine instance). Ensure its durable
    // `instances` row exists so a run's delegation, whose caller is the api root, satisfies the caller FK.
    await this.persistence.ensureApiRoot(this.projectId, this.apiRootId);
    // Replay the undrained outbox: events produced before the crash but not yet consumed.
    for (const message of snapshot.pendingOutbox) {
      this.substrate.enqueueOutbox(message.event, message.seq);
    }
    // NB: the substrate marks the project loaded only after this whole method (incl. the resume below)
    // resolves, so a resume failure does not leave it loaded-but-half-initialised — the next caller retries.
    await this.core.resumeInFlightExternals();
  }
}
