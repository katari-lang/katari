// ProjectActor: the warm, per-project composition root. It wires three siblings together and routes between
// them: the `Substrate` (the transactional bus — serial mailbox + the one atomic commit per turn), the
// `CoreReactor` (the engine — instances, the delegation graph, the IR turns), and the `ApiReactor` (the
// user-facing management root — runs and escalations). It owns no engine state itself; it is the substrate's
// host (supplying `dispatch` + the domain half of `reactivate`) and the dispatcher that decides, for each
// inbound event, which reactor reacts. Everything is serial; concurrency is the ack model (a parent that
// fanned out several delegates resumes each branch as its delegateAck lands).
//
// Until the FFI reactor lands (R3), FFI completions still route to the core reactor (`reactFfi`); and the
// api|core routing decision is a sentinel comparison (a run delegation's caller is the api root) rather than
// an event's reactor-name address.

import type { QualifiedName } from "@katari-lang/types";
import type { PrimRunner } from "../engine/context.js";
import type { ActorMessage, ExternalEvent, FfiResult } from "../event/types.js";
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
import { Substrate } from "./substrate.js";
import type { Reaction } from "./turn-commit.js";

/** What routing one inbound message produced: the Reaction the substrate commits (`null` = nothing to
 *  commit — a late FFI completion whose instance is already gone, which also carries no outbox row), plus an
 *  optional strictly-post-commit side effect (the api root settling its in-process result promise). */
interface Routed {
  reaction: Reaction | null;
  after?: () => void;
}

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

  /** Route one inbound message to the reactor that owns it and run its turn in memory, returning the Reaction
   *  the substrate then commits (with the inbound row `seq`) plus any post-commit side effect. This is the
   *  single commit funnel: every turn — core or api — flows `route → substrate.commit → after`. A late FFI
   *  completion whose instance is gone yields a `null` reaction (and carries no row), so nothing commits. */
  private async handle(message: ActorMessage, seq: OutboxSeq | null): Promise<void> {
    const { reaction, after } = await this.route(message);
    if (reaction !== null) await this.substrate.commit(reaction, seq);
    after?.();
  }

  /** Decide which reactor owns `message` and run its turn. `delegate`, `escalateAck`, and `terminate` always
   *  target a `core` instance (a freshly summoned child, the escalation's raiser, the cancelled child); only
   *  `delegateAck` / `escalate` / `terminateAck` route to the delegation's *caller* via `routeToCaller`. FFI
   *  completions are ephemeral triggers that resume their core instance. */
  private async route(message: ActorMessage): Promise<Routed> {
    if (isFfiResult(message)) return { reaction: await this.core.reactFfi(message) };
    switch (message.kind) {
      case "delegate":
      case "escalateAck":
      case "terminate":
        return { reaction: await this.core.react(message) };
      case "delegateAck":
      case "escalate":
      case "terminateAck":
        return this.routeToCaller(message);
    }
  }

  /** The single api|core dispatch. A `delegateAck` / `escalate` / `terminateAck` routes to its delegation's
   *  caller: a run's caller is the api root (reacts in the `ApiReactor`, settling its result promise after
   *  commit), else a core caller reacts in the engine (which resolves the caller from its own routing graph).
   *  The boundary is crossed once, here, by the core reactor's `isRunDelegation` sentinel. */
  private async routeToCaller(
    message: Extract<ExternalEvent, { kind: "delegateAck" | "escalate" | "terminateAck" }>,
  ): Promise<Routed> {
    // delegateAck / terminateAck end the delegation, so its child edge is dropped (an `escalate` leaves the
    // run running, so it keeps its child — that is how the eventual `escalateAck` finds the raiser).
    if (message.kind !== "escalate") this.core.dropChildEdge(message.delegation);
    if (this.core.isRunDelegation(message.delegation)) {
      const reaction = this.api.react(message);
      return { reaction, after: () => this.api.afterCommit(message, reaction) };
    }
    return { reaction: await this.core.react(message) };
  }
}
