// ProjectActor: the warm, per-project external consumer. It owns the project's `ProjectStore` (the
// loaded instances + shared scopes) and a serial mailbox of external events. The loop pulls one message
// at a time, routes it to the owning instance, drives that instance's internal turn to quiescence,
// persists at the turn boundary, then flushes the turn's outbound external events back onto the mailbox.
// Everything is serial; concurrency is the ack model (a parent that fanned out several delegates resumes
// each branch as its delegateAck lands). FFI completions and the inter-instance escalate / terminate
// halves arrive through the same mailbox and are handled in their respective (later) layers.

import type { QualifiedName } from "@katari-lang/types";
import { ascendResources, reownResources } from "../engine/ascent.js";
import { delegateProxyOf, raisePanic, relayEscalate, resumeEscalation } from "../engine/common.js";
import { makeStepContext, type PrimRunner, type StepContext } from "../engine/context.js";
import { drive } from "../engine/drive.js";
import { createInstance, isInstanceComplete, teardownInstance } from "../engine/instance.js";
import { readVariable } from "../engine/scope.js";
import { createProjectStore } from "../engine/store.js";
import { completeExternalAbort } from "../engine/thread-ops.js";
import type { CoreInstance, ProjectStore } from "../engine/types.js";
import { isUserFacingRequest } from "../escalation-filter.js";
import type {
  ActorMessage,
  DelegateTarget,
  ExternalEvent,
  FfiResult,
  InternalEvent,
} from "../event/types.js";
import { isFfiResult } from "../event/types.js";
import type { ExternalRunner } from "../external/runner.js";
import {
  apiRootIdOf,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newOutboxSeq,
  type OutboxSeq,
  type ProjectId,
  type ScopeId,
  type SnapshotId,
} from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import { type ApiHost, ApiReactor, type OpenEscalation } from "./api-reactor.js";
import type { Persistence } from "./persistence.js";
import {
  type EntityTransition,
  type Layer2Commit,
  type OutboxMessage,
  outboundTransitions,
  type Reaction,
} from "./turn-commit.js";

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
  private readonly ir: IrSource;
  private readonly prims: PrimRunner;
  private readonly blobs: BlobStore;
  private readonly external: ExternalRunner;
  private readonly persistence: Persistence;

  private readonly store: ProjectStore = createProjectStore();
  /** The project's permanent `api` management root (the issuer of run delegations / the sink of
   *  user-facing escalations). Its id is the project id (the single source of truth) — deterministic and
   *  stable across restarts, so no layer manages or persists it as a separate handle. */
  private readonly apiRootId: InstanceId;
  /** The serial inbox. Each entry carries the durable outbox row it came from (`seq`) so the turn that
   *  processes it consumes that row in its commit; `null` for an FFI completion (ephemeral, not an outbox
   *  event). The mailbox is just the warm cache of the outbox — replayed into on recovery. */
  private readonly mailbox: { message: ActorMessage; seq: OutboxSeq | null }[] = [];
  private pumping = false;
  /** Serialises every `commitTurn` against the others, so no two DB transactions interleave in the single
   *  (event-loop-concurrent) actor. */
  private commitChain: Promise<unknown> = Promise.resolve();
  /** Whether the project's persisted state has been reloaded into the warm store (lazy, on first use). */
  private loaded = false;
  /** The in-flight reactivation, so concurrent first-use callers (an api `produce` and the `pump`) share one
   *  load. Loading MUST complete before any commit — otherwise a just-produced outbox row would be re-read
   *  by `loadProject` and replayed (double-delivered). */
  private loadingPromise: Promise<void> | null = null;

  /** A pending delegate's caller instance, for routing its delegateAck / escalate home (the `delegations`
   *  row's caller). Absent for a run-root delegate, whose ack resolves the run instead (`runResolvers`). */
  private readonly delegationCaller: Record<DelegationId, InstanceId> = {};
  /** A delegation's spawned child instance — for routing a `terminate` to it, and an `escalateAck` back to
   *  the raiser (the escalating child is the delegation's child, so this is its raiser too). */
  private readonly delegationChild: Record<DelegationId, InstanceId> = {};

  /** The api management root's reactor: the user-facing run / escalation logic (it issues the run delegate /
   *  terminate / escalateAck and reacts to a run's delegateAck / escalate / terminateAck). It owns the api
   *  root's own state; the actor here is its substrate, exposed through the `ApiHost` adapter below. */
  private readonly api: ApiReactor;

  constructor(dependencies: ProjectActorDependencies) {
    this.projectId = dependencies.projectId;
    this.apiRootId = apiRootIdOf(this.projectId);
    this.ir = dependencies.ir;
    this.prims = dependencies.prims;
    this.blobs = dependencies.blobs;
    this.external = dependencies.external;
    this.persistence = dependencies.persistence;
    this.api = new ApiReactor(this.apiHost());
    // FFI completions re-enter through the same serial mailbox as every other external message.
    this.external.onResult((result) => this.feed(result));
  }

  /** The narrow substrate slice the api root drives (produce / commit / consume + the run delegation's
   *  routing edge). Built once; the arrows close over this actor's private machinery. */
  private apiHost(): ApiHost {
    return {
      apiRootId: this.apiRootId,
      ensureLoaded: () => this.ensureLoaded(),
      commit: (reaction, consumed) => this.commitReaction(reaction, consumed),
      openRunDelegation: (delegation) => {
        this.delegationCaller[delegation] = this.apiRootId;
      },
      closeRunDelegation: (delegation) => {
        delete this.delegationCaller[delegation];
      },
    };
  }

  /** Start a run on the api root. The actor exposes it for in-process callers (tests / the façade); the
   *  run id is the run delegation id (the durable handle), the `result` promise an in-process convenience. */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): { run: DelegationId; result: Promise<Value> } {
    return this.api.startRun(qualifiedName, snapshot, argument);
  }

  /** The loaded core instance under `id` (the engine store holds only core instances). */
  private coreInstance(id: InstanceId | undefined): CoreInstance | undefined {
    return id !== undefined ? this.store.instances[id] : undefined;
  }

  /** Whether `delegation` was issued by the api management root (a run) rather than a core caller (a
   *  sub-call). The api root is not an engine instance — it is the sentinel id, so this is a direct
   *  comparison, not a store lookup. */
  private isRunDelegation(delegation: DelegationId): boolean {
    return this.delegationCaller[delegation] === this.apiRootId;
  }

  // ─── api root commands (exposed for in-process callers; the logic lives in the ApiReactor) ──────────

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
    this.mailbox.push({ message: result, seq: null });
    void this.pump();
  }

  /** Reactivate the project once, before any commit. The lazy load reads the persisted outbox; doing it
   *  before producing prevents a just-produced row being re-read by `loadProject` and replayed. */
  private ensureLoaded(): Promise<void> {
    if (this.loaded) return Promise.resolve();
    if (this.loadingPromise === null) {
      // `loaded` flips true only once reactivation FULLY succeeds (including re-dispatching in-flight
      // externals); a failure clears `loadingPromise` so the next caller retries rather than proceeding on
      // a half-initialised actor.
      this.loadingPromise = this.reactivate().then(
        () => {
          this.loaded = true;
        },
        (error) => {
          this.loadingPromise = null;
          throw error;
        },
      );
    }
    return this.loadingPromise;
  }

  /** Durably produce external events from an api operation (no inbound event is being consumed): commit the
   *  outbox rows, then deliver them to the mailbox. The issuer is the api root (it re-establishes a replayed
   *  delegate's caller). */
  /** Commit one reactor turn (the substrate side of the bus): reactivate first so loading can never race a
   *  just-produced row, mint an outbox seq per `outbound` event (issued by the turn's instance), then write
   *  the whole turn — its Reaction plus the inbound `consumed` row — atomically and deliver. This is the one
   *  funnel every commit flows through, so "loading before any commit" and "seqs are the bus's" hold in one
   *  place. */
  private async commitReaction(reaction: Reaction, consumed: OutboxSeq | null): Promise<void> {
    await this.ensureLoaded();
    const produced: OutboxMessage[] = reaction.outbound.map((event) => ({
      seq: newOutboxSeq(),
      issuer: reaction.instanceId,
      event,
    }));
    await this.commit({
      instanceId: reaction.instanceId,
      layer2: reaction.layer2,
      transitions: reaction.transitions,
      consumed,
      produced,
    });
  }

  /** Commit one turn (serialised against all the others, so no two DB transactions interleave in the
   *  event-loop-concurrent actor), then deliver its produced events to the mailbox. */
  private async commit(commit: {
    instanceId: InstanceId;
    layer2: Layer2Commit;
    transitions: EntityTransition[];
    consumed: OutboxSeq | null;
    produced: OutboxMessage[];
  }): Promise<void> {
    const run = this.commitChain.then(() => this.persistence.commitTurn(this.projectId, commit));
    this.commitChain = run.then(
      () => undefined,
      () => undefined,
    );
    await run;
    this.deliver(commit.produced);
  }

  /** Consume an outbox row with no other effect — used by a handler that processes its event without a turn
   *  (an early return whose target is already gone, or an api handler that only settles a promise). A `null`
   *  seq (an FFI completion) has no row, so this is a no-op. */
  private consumeOnly(seq: OutboxSeq | null): Promise<void> {
    if (seq === null) return Promise.resolve();
    return this.commitReaction(
      { instanceId: this.apiRootId, layer2: { kind: "none" }, transitions: [], outbound: [] },
      seq,
    );
  }

  /** Deliver produced events to the mailbox (after their commit) and kick the loop. */
  private deliver(produced: OutboxMessage[]): void {
    for (const message of produced) {
      this.mailbox.push({ message: message.event, seq: message.seq });
    }
    if (produced.length > 0) void this.pump();
  }

  /** Activate a (possibly recovered) actor: reload persisted state and re-dispatch in-flight external
   *  work, without an inbound message to trigger it. Idempotent — the warm actor also self-activates on
   *  its first `feed`; a host calls this on boot to resume a project whose process went down mid-flight. */
  async activate(): Promise<void> {
    await this.pump();
  }

  // ─── serial loop ──────────────────────────────────────────────────────────────────────────────

  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    try {
      await this.ensureLoaded();
      while (this.mailbox.length > 0) {
        const entry = this.mailbox.shift();
        if (entry === undefined) break;
        await this.handle(entry.message, entry.seq);
      }
    } finally {
      this.pumping = false;
    }
  }

  /** Lazily reload the project's persisted engine state on first use, rebuilding the routing maps from
   *  the instances (a pending delegation's key names its caller; an instance's `delegationId` its child —
   *  which doubles as an escalation's raiser). The warm store is then the truth until eviction. */
  private async reactivate(): Promise<void> {
    const snapshot = await this.persistence.loadProject(this.projectId);
    this.store.instances = snapshot.instances;
    this.store.scopes = snapshot.scopes;
    this.store.nextScopeId = snapshot.nextScopeId;
    // The live Layer 1 delegation edges give every delegation its caller — in particular the api root's run
    // delegations, which have no `DelegateThread` to rebuild from (the api root runs no engine threads).
    for (const [delegation, caller] of Object.entries(snapshot.delegations)) {
      this.delegationCaller[delegation as DelegationId] = caller;
    }
    for (const instance of Object.values(this.store.instances)) {
      if (instance.delegationId !== null) {
        this.delegationChild[instance.delegationId] = instance.id;
      }
      // A surviving `DelegateThread` also names its delegation's caller (its own instance) — this covers a
      // freshly-issued delegation whose child instance / Layer 1 row a crash may have preceded.
      for (const thread of Object.values(instance.threads)) {
        if (thread.kind === "delegate") this.delegationCaller[thread.delegationId] = instance.id;
      }
      // No escalation mirror to rebuild — an `escalateAck` routes to its raiser via `delegationChild`
      // (set above from each instance's own `delegationId`).
    }
    // Rehydrate the user-facing open escalations (a run suspended awaiting a user's answer must survive a
    // restart). An open escalation is user-facing iff its raiser is a run root (its delegation's caller is
    // the api root) and it is a genuine request (not a panic / control escape, which fail rather than wait).
    for (const open of snapshot.openEscalations) {
      const raiser = this.coreInstance(open.raiser);
      const run = raiser?.delegationId;
      if (run === undefined || run === null) continue;
      if (this.delegationCaller[run] !== this.apiRootId) continue;
      if (!isUserFacingRequest(open.request)) continue;
      this.api.rehydrateOpenEscalation({
        run,
        escalation: open.escalation,
        request: open.request as QualifiedName,
        argument: open.argument,
      });
    }
    // The api management root is a permanent per-project Layer 1 fixture, not an engine instance. Ensure its
    // durable `instances` row exists (so a run's `delegation-open`, whose caller is the api root, satisfies
    // the caller FK); routing to it needs no warm-store entry — the dispatch resolves it by sentinel id.
    await this.persistence.ensureApiRoot(this.projectId, this.apiRootId);
    // Replay the undrained outbox into the mailbox: events produced before the crash but not yet consumed
    // (e.g. a completed child's `delegateAck` whose parent never resumed). A replayed `delegate` re-uses its
    // row's issuer as its caller (the event itself does not carry it), exactly as the warm path records it.
    for (const message of snapshot.pendingOutbox) {
      if (message.event.kind === "delegate") {
        this.delegationCaller[message.event.delegation] = message.issuer;
      }
      this.mailbox.push({ message: message.event, seq: message.seq });
    }
    // NB: `loaded` is set by `ensureLoaded` only after this whole method (incl. the resume below) resolves,
    // so a resume failure does not leave the actor marked loaded-but-half-initialised.
    await this.resumeInFlightExternals();
  }

  /** After reactivation, re-dispatch every external (FFI) leaf still `open`: its in-flight dispatch was a
   *  private side channel (not a persisted event), so the process going down lost it. The durable
   *  `ExternalThread` row is the recovery handle — key + argument are re-derived from its block + scope.
   *  Completions re-enter through the serial mailbox exactly like a first dispatch. */
  private async resumeInFlightExternals(): Promise<void> {
    for (const instance of Object.values(this.store.instances)) {
      const snapshot = instance.target.snapshot;
      await this.ir.preload(snapshot);
      const ir = this.ir.access(snapshot, moduleOf(instance.target));
      for (const thread of Object.values(instance.threads)) {
        if (thread.kind !== "external" || thread.externalState !== "open") continue;
        if (thread.status === "cancelling") {
          // A mid-abort external: re-request the abort (its `ffiCancelled` confirmation may have been lost
          // when the process went down) rather than re-dispatch the call.
          this.external.cancel(instance.id, thread.id);
          continue;
        }
        const block = ir.block(thread.blockId).block;
        if (block.kind !== "external") continue;
        const argument = readVariable(this.store, thread.scopeId, block.input) ?? null;
        this.external.dispatch({
          projectId: this.projectId,
          instance: instance.id,
          thread: thread.id,
          key: block.key,
          argument,
          redispatch: true,
        });
      }
    }
  }

  /** Route one inbound message to its handler. `seq` is the durable outbox row it came from (`null` for an
   *  FFI completion); the handler consumes it in the same commit as its effects (the transactional
   *  consumer), so a crash never replays an event whose effect already committed.
   *
   *  `delegate`, `escalateAck`, and `terminate` always target a `core` instance (a freshly summoned child,
   *  the escalation's raiser, the cancelled child). Only `delegateAck` / `escalate` / `terminateAck` route
   *  to the delegation's *caller* — which is the api root (a run) or a core instance — so they pass through
   *  `routeToCaller`, the one place the api|core decision is made. */
  private async handle(message: ActorMessage, seq: OutboxSeq | null): Promise<void> {
    if (isFfiResult(message)) {
      await this.onFfiResult(message);
      return;
    }
    switch (message.kind) {
      case "delegate":
        return this.onDelegate(message, seq);
      case "escalateAck":
        return this.onEscalateAck(message, seq);
      case "terminate":
        return this.onTerminate(message, seq);
      case "delegateAck":
      case "escalate":
      case "terminateAck":
        return this.routeToCaller(message, seq);
    }
  }

  /** The single api|core dispatch. A `delegateAck` / `escalate` / `terminateAck` routes to its delegation's
   *  caller; resolve it once and branch here. After this point neither the ApiReactor nor the core handlers
   *  inspect the other's kind — this is the only place the boundary is crossed. */
  private routeToCaller(
    message: Extract<ExternalEvent, { kind: "delegateAck" | "escalate" | "terminateAck" }>,
    seq: OutboxSeq | null,
  ): Promise<void> {
    // delegateAck / terminateAck end the delegation, so its child edge is dropped here (an `escalate` leaves
    // the run running, so it keeps its child — that is how the eventual `escalateAck` finds the raiser).
    if (message.kind !== "escalate") delete this.delegationChild[message.delegation];
    // The single api|core dispatch: a run delegation's caller is the api root (a sentinel id, not an engine
    // instance), so the boundary is crossed by comparing ids — branch once, here, and never again.
    if (this.isRunDelegation(message.delegation)) return this.reactApi(message, seq);
    const caller = this.coreInstance(this.delegationCaller[message.delegation]);
    if (caller === undefined) return this.consumeOnly(seq);
    return this.reactCore(message, caller, seq);
  }

  /** The api root's reaction to a run's delegateAck / escalate / terminateAck. The reactor computes its turn
   *  as a `Reaction` (the kind-dispatch lives inside `react`), the substrate commits it, then the reactor's
   *  post-commit side effect (settling the in-process result promise) runs durable-first. */
  private async reactApi(
    message: Extract<ExternalEvent, { kind: "delegateAck" | "escalate" | "terminateAck" }>,
    seq: OutboxSeq | null,
  ): Promise<void> {
    const reaction = this.api.react(message);
    await this.commitReaction(reaction, seq);
    this.api.afterCommit(message, reaction);
  }

  /** A core caller's reaction to a sub-call's delegateAck / escalate / terminateAck (`caller` is resolved
   *  once in `routeToCaller`, so these never re-look-up or re-check kind). */
  private reactCore(
    message: Extract<ExternalEvent, { kind: "delegateAck" | "escalate" | "terminateAck" }>,
    caller: CoreInstance,
    seq: OutboxSeq | null,
  ): Promise<void> {
    switch (message.kind) {
      case "delegateAck":
        return this.onCoreDelegateAck(message, caller, seq);
      case "escalate":
        return this.onCoreEscalate(message, caller, seq);
      case "terminateAck":
        return this.onCoreTerminateAck(message, caller, seq);
    }
  }

  // ─── delegate / delegateAck ─────────────────────────────────────────────────────────────────

  private async onDelegate(
    event: Extract<ExternalEvent, { kind: "delegate" }>,
    seq: OutboxSeq | null,
  ): Promise<void> {
    await this.ir.preload(event.target.snapshot);
    const resolved = this.resolveTarget(event.target);
    const instance = createInstance(this.store, {
      delegationId: event.delegation,
      target: event.target,
      argument: event.argument,
      agentBlockId: resolved.agentBlockId,
      capturedScopeId: resolved.capturedScopeId,
      snapshotId: resolved.snapshot,
      ...(event.generics !== undefined ? { ambientGenerics: event.generics } : {}),
    });
    this.delegationChild[event.delegation] = instance.id;
    // Record the Layer 1 delegation edge in this same (child create) turn, so it commits atomically with
    // the child instance. Its caller is known from routing (a core issuer, or the api root for a run). This
    // is where a run's delegation row first appears — the api root issues but runs no turn of its own.
    const caller = this.delegationCaller[event.delegation];
    const open: EntityTransition[] =
      caller === undefined
        ? []
        : [
            {
              kind: "delegation-open",
              delegation: event.delegation,
              caller,
              target: event.target,
              argument: event.argument,
            },
          ];
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }], open, seq);
  }

  /** A core sub-call returned: hand its value to the caller's pending proxy slot (`caller` and the dropped
   *  child edge are handled by `routeToCaller`). */
  private async onCoreDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    caller: CoreInstance,
    seq: OutboxSeq | null,
  ): Promise<void> {
    delete this.delegationCaller[event.delegation];
    // Claim any resources the returned value carries up (a returned closure's captured scope chain, a
    // returned blob — set in-transit when the child retired): they now belong to this caller, which is
    // about to bind the value.
    reownResources(this.store, caller.id, event.value);
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) {
      return this.consumeOnly(seq);
    }
    delete caller.threads[proxy.id];
    await this.runTurn(
      caller,
      [{ kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value }],
      [],
      seq,
    );
  }

  // ─── escalate / escalateAck (a request / control ask crossing the instance boundary) ────────────

  /** A sub-call's escalation reached a core caller: re-raise it inside the caller from the proxy's position
   *  so it bubbles toward a handle (`caller` resolved by `routeToCaller`). */
  private async onCoreEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    caller: CoreInstance,
    seq: OutboxSeq | null,
  ): Promise<void> {
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined) return this.consumeOnly(seq);
    // The relay echoes the raiser's `(delegation, escalation)` so its eventual `escalateAck` finds its way home.
    await this.runTurnWith(
      caller,
      (ctx) => {
        relayEscalate(ctx, proxy.id, event.escalation, event.ask);
      },
      [],
      seq,
    );
  }

  private async onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
    seq: OutboxSeq | null,
  ): Promise<void> {
    // The escalating child is the delegation's child, so it is also the raiser. Hand the answer to its
    // Agent root in external vocabulary `(escalation, value)`; the Agent maps the escalation back to its
    // internal askId and re-enters it as an askAck. The actor never names an inner thread. (The raiser is
    // always a `core` instance — the api root never raises.)
    const instance = this.coreInstance(this.delegationChild[event.delegation]);
    if (instance === undefined) return this.consumeOnly(seq);
    // Mark the escalation answered in this same turn (the api root, or a relaying parent, runs no turn that
    // would emit the escalateAck as outbound, so record it here from the consumed event).
    await this.runTurnWith(
      instance,
      (ctx) => resumeEscalation(ctx, event.escalation, event.value),
      [{ kind: "escalation-answered", escalation: event.escalation, answer: event.value }],
      seq,
    );
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  private async onTerminate(
    event: Extract<ExternalEvent, { kind: "terminate" }>,
    seq: OutboxSeq | null,
  ): Promise<void> {
    const child = this.coreInstance(this.delegationChild[event.delegation]);
    if (child === undefined) return this.consumeOnly(seq);
    child.status = "cancelling";
    // Cancel the root; once its subtree is torn down it emits terminateAck and retires the instance. Record
    // the delegation moving to `cancelling` in this same turn (so it holds even for an api-issued cancel,
    // which runs no turn of its own).
    await this.runTurn(
      child,
      [{ kind: "cancel", target: child.rootThreadId }],
      [{ kind: "delegation-cancelling", delegation: event.delegation }],
      seq,
    );
  }

  /** A core sub-call's terminate cascade confirmed: retire the proxy and cancelAck the caller's parent so the
   *  cancel cascade continues (`caller` and the dropped child edge are handled by `routeToCaller`). */
  private async onCoreTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    caller: CoreInstance,
    seq: OutboxSeq | null,
  ): Promise<void> {
    delete this.delegationCaller[event.delegation];
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) {
      return this.consumeOnly(seq);
    }
    delete caller.threads[proxy.id];
    delete caller.cancelExits[proxy.id];
    await this.runTurn(
      caller,
      [{ kind: "cancelAck", target: proxy.parent, callId: proxy.parentCallId }],
      [],
      seq,
    );
  }

  // ─── FFI completion ──────────────────────────────────────────────────────────────────────────

  /** Feed an FFI completion back to the suspended `ExternalThread` it belongs to: a result resumes it
   *  (ack its parent → completes the call's instance → delegateAck), an error raises a panic, and an
   *  abort confirmation finishes a cancelling thread's graceful cancel. */
  private async onFfiResult(result: FfiResult): Promise<void> {
    const instance = this.coreInstance(result.instance);
    if (instance === undefined) return; // its instance was torn down (cancelled) — drop the late result
    const thread = instance.threads[result.thread];
    if (thread === undefined || thread.kind !== "external") return;
    if (result.kind === "ffiCancelled" || thread.status === "cancelling") {
      // The thread is being aborted: any completion (the runner's `ffiCancelled`, or a real result/error
      // that raced the abort) finishes its graceful cancel. The value, if any, is discarded.
      await this.runTurnWith(instance, (ctx) => completeExternalAbort(ctx, thread.id));
      return;
    }
    if (result.kind === "ffiError") {
      // An FFI failure is a panic raised from the external leaf (it bubbles to a handler / fails the run).
      await this.runTurnWith(instance, (ctx) => raisePanic(ctx, thread, result.message));
      return;
    }
    if (thread.parent === null || thread.parentCallId === null) return;
    delete instance.threads[thread.id];
    await this.runTurn(instance, [
      { kind: "callAck", target: thread.parent, callId: thread.parentCallId, value: result.value },
    ]);
  }

  /** Ascend the resources a completing instance's returned value captures — but only when its caller is a
   *  `core` instance that re-owns them (in its `onDelegateAck`). A run result goes to the `api` root and
   *  leaves the engine, so its captured resources simply drop with the instance. The returned value rides
   *  in this same turn's own `delegateAck`. */
  private ascendReturnedResources(instance: CoreInstance, outbound: ExternalEvent[]): void {
    const delegation = instance.delegationId;
    if (delegation === null) return;
    // Only a core caller re-owns ascended resources. A run result goes to the api root (the sentinel id, not
    // an engine instance) and leaves the engine, so its captured resources simply drop with the instance.
    const caller = this.coreInstance(this.delegationCaller[delegation]);
    if (caller === undefined) return;
    const ack = outbound.find(
      (event): event is Extract<ExternalEvent, { kind: "delegateAck" }> =>
        event.kind === "delegateAck" && event.delegation === delegation,
    );
    if (ack !== undefined) ascendResources(this.store, instance.id, ack.value);
  }

  // ─── one instance turn ────────────────────────────────────────────────────────────────────────

  private runTurn(
    instance: CoreInstance,
    initial: InternalEvent[],
    extraTransitions: EntityTransition[] = [],
    consumed: OutboxSeq | null = null,
  ): Promise<void> {
    return this.runTurnWith(
      instance,
      (ctx) => {
        ctx.buffers.internalQueue.push(...initial);
      },
      extraTransitions,
      consumed,
    );
  }

  /** Drive one `core` instance's turn after `seed` queues its initial internal events (directly, or via a
   *  helper that needs the StepContext such as `relayEscalate`); then commit the turn and flush. The turn
   *  commits atomically: its Layer 2 (the instance's graph, persisted, or dropped if it completed) together
   *  with the Layer 1 entity transitions it implies — `extraTransitions` from the handler (a delegation it
   *  is opening / cancelling, an escalation it is answering) plus the ones its outbound events imply — and
   *  the outbox bookkeeping (consume the handled row `consumed`, durably produce the outbound events). */
  private async runTurnWith(
    instance: CoreInstance,
    seed: (ctx: StepContext) => void,
    extraTransitions: EntityTransition[] = [],
    consumed: OutboxSeq | null = null,
  ): Promise<void> {
    const snapshot = instance.target.snapshot;
    await this.ir.preload(snapshot);
    const ctx = makeStepContext({
      projectId: this.projectId,
      store: this.store,
      instance,
      ir: this.ir.access(snapshot, moduleOf(instance.target)),
      prims: this.prims,
      blobs: this.blobs,
      external: this.external,
    });
    seed(ctx);
    await drive(ctx);
    // DB reflection happens once the internal queue is empty (the turn boundary). A completed instance is
    // dropped (cascade), a still-running one is written through with its owned scopes — either way together
    // with the Layer 1 transitions, in one atomic commit.
    const outbound = ctx.buffers.outbound;
    const transitions = [...extraTransitions, ...outboundTransitions(instance.id, outbound)];
    // Record the caller of every delegate this turn issues (the warm-path mirror; the outbox row's issuer
    // re-establishes the same on recovery). The escalate / escalateAck / terminate legs route by
    // `delegationChild`, already set when the child was summoned, so they need no separate mirror.
    for (const event of outbound) {
      if (event.kind === "delegate") this.delegationCaller[event.delegation] = instance.id;
    }
    let layer2: Layer2Commit;
    if (isInstanceComplete(instance)) {
      // Before dropping the instance's scopes, ascend the ones its returned value captures (set them
      // in-transit) so the caller re-owns them in its `onDelegateAck`. Only when there is a caller — a
      // run-root result leaves the engine, so its captured scopes (if any) simply drop with the instance.
      this.ascendReturnedResources(instance, outbound);
      teardownInstance(this.store, instance.id);
      layer2 = { kind: "drop" };
    } else {
      const ownedScopes = Object.values(this.store.scopes).filter(
        (scope) => scope.owner === instance.id,
      );
      layer2 = { kind: "persist", instance, ownedScopes };
    }
    await this.commitReaction({ instanceId: instance.id, layer2, transitions, outbound }, consumed);
  }

  private resolveTarget(target: DelegateTarget): {
    agentBlockId: number;
    capturedScopeId: ScopeId | null;
    snapshot: SnapshotId;
  } {
    if (target.kind === "named") {
      return {
        agentBlockId: this.ir.locate(target.snapshot, target.name).blockId,
        capturedScopeId: null,
        snapshot: target.snapshot,
      };
    }
    return {
      agentBlockId: target.blockId,
      capturedScopeId: target.scopeId,
      snapshot: target.snapshot,
    };
  }
}

/** The module a delegate target's agent lives in (block ids are module-local). */
function moduleOf(target: DelegateTarget): string {
  return target.kind === "named" ? moduleOfName(target.name) : target.module;
}
