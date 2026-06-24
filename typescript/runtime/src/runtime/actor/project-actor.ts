// ProjectActor: the warm, per-project external consumer. It owns the project's `ProjectStore` (the
// loaded instances + shared scopes) and a serial mailbox of external events. The loop pulls one message
// at a time, routes it to the owning instance, drives that instance's internal turn to quiescence,
// persists at the turn boundary, then flushes the turn's outbound external events back onto the mailbox.
// Everything is serial; concurrency is the ack model (a parent that fanned out several delegates resumes
// each branch as its delegateAck lands). FFI completions and the inter-instance escalate / terminate
// halves arrive through the same mailbox and are handled in their respective (later) layers.

import type { QualifiedName } from "@katari-lang/types";
import { ascendResources, reownResources } from "../engine/ascent.js";
import {
  delegateProxyOf,
  PANIC_REQUEST,
  raisePanic,
  relayEscalate,
  resumeEscalation,
} from "../engine/common.js";
import { makeStepContext, type PrimRunner, type StepContext } from "../engine/context.js";
import { drive } from "../engine/drive.js";
import {
  createInstance,
  ensureApiRoot,
  isInstanceComplete,
  teardownInstance,
} from "../engine/instance.js";
import { readVariable } from "../engine/scope.js";
import { createProjectStore } from "../engine/store.js";
import { completeExternalAbort } from "../engine/thread-ops.js";
import type { CoreInstance, Instance, ProjectStore } from "../engine/types.js";
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
  newDelegationId,
  type ProjectId,
  type ScopeId,
  type SnapshotId,
} from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import type { Persistence } from "./persistence.js";
import { type EntityTransition, outboundTransitions } from "./turn-commit.js";

export interface ProjectActorDependencies {
  projectId: ProjectId;
  ir: IrSource;
  prims: PrimRunner;
  blobs: BlobStore;
  external: ExternalRunner;
  persistence: Persistence;
}

/** One run-root request the engine could not handle internally, awaiting a user's answer. */
export interface OpenEscalation {
  escalation: EscalationId;
  request: QualifiedName;
  argument: Value | null;
}

/** Why a run's `result` promise rejected: it was cancelled (vs failed). Lets the run layer settle the
 *  durable run record as `cancelled` rather than `error`. */
export class RunCancelledError extends Error {
  constructor(public readonly reason?: string) {
    super(reason !== undefined ? `run cancelled: ${reason}` : "run cancelled");
    this.name = "RunCancelledError";
  }
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
  private readonly mailbox: ActorMessage[] = [];
  private pumping = false;
  /** Whether the project's persisted state has been reloaded into the warm store (lazy, on first use). */
  private loaded = false;

  /** A pending delegate's caller instance, for routing its delegateAck / escalate home (the `delegations`
   *  row's caller). Absent for a run-root delegate, whose ack resolves the run instead (`runResolvers`). */
  private readonly delegationCaller: Record<DelegationId, InstanceId> = {};
  /** A delegation's spawned child instance — for routing a `terminate` to it, and an `escalateAck` back to
   *  the raiser (the escalating child is the delegation's child, so this is its raiser too). */
  private readonly delegationChild: Record<DelegationId, InstanceId> = {};
  /** Settle / reject a run-root delegation: its delegateAck resolves the `startRun` promise; a panic /
   *  unhandled escape at the run root rejects it; a terminate (cancel) rejects it with `RunCancelledError`. */
  private readonly runResolvers: Record<DelegationId, (value: Value) => void> = {};
  private readonly runRejecters: Record<DelegationId, (error: Error) => void> = {};
  /** Run-root requests the engine could not handle, kept open (their run-root instance stays suspended)
   *  until a user answers — keyed by the escalation id, which also names the run delegation it belongs to. */
  private readonly openEscalations: Record<EscalationId, OpenEscalation & { run: DelegationId }> =
    {};
  /** A cancelling run's reason, held until its terminateAck settles the run (`RunCancelledError`). */
  private readonly cancelReasons: Record<DelegationId, string | undefined> = {};

  constructor(dependencies: ProjectActorDependencies) {
    this.projectId = dependencies.projectId;
    this.apiRootId = apiRootIdOf(this.projectId);
    this.ir = dependencies.ir;
    this.prims = dependencies.prims;
    this.blobs = dependencies.blobs;
    this.external = dependencies.external;
    this.persistence = dependencies.persistence;
    // FFI completions re-enter through the same serial mailbox as every other external message.
    this.external.onResult((result) => this.feed(result));
  }

  /** Start a run: summon a root instance for `qualifiedName@snapshot`. Returns the run delegation (the
   *  handle for `cancelRun`) and a promise that settles with the result (or rejects: a panic / unhandled
   *  escape fails it, a cancel rejects it with `RunCancelledError`). */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): { run: DelegationId; result: Promise<Value> } {
    // A run is a `delegate` the api root issues to a `core` instance. Record the root as the delegation's
    // caller *explicitly* (it is the issuer) — this is what routes the run's delegateAck / escalate /
    // terminateAck to the api handler, exactly as `routeOutbound` records the caller of a core sub-delegate.
    const delegation = newDelegationId();
    this.delegationCaller[delegation] = this.apiRootId;
    const result = new Promise<Value>((resolve, reject) => {
      this.runResolvers[delegation] = resolve;
      this.runRejecters[delegation] = reject;
    });
    this.feed({
      kind: "delegate",
      delegation,
      target: { kind: "named", name: qualifiedName, snapshot },
      argument,
    });
    return { run: delegation, result };
  }

  /** The loaded instance under `id` if it is a `core` instance (the engine only ever drives core). */
  private coreInstance(id: InstanceId | undefined): CoreInstance | undefined {
    if (id === undefined) return undefined;
    const instance = this.store.instances[id];
    return instance !== undefined && instance.kind === "core" ? instance : undefined;
  }

  /** The instance that issued `delegation` (its caller) — `api` for a run, `core` for a sub-call. */
  private callerOf(delegation: DelegationId): Instance | undefined {
    const id = this.delegationCaller[delegation];
    return id !== undefined ? this.store.instances[id] : undefined;
  }

  // ─── api root handlers (a run's delegateAck / escalate / terminateAck reaching the management root) ──

  /** A run finished: settle its result. */
  private handleApiDelegateAck(delegation: DelegationId, value: Value): void {
    delete this.delegationCaller[delegation];
    this.settleRun(delegation, { value });
  }

  /** A run's escalation reached the root unhandled: a genuine request is kept open for a user to answer
   *  (the run stays suspended); a panic / unhandled escape fails the run. */
  private handleApiEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): void {
    const ask = event.ask;
    if (ask.kind === "request" && ask.request !== PANIC_REQUEST) {
      this.openEscalations[event.escalation] = {
        run: event.delegation,
        escalation: event.escalation,
        request: ask.request,
        argument: ask.argument,
      };
      return;
    }
    this.settleRun(event.delegation, { error: new Error(escalationErrorMessage(event)) });
  }

  /** A run's terminate cascade confirmed: settle it as cancelled. */
  private handleApiTerminateAck(delegation: DelegationId): void {
    delete this.delegationCaller[delegation];
    this.settleRun(delegation, { error: new RunCancelledError(this.cancelReasons[delegation]) });
  }

  /** Request a run's cancellation: terminate its root instance (the run delegation's child). The cascade
   *  tears the tree down and the terminateAck rejects the run with `RunCancelledError`. A no-op if the run
   *  already finished. */
  cancelRun(run: DelegationId, reason?: string): void {
    this.cancelReasons[run] = reason;
    this.feed({ kind: "terminate", delegation: run });
  }

  /** Answer an open run-root escalation: relay the value back to its suspended raiser, which resumes. */
  answerEscalation(escalation: EscalationId, value: Value): void {
    const open = this.openEscalations[escalation];
    if (open === undefined) return;
    delete this.openEscalations[escalation];
    this.feed({ kind: "escalateAck", delegation: open.run, escalation, value });
  }

  /** The run-root escalations currently awaiting an answer. */
  listOpenEscalations(): OpenEscalation[] {
    return Object.values(this.openEscalations).map(({ escalation, request, argument }) => ({
      escalation,
      request,
      argument,
    }));
  }

  /** Settle a run-root delegation either way and drop its handlers + any of its still-open escalations. */
  private settleRun(delegation: DelegationId, outcome: { value: Value } | { error: Error }): void {
    const resolver = this.runResolvers[delegation];
    const rejecter = this.runRejecters[delegation];
    delete this.runResolvers[delegation];
    delete this.runRejecters[delegation];
    delete this.cancelReasons[delegation];
    for (const [escalation, open] of Object.entries(this.openEscalations)) {
      if (open.run === delegation) delete this.openEscalations[escalation as EscalationId];
    }
    if ("value" in outcome) resolver?.(outcome.value);
    else rejecter?.(outcome.error);
  }

  /** Enqueue an external message and ensure the serial loop is running. */
  feed(message: ActorMessage): void {
    this.mailbox.push(message);
    void this.pump();
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
      if (!this.loaded) await this.reactivate();
      while (this.mailbox.length > 0) {
        const message = this.mailbox.shift();
        if (message === undefined) break;
        await this.handle(message);
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
      if (instance.kind !== "core") continue; // the api root has no engine routing edges to rebuild
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
      this.openEscalations[open.escalation] = {
        run,
        escalation: open.escalation,
        request: open.request as QualifiedName,
        argument: open.argument,
      };
    }
    // The api management root is a permanent per-project fixture; (re)create it after loading replaced the
    // store, so a run's delegateAck / escalate / terminateAck can always find it as the delegation's caller.
    ensureApiRoot(this.store, this.apiRootId);
    this.loaded = true;
    await this.resumeInFlightExternals();
  }

  /** After reactivation, re-dispatch every external (FFI) leaf still `open`: its in-flight dispatch was a
   *  private side channel (not a persisted event), so the process going down lost it. The durable
   *  `ExternalThread` row is the recovery handle — key + argument are re-derived from its block + scope.
   *  Completions re-enter through the serial mailbox exactly like a first dispatch. */
  private async resumeInFlightExternals(): Promise<void> {
    for (const instance of Object.values(this.store.instances)) {
      if (instance.kind !== "core") continue; // the api root has no external (FFI) threads
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

  private async handle(message: ActorMessage): Promise<void> {
    if (isFfiResult(message)) {
      await this.onFfiResult(message);
      return;
    }
    switch (message.kind) {
      case "delegate":
        await this.onDelegate(message);
        return;
      case "delegateAck":
        await this.onDelegateAck(message);
        return;
      case "escalate":
        await this.onEscalate(message);
        return;
      case "escalateAck":
        await this.onEscalateAck(message);
        return;
      case "terminate":
        await this.onTerminate(message);
        return;
      case "terminateAck":
        await this.onTerminateAck(message);
        return;
    }
  }

  // ─── delegate / delegateAck ─────────────────────────────────────────────────────────────────

  private async onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): Promise<void> {
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
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }], open);
  }

  private async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): Promise<void> {
    delete this.delegationChild[event.delegation];
    const caller = this.callerOf(event.delegation);
    if (caller === undefined) return;
    if (caller.kind === "api") {
      this.handleApiDelegateAck(event.delegation, event.value);
      return;
    }
    delete this.delegationCaller[event.delegation];
    // Claim any resources the returned value carries up (a returned closure's captured scope chain, a
    // returned blob — set in-transit when the child retired): they now belong to this caller, which is
    // about to bind the value.
    reownResources(this.store, caller.id, event.value);
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    delete caller.threads[proxy.id];
    await this.runTurn(caller, [
      { kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value },
    ]);
  }

  // ─── escalate / escalateAck (a request / control ask crossing the instance boundary) ────────────

  private async onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): Promise<void> {
    const caller = this.callerOf(event.delegation);
    if (caller === undefined) return;
    if (caller.kind === "api") {
      // Reached the management root unhandled → a user-facing open escalation (the raiser stays suspended,
      // found later via `delegationChild` when answered). Panic / unhandled escape fails the run.
      this.handleApiEscalate(event);
      return;
    }
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined) return;
    // Re-raise the ask inside the caller from the proxy's position; it bubbles toward a handle. The relay
    // echoes the raiser's `(delegation, escalation)` so its eventual `escalateAck` finds its way home.
    await this.runTurnWith(caller, (ctx) => {
      relayEscalate(ctx, proxy.id, event.escalation, event.ask);
    });
  }

  private async onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
  ): Promise<void> {
    // The escalating child is the delegation's child, so it is also the raiser. Hand the answer to its
    // Agent root in external vocabulary `(escalation, value)`; the Agent maps the escalation back to its
    // internal askId and re-enters it as an askAck. The actor never names an inner thread. (The raiser is
    // always a `core` instance — the api root never raises.)
    const instance = this.coreInstance(this.delegationChild[event.delegation]);
    if (instance === undefined) return;
    // Mark the escalation answered in this same turn (the api root, or a relaying parent, runs no turn that
    // would emit the escalateAck as outbound, so record it here from the consumed event).
    await this.runTurnWith(
      instance,
      (ctx) => resumeEscalation(ctx, event.escalation, event.value),
      [{ kind: "escalation-answered", escalation: event.escalation, answer: event.value }],
    );
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  private async onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): Promise<void> {
    const child = this.coreInstance(this.delegationChild[event.delegation]);
    if (child === undefined) return;
    child.status = "cancelling";
    // Cancel the root; once its subtree is torn down it emits terminateAck and retires the instance. Record
    // the delegation moving to `cancelling` in this same turn (so it holds even for an api-issued cancel,
    // which runs no turn of its own).
    await this.runTurn(
      child,
      [{ kind: "cancel", target: child.rootThreadId }],
      [{ kind: "delegation-cancelling", delegation: event.delegation }],
    );
  }

  private async onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
  ): Promise<void> {
    delete this.delegationChild[event.delegation];
    const caller = this.callerOf(event.delegation);
    if (caller === undefined) return;
    if (caller.kind === "api") {
      // A run terminate confirmed: the cancelled run's tree is gone — settle it as cancelled.
      this.handleApiTerminateAck(event.delegation);
      return;
    }
    delete this.delegationCaller[event.delegation];
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    // The child confirmed teardown: retire the proxy and cancelAck its parent (the cancel cascade continues).
    delete caller.threads[proxy.id];
    delete caller.cancelExits[proxy.id];
    await this.runTurn(caller, [
      { kind: "cancelAck", target: proxy.parent, callId: proxy.parentCallId },
    ]);
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
    const caller = this.callerOf(delegation);
    if (caller === undefined || caller.kind !== "core") return;
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
  ): Promise<void> {
    return this.runTurnWith(
      instance,
      (ctx) => {
        ctx.buffers.internalQueue.push(...initial);
      },
      extraTransitions,
    );
  }

  /** Drive one `core` instance's turn after `seed` queues its initial internal events (directly, or via a
   *  helper that needs the StepContext such as `relayEscalate`); then commit the turn and flush. The turn
   *  commits atomically: its Layer 2 (the instance's graph, persisted, or dropped if it completed) together
   *  with the Layer 1 entity transitions it implies — `extraTransitions` from the handler (a delegation it
   *  is opening / cancelling, an escalation it is answering) plus the ones its outbound events imply. */
  private async runTurnWith(
    instance: CoreInstance,
    seed: (ctx: StepContext) => void,
    extraTransitions: EntityTransition[] = [],
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
    const transitions = [
      ...extraTransitions,
      ...outboundTransitions(instance.id, ctx.buffers.outbound),
    ];
    if (isInstanceComplete(instance)) {
      // Before dropping the instance's scopes, ascend the ones its returned value captures (set them
      // in-transit) so the caller re-owns them in its `onDelegateAck`. Only when there is a caller — a
      // run-root result leaves the engine, so its captured scopes (if any) simply drop with the instance.
      this.ascendReturnedResources(instance, ctx.buffers.outbound);
      teardownInstance(this.store, instance.id);
      await this.persistence.commitTurn(this.projectId, {
        instanceId: instance.id,
        layer2: { kind: "drop" },
        transitions,
      });
    } else {
      const ownedScopes = Object.values(this.store.scopes).filter(
        (scope) => scope.owner === instance.id,
      );
      await this.persistence.commitTurn(this.projectId, {
        instanceId: instance.id,
        layer2: { kind: "persist", instance, ownedScopes },
        transitions,
      });
    }
    for (const event of ctx.buffers.outbound) {
      this.routeOutbound(instance.id, event);
    }
  }

  /** Send a turn's outbound external event onward: a delegate records its caller for ack routing (the
   *  escalate / escalateAck legs route by `delegationChild`, already set when the child was summoned, so
   *  they need no separate mirror); then every event re-enters the serial mailbox. */
  private routeOutbound(fromInstanceId: InstanceId, event: ExternalEvent): void {
    if (event.kind === "delegate") {
      this.delegationCaller[event.delegation] = fromInstanceId;
    }
    this.mailbox.push(event);
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

/** The `AskKind`s that are control-flow escapes (not capability requests). An escalation carrying one of
 *  these is an unwind crossing an instance boundary, not a user-answerable request. */
const CONTROL_ESCAPE_KINDS = new Set(["next", "next-for", "return", "break", "break-for"]);

/** Whether a persisted escalation's `request` names a genuine user-answerable capability — i.e. it is not a
 *  panic and not a control-flow escape (both of which fail the run rather than wait for an answer). The
 *  `request` column stores a request ask's qualified name, or a control ask's bare `kind`; capability
 *  names are qualified, so they never collide with the bare control keywords. */
function isUserFacingRequest(request: string): boolean {
  return request !== PANIC_REQUEST && !CONTROL_ESCAPE_KINDS.has(request);
}

/** A human message for an escalation that reached the run root unhandled (it fails the run). A panic
 *  reports its `{ msg }`; any other unhandled request / control escape reports its name. */
function escalationErrorMessage(event: Extract<ExternalEvent, { kind: "escalate" }>): string {
  if (event.ask.kind !== "request") {
    return `unhandled "${event.ask.kind}" reached the run root`;
  }
  if (event.ask.request === PANIC_REQUEST) {
    const argument = event.ask.argument;
    const message =
      argument?.kind === "record" && argument.fields.msg?.kind === "string"
        ? argument.fields.msg.value
        : "(no message)";
    return `panic: ${message}`;
  }
  return `unhandled request "${event.ask.request}" reached the run root`;
}
