// ProjectActor: the warm, per-project composition root. It wires three siblings together: the `Substrate`
// (the transactional bus — serial mailbox + the one atomic commit per turn), the `CoreReactor` (the engine —
// instances, the delegation graph, the IR turns), and the `ApiReactor` (the user-facing management root —
// runs and escalations). It owns no engine state itself; it is the substrate's host (supplying `dispatch` +
// the domain half of `reactivate`) and routes each inbound event **purely by its `to`** (`reactors[to]`) — no
// api|core decision, since the emitter stamped the destination. Everything is serial; concurrency is the ack
// model (a parent that fanned out several delegates resumes each branch as its delegateAck lands).
//
// Until the FFI reactor lands, FFI completions still route to the core reactor (`reactFfi`) as an ephemeral
// trigger (they carry no `to`).

import type { QualifiedName } from "@katari-lang/types";
import type { PrimRunner } from "../engine/context.js";
import type { ActorMessage, FfiResult, ReactorName } from "../event/types.js";
import { isFfiResult } from "../event/types.js";
import type { ExternalRunner } from "../external/runner.js";
import {
  apiRootIdOf,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  type OutboxSeq,
  type ProjectId,
  type SnapshotId,
} from "../ids.js";
import type { IrSource } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import { type ApiHost, ApiReactor, type OpenEscalation } from "./api-reactor.js";
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

  /** The bus: the serial mailbox + the one atomic commit per turn. This actor is its host — it supplies the
   *  routing (`dispatch`) and the domain half of reactivation. */
  private readonly substrate: Substrate;
  /** The engine reactor: instances, the delegation routing graph, the IR turns. */
  private readonly core: CoreReactor;
  /** The api management root reactor: the user-facing run / escalation logic. */
  private readonly api: ApiReactor;
  /** The reactor registry, keyed by name: the substrate dispatches an inbound event purely by its `to`. */
  private readonly reactors: Record<ReactorName, Reactor>;

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
      this.apiRootId,
    );
    this.substrate = new Substrate(this.projectId, this.persistence, {
      reactivate: () => this.reactivate(),
      dispatch: (message, seq) => this.handle(message, seq),
    });
    this.api = new ApiReactor(this.apiHost());
    this.reactors = { core: this.core, api: this.api };
    // FFI completions re-enter through the same serial mailbox as every other external message.
    dependencies.external.onResult((result) => this.feed(result));
  }

  /** The narrow substrate / routing slice the api root drives: load + commit (the bus) and the run
   *  delegation's routing edge (the core reactor owns the graph). Built once; the arrows close over the
   *  siblings. */
  private apiHost(): ApiHost {
    return {
      apiRootId: this.apiRootId,
      ensureLoaded: () => this.substrate.ensureLoaded(),
      commit: (reaction, consumed) => this.substrate.commit(reaction, consumed),
      openRunDelegation: (delegation) => this.core.openRunDelegation(delegation),
      closeRunDelegation: (delegation) => this.core.closeRunDelegation(delegation),
    };
  }

  // ─── api root commands (exposed for in-process callers; the logic lives in the ApiReactor) ──────────

  /** Start a run on the api root. The actor exposes it for in-process callers (tests / the façade); the
   *  run id is the run delegation id (the durable handle), the `result` promise an in-process convenience. */
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

  /** Feed an FFI completion into the serial loop. FFI completions are ephemeral (not outbox events — they
   *  are re-derived from the `ExternalThread` rows on recovery), so they carry no outbox row (`seq` null). */
  feed(result: FfiResult): void {
    this.substrate.feed(result, null);
  }

  /** Activate a (possibly recovered) actor: reload persisted state and re-dispatch in-flight external
   *  work, without an inbound message to trigger it. Idempotent — the warm actor also self-activates on
   *  its first `feed`; a host calls this on boot to resume a project whose process went down mid-flight. */
  async activate(): Promise<void> {
    await this.substrate.activate();
  }

  // ─── reactivation (the substrate's domain half) ─────────────────────────────────────────────────

  /** Lazily reload the project's persisted state on first use: the core reactor rebuilds its store + routing
   *  graph, the api reactor rehydrates its user-facing open escalations, the durable api root row is ensured,
   *  the undrained outbox is replayed into the mailbox, and in-flight external calls are re-dispatched. */
  private async reactivate(): Promise<void> {
    const snapshot = await this.persistence.loadProject(this.projectId);
    this.core.loadState(snapshot);
    // A run suspended awaiting a user's answer must survive a restart; the core reactor decides which open
    // escalations are user-facing (raised by a run root) and the run delegation each belongs to.
    for (const open of this.core.userFacingOpenEscalations(snapshot.openEscalations)) {
      this.api.rehydrateOpenEscalation(open);
    }
    // The api management root is a permanent per-project Layer 1 fixture, not an engine instance. Ensure its
    // durable `instances` row exists (so a run's `delegation-open`, whose caller is the api root, satisfies
    // the caller FK).
    await this.persistence.ensureApiRoot(this.projectId, this.apiRootId);
    // Replay the undrained outbox into the mailbox: events produced before the crash but not yet consumed
    // (the core reactor re-established their delegation callers in `loadState` above).
    for (const message of snapshot.pendingOutbox) {
      this.substrate.enqueue(message.event, message.seq);
    }
    // NB: the substrate marks the project loaded only after this whole method (incl. the resume below)
    // resolves, so a resume failure does not leave it loaded-but-half-initialised — the next caller retries.
    await this.core.resumeInFlightExternals();
  }

  // ─── dispatch (the substrate's routing half) ────────────────────────────────────────────────────

  /** Route one inbound message to the reactor that owns it, run its turn, commit, then run its post-commit
   *  side effect. Self-routing: the destination is the event's `to` (the emitter stamped it) — there is no
   *  api|core decision here, just a registry lookup. A reactor reacts (mutating its warm state and producing
   *  sends), the substrate commits the Reaction, then `afterCommit` settles durable-first (the api root's
   *  result promise; a no-op for core). An FFI completion is an ephemeral core trigger (no `to`): it resumes
   *  its core instance directly, and yields a `null` reaction when its instance is already gone (no row). */
  private async handle(message: ActorMessage, seq: OutboxSeq | null): Promise<void> {
    if (isFfiResult(message)) {
      const reaction = await this.core.reactFfi(message);
      if (reaction !== null) await this.substrate.commit(reaction, seq);
      return;
    }
    const reactor = this.reactors[message.to];
    const reaction = await reactor.react(message);
    await this.substrate.commit(reaction, seq);
    reactor.afterCommit(message, reaction);
  }
}
