// CoreReactor: the engine as a reactor. It runs the IR — owning the project's `ProjectStore` (the loaded
// instances + shared scopes) and the delegation routing graph (which instance issued / handles each
// delegation) — and reacts to the external events a delegation's two halves exchange: a `delegate` summons a
// child instance, an ack/escalate resumes the proxying `DelegateThread`, a `terminate` cancels a subtree.
// Each `react` drives one instance's internal turn to quiescence and returns it as a `Reaction` for the
// substrate to commit; the reactor itself persists nothing (see docs/2026-06-25-reactor-bus-redesign.md).
//
// The api root (a run's caller / a user escalation's sink) is a sibling reactor — this never inspects it
// beyond the routing sentinel `isRunDelegation` (a delegation whose caller is the api root). FFI completions
// still arrive here via `reactFfi` until the FFI reactor lands (R3).

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
import type { DelegateTarget, ExternalEvent, FfiResult, InternalEvent } from "../event/types.js";
import type { ExternalRunner } from "../external/runner.js";
import type { DelegationId, InstanceId, ProjectId, ScopeId, SnapshotId } from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { OpenEscalation } from "./api-reactor.js";
import type { PersistedOpenEscalation, ProjectSnapshot } from "./persistence.js";
import { Reactor } from "./reactor.js";
import {
  type EntityTransition,
  type Layer2Commit,
  outboundTransitions,
  type Reaction,
} from "./turn-commit.js";

export class CoreReactor extends Reactor {
  private readonly store: ProjectStore = createProjectStore();
  /** A pending delegate's caller instance, for routing its delegateAck / escalate home (the `delegations`
   *  row's caller). A run delegation's caller is the api root (the routing sentinel `isRunDelegation`). */
  private readonly delegationCaller: Record<DelegationId, InstanceId> = {};
  /** A delegation's spawned child instance — for routing a `terminate` to it, and an `escalateAck` back to
   *  the raiser (the escalating child is the delegation's child, so this is its raiser too). */
  private readonly delegationChild: Record<DelegationId, InstanceId> = {};

  constructor(
    private readonly projectId: ProjectId,
    private readonly ir: IrSource,
    private readonly prims: PrimRunner,
    private readonly blobs: BlobStore,
    private readonly external: ExternalRunner,
    /** The api management root's id — both the routing sentinel (a run's caller) and the borrowed name of an
     *  empty consume's (instance-less) turn. */
    private readonly apiRootId: InstanceId,
  ) {
    super();
  }

  /** React to one external event a delegation routes to a core instance: summon a child (`delegate`), resume
   *  the proxying `DelegateThread` (`delegateAck` / `escalate` / `terminateAck` from a *core* caller), relay
   *  an answer inward (`escalateAck`), or cancel a subtree (`terminate`). The caller-side legs resolve their
   *  caller from the routing graph (the dispatcher routes a *run*'s caller-side legs to the api root instead,
   *  so those never reach here). */
  react(event: ExternalEvent): Promise<Reaction> {
    switch (event.kind) {
      case "delegate":
        return this.onDelegate(event);
      case "delegateAck":
        return this.onDelegateAck(event);
      case "escalate":
        return this.onEscalate(event);
      case "escalateAck":
        return this.onEscalateAck(event);
      case "terminate":
        return this.onTerminate(event);
      case "terminateAck":
        return this.onTerminateAck(event);
    }
  }

  // ─── routing graph (queried by the dispatcher; the api root sets its run edges through here) ─────

  /** Whether `delegation` was issued by the api management root (a run) rather than a core caller (a
   *  sub-call) — the one place the api|core routing boundary is decided. */
  isRunDelegation(delegation: DelegationId): boolean {
    return this.delegationCaller[delegation] === this.apiRootId;
  }

  /** Drop a finished delegation's child edge (a terminal ack ends it; an `escalate` keeps it so the eventual
   *  `escalateAck` still finds the raiser). */
  dropChildEdge(delegation: DelegationId): void {
    delete this.delegationChild[delegation];
  }

  /** Record / drop a run delegation the api root issues / finishes (its caller is the api root). */
  openRunDelegation(delegation: DelegationId): void {
    this.delegationCaller[delegation] = this.apiRootId;
  }
  closeRunDelegation(delegation: DelegationId): void {
    delete this.delegationCaller[delegation];
  }

  // ─── reactivation (rebuilt from durable rows; called by the actor's reactivate) ─────────────────

  /** Reload the engine store and rebuild the routing graph from a project snapshot: the live Layer 1
   *  delegation edges give every delegation its caller (in particular the api root's run delegations, which
   *  have no `DelegateThread` to rebuild from); each surviving `DelegateThread` re-establishes a freshly
   *  issued delegation whose child / Layer 1 row a crash may have preceded; the undrained outbox's delegate
   *  issuers cover one produced but not yet consumed. An instance's own `delegationId` names its child. */
  loadState(snapshot: ProjectSnapshot): void {
    this.store.instances = snapshot.instances;
    this.store.scopes = snapshot.scopes;
    this.store.nextScopeId = snapshot.nextScopeId;
    for (const [delegation, caller] of Object.entries(snapshot.delegations)) {
      this.delegationCaller[delegation as DelegationId] = caller;
    }
    for (const instance of Object.values(this.store.instances)) {
      if (instance.delegationId !== null) {
        this.delegationChild[instance.delegationId] = instance.id;
      }
      for (const thread of Object.values(instance.threads)) {
        if (thread.kind === "delegate") this.delegationCaller[thread.delegationId] = instance.id;
      }
    }
    for (const message of snapshot.pendingOutbox) {
      if (message.event.kind === "delegate") {
        this.delegationCaller[message.event.delegation] = message.issuer;
      }
    }
  }

  /** The user-facing open escalations among `opens`: those a run root raised (their delegation's caller is
   *  the api root) and that are genuine requests (not panics / control escapes, which fail rather than wait).
   *  The api reactor rehydrates these so a run suspended awaiting a user's answer survives a restart. */
  userFacingOpenEscalations(
    opens: PersistedOpenEscalation[],
  ): Array<OpenEscalation & { run: DelegationId }> {
    const result: Array<OpenEscalation & { run: DelegationId }> = [];
    for (const open of opens) {
      const run = this.coreInstance(open.raiser)?.delegationId;
      if (run === undefined || run === null) continue;
      if (!this.isRunDelegation(run)) continue;
      if (!isUserFacingRequest(open.request)) continue;
      result.push({
        run,
        escalation: open.escalation,
        request: open.request as QualifiedName,
        argument: open.argument,
      });
    }
    return result;
  }

  /** After reactivation, re-dispatch every external (FFI) leaf still `open`: its in-flight dispatch was a
   *  private side channel (not a persisted event), so the process going down lost it. The durable
   *  `ExternalThread` row is the recovery handle — key + argument are re-derived from its block + scope.
   *  Completions re-enter through the serial mailbox exactly like a first dispatch. */
  async resumeInFlightExternals(): Promise<void> {
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

  // ─── delegate / delegateAck ─────────────────────────────────────────────────────────────────

  private async onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): Promise<Reaction> {
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
    return this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }], open);
  }

  /** A core sub-call returned: hand its value to the caller's pending proxy slot. The caller is resolved from
   *  the routing graph (gone ⇒ a bare consume); its child edge was already dropped by the dispatcher. */
  private async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): Promise<Reaction> {
    const caller = this.coreInstance(this.delegationCaller[event.delegation]);
    if (caller === undefined) return this.consume();
    delete this.delegationCaller[event.delegation];
    // Claim any resources the returned value carries up (a returned closure's captured scope chain, a
    // returned blob — set in-transit when the child retired): they now belong to this caller, which is
    // about to bind the value.
    reownResources(this.store, caller.id, event.value);
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) {
      return this.consume();
    }
    delete caller.threads[proxy.id];
    return this.runTurn(caller, [
      { kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value },
    ]);
  }

  // ─── escalate / escalateAck (a request / control ask crossing the instance boundary) ────────────

  /** A sub-call's escalation reached a core caller: re-raise it inside the caller from the proxy's position
   *  so it bubbles toward a handle. */
  private onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): Promise<Reaction> {
    const caller = this.coreInstance(this.delegationCaller[event.delegation]);
    const proxy = caller !== undefined ? delegateProxyOf(caller, event.delegation) : undefined;
    if (caller === undefined || proxy === undefined) return Promise.resolve(this.consume());
    // The relay echoes the raiser's `(delegation, escalation)` so its eventual `escalateAck` finds its way home.
    return this.runTurnWith(caller, (ctx) => {
      relayEscalate(ctx, proxy.id, event.escalation, event.ask);
    });
  }

  private onEscalateAck(event: Extract<ExternalEvent, { kind: "escalateAck" }>): Promise<Reaction> {
    // The escalating child is the delegation's child, so it is also the raiser. Hand the answer to its
    // Agent root in external vocabulary `(escalation, value)`; the Agent maps the escalation back to its
    // internal askId and re-enters it as an askAck. The reactor never names an inner thread. (The raiser is
    // always a `core` instance — the api root never raises.)
    const instance = this.coreInstance(this.delegationChild[event.delegation]);
    if (instance === undefined) return Promise.resolve(this.consume());
    // Mark the escalation answered in this same turn (the api root, or a relaying parent, runs no turn that
    // would emit the escalateAck as outbound, so record it here from the consumed event).
    return this.runTurnWith(
      instance,
      (ctx) => resumeEscalation(ctx, event.escalation, event.value),
      [{ kind: "escalation-answered", escalation: event.escalation, answer: event.value }],
    );
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  private onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): Promise<Reaction> {
    const child = this.coreInstance(this.delegationChild[event.delegation]);
    if (child === undefined) return Promise.resolve(this.consume());
    child.status = "cancelling";
    // Cancel the root; once its subtree is torn down it emits terminateAck and retires the instance. Record
    // the delegation moving to `cancelling` in this same turn (so it holds even for an api-issued cancel,
    // which runs no turn of its own).
    return this.runTurn(
      child,
      [{ kind: "cancel", target: child.rootThreadId }],
      [{ kind: "delegation-cancelling", delegation: event.delegation }],
    );
  }

  /** A core sub-call's terminate cascade confirmed: retire the proxy and cancelAck the caller's parent so the
   *  cancel cascade continues (the caller is resolved from the routing graph; its child edge was already
   *  dropped by the dispatcher). */
  private onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
  ): Promise<Reaction> {
    const caller = this.coreInstance(this.delegationCaller[event.delegation]);
    if (caller === undefined) return Promise.resolve(this.consume());
    delete this.delegationCaller[event.delegation];
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) {
      return Promise.resolve(this.consume());
    }
    delete caller.threads[proxy.id];
    delete caller.cancelExits[proxy.id];
    return this.runTurn(caller, [
      { kind: "cancelAck", target: proxy.parent, callId: proxy.parentCallId },
    ]);
  }

  // ─── FFI completion (until the FFI reactor lands in R3) ─────────────────────────────────────────

  /** Feed an FFI completion back to the suspended `ExternalThread` it belongs to: a result resumes it
   *  (ack its parent → completes the call's instance → delegateAck), an error raises a panic, and an
   *  abort confirmation finishes a cancelling thread's graceful cancel. `null` when the completion is late
   *  (its instance / thread is gone) — there is no outbox row to consume either. */
  reactFfi(result: FfiResult): Promise<Reaction | null> {
    const instance = this.coreInstance(result.instance);
    if (instance === undefined) return Promise.resolve(null); // instance torn down — drop the late result
    const thread = instance.threads[result.thread];
    if (thread === undefined || thread.kind !== "external") return Promise.resolve(null);
    if (result.kind === "ffiCancelled" || thread.status === "cancelling") {
      // The thread is being aborted: any completion (the runner's `ffiCancelled`, or a real result/error
      // that raced the abort) finishes its graceful cancel. The value, if any, is discarded.
      return this.runTurnWith(instance, (ctx) => completeExternalAbort(ctx, thread.id));
    }
    if (result.kind === "ffiError") {
      // An FFI failure is a panic raised from the external leaf (it bubbles to a handler / fails the run).
      return this.runTurnWith(instance, (ctx) => raisePanic(ctx, thread, result.message));
    }
    if (thread.parent === null || thread.parentCallId === null) return Promise.resolve(null);
    delete instance.threads[thread.id];
    return this.runTurn(instance, [
      { kind: "callAck", target: thread.parent, callId: thread.parentCallId, value: result.value },
    ]);
  }

  // ─── one instance turn ────────────────────────────────────────────────────────────────────────

  private runTurn(
    instance: CoreInstance,
    initial: InternalEvent[],
    extraTransitions: EntityTransition[] = [],
  ): Promise<Reaction> {
    return this.runTurnWith(
      instance,
      (ctx) => {
        ctx.buffers.internalQueue.push(...initial);
      },
      extraTransitions,
    );
  }

  /** Drive one instance's turn after `seed` queues its initial internal events (directly, or via a helper
   *  that needs the StepContext such as `relayEscalate`), then return the turn as a `Reaction` for the
   *  substrate to commit. The Reaction carries the turn's Layer 2 (the instance's graph, persisted, or
   *  dropped if it completed) together with the Layer 1 entity transitions it implies — `extraTransitions`
   *  from the handler (a delegation it is opening / cancelling, an escalation it is answering) plus the ones
   *  its outbound events imply — and the outbound events to durably produce. */
  private async runTurnWith(
    instance: CoreInstance,
    seed: (ctx: StepContext) => void,
    extraTransitions: EntityTransition[] = [],
  ): Promise<Reaction> {
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
    return { instanceId: instance.id, layer2, transitions, outbound };
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

  /** The loaded core instance under `id` (the engine store holds only core instances). */
  private coreInstance(id: InstanceId | undefined): CoreInstance | undefined {
    return id !== undefined ? this.store.instances[id] : undefined;
  }

  /** An empty turn: a handler whose event needs no engine turn (its target is already gone) returns this so
   *  the dispatcher still consumes the inbound row. The instance it names is irrelevant — `layer2: none`
   *  touches none — so it borrows the api root id. */
  private consume(): Reaction {
    return { instanceId: this.apiRootId, layer2: { kind: "none" }, transitions: [], outbound: [] };
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
