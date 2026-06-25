// ProjectActor: the warm, per-project composition root. It wires three siblings together: the `Substrate`
// (the transactional bus — serial mailbox + the one atomic commit per turn, routing by `to`), the
// `CoreReactor` (the engine — instances, the delegation graph, the IR turns), and the `ApiReactor` (the
// user-facing management root — runs and escalations). It owns no engine state itself; it supplies the
// substrate's reactor registry and the domain half of reactivation, and bridges the out-of-loop entry points
// (in-process api commands, FFI completions) onto the serial bus. Everything is serial; concurrency is the
// ack model (a parent that fanned out several delegates resumes each branch as its delegateAck lands).

import type { QualifiedName } from "@katari-lang/types";
import type { PrimRunner } from "../engine/context.js";
import { createProjectStore } from "../engine/store.js";
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
import { ResourcePool } from "./resource-pool.js";
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
  /** The shared scope/blob resource — reset together with the reactors on a poisoned commit. */
  private readonly pool: ResourcePool;
  /** The bus: the serial mailbox + the one atomic commit per turn, routing inbound events by their `to`. */
  private readonly substrate: Substrate;

  constructor(dependencies: ProjectActorDependencies) {
    this.projectId = dependencies.projectId;
    this.apiRootId = apiRootIdOf(this.projectId);
    this.persistence = dependencies.persistence;
    // The shared scope store + the pool that wraps it: the engine reads / writes scopes in place, while every
    // reactor reowns through the same pool (so a run result crosses from a core instance to the api root).
    const store = createProjectStore();
    this.pool = new ResourcePool(this.projectId, store);
    const pool = this.pool;
    this.core = new CoreReactor(
      this.projectId,
      dependencies.ir,
      dependencies.prims,
      dependencies.blobs,
      dependencies.external,
      store,
      pool,
    );
    // The api root schedules each command (start / cancel / answer) onto the bus as a serial command turn;
    // the closure reads `this.substrate`, assigned just below, only when a command actually runs.
    this.api = new ApiReactor(
      this.apiRootId,
      { enqueue: (thunk) => this.substrate.enqueueCommand(this.api, thunk) },
      pool,
    );
    const registry: Record<ReactorName, Reactor> = { core: this.core, api: this.api };
    this.substrate = new Substrate(this.projectId, this.persistence, registry, pool, {
      reactivate: () => this.reactivate(),
      onPoison: (error) =>
        this.api.poisonRunPromises(
          error instanceof Error
            ? new Error(`run tracking reset after a commit failure: ${error.message}`)
            : new Error("run tracking reset after a commit failure; query the run's durable state"),
        ),
    });
    // FFI completions re-enter through the same serial mailbox as every other turn, as a core FFI turn.
    dependencies.external.onResult((result) =>
      this.substrate.submit(this.core, () => this.core.reactFfi(result)),
    );
  }

  // ─── api root commands (exposed for in-process callers; the logic lives in the ApiReactor) ──────────

  /** Start a run on the api root. The run id is the run delegation id (the durable handle); `result` is an
   *  in-process convenience; `started` resolves once the launch (delegation + `runs` metadata + delegate) is
   *  durably committed. `name` is the run's human label (defaults to the qualified name). */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
    name?: string,
  ): { run: DelegationId; result: Promise<Value>; started: Promise<void> } {
    return this.api.startRun(qualifiedName, snapshot, argument, name ?? qualifiedName);
  }

  /** Request a run's cancellation (terminate cascade + durable cancel reason). Resolves once the cancel
   *  commit is durable; a no-op in the engine if the run already finished. */
  cancelRun(run: DelegationId, reason?: string): Promise<void> {
    return this.api.cancelRun(run, reason);
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

  /** Lazily reload the project's persisted state on first use: each reactor pulls only the rows it owns from
   *  the loader (core its engine graph + routing + its delegations/escalations; the api root its run
   *  delegations + answerable escalations) — no central blob, no cross-reactor classification. The undrained
   *  outbox is replayed into the mailbox; in-flight external calls are re-dispatched. The api management
   *  root's durable `instances` row is ensured by the api reactor in each run's `delegate` commit (it owns
   *  that row), so reactivation only reads. */
  private async reactivate(): Promise<void> {
    // Reactivation is idempotent and is the recovery path after a poisoned commit too: drop any warm state
    // first (a cold start clears empty state — a no-op), so reloading never accumulates stale routing.
    this.core.reset();
    this.api.reset();
    this.pool.reset();
    await this.persistence.load(this.projectId, async (loader) => {
      await this.core.load(loader);
      await this.api.load(loader);
      // Replay the undrained outbox: events produced before the crash but not yet consumed.
      for (const message of await loader.outbox()) {
        this.substrate.enqueueOutbox(message.event, message.seq);
      }
    });
    // NB: the substrate marks the project loaded only after this whole method (incl. the resume below)
    // resolves, so a resume failure does not leave it loaded-but-half-initialised — the next caller retries.
    await this.core.resumeInFlightExternals();
  }
}
