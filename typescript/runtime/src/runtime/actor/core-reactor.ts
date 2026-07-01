// CoreReactor: the engine as a reactor. It runs the IR — owning the project's `ProjectStore` (the loaded
// instances + shared scopes) and the delegation routing graph (which instance issued / handles each
// delegation) — and reacts to the external events a delegation's two halves exchange: a `delegate` summons a
// child instance, an ack/escalate resumes the proxying `DelegateThread`, a `terminate` cancels a subtree.
// Each `react` drives one instance's internal turn to quiescence, `send`s the events it produced, and stages
// the turn's persistence (the instance's Layer 2 + the Layer 1 rows it owns) for the substrate to commit.
//
// Ownership is caller-side, but the base now derives every Layer 1 edge change from the events core emits /
// receives: core just emits (a sub-call `delegate`, a `terminate`, a user-facing `escalate`) and the base
// opens / cancels / retires the row. So core holds no delegation / escalation bookkeeping — it only creates /
// tears down instances, drives their turns, and implements the per-event hooks (`onDelegate` etc.) that resume
// the proxying `DelegateThread` from the base-resolved caller / callee / raiser. A *run* delegation is owned by
// the api root — a run-root instance records `callerReactor = api` (the summoning delegate's `from`), so a
// reply it emits routes to `api` without core inferring it.

import { delegateProxyOf, relayEscalate, resumeEscalation } from "../engine/common.js";
import { makeStepContext, type PrimRunner, type StepContext } from "../engine/context.js";
import { drive } from "../engine/drive.js";
import { unreachableOwnedScopes } from "../engine/gc.js";
import { createInstance, isInstanceComplete, teardownInstance } from "../engine/instance.js";
import { rebuildScopeOwnerIndex } from "../engine/scope.js";
import type { CoreInstance, ProjectStore } from "../engine/types.js";
import {
  agentSnapshot,
  type DelegateTarget,
  type ExternalEvent,
  escalateValue,
  type InternalEvent,
  type ReactorName,
} from "../event/types.js";
import type { InstanceId, ProjectId, ScopeId, SnapshotId } from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import { isTransientError, messageOf } from "./failure.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { serializeCoreInstance } from "./persistence-codec.js";
import { Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";

export class CoreReactor extends Reactor {
  readonly name: ReactorName = "core";

  /** The instances this turn touched (or, if a future substrate ever batches several turns into one commit,
   *  the turns since the last persist). `runTurnWith` adds each instance it drove; `persist` reconciles them
   *  against the engine store (the source of truth) — one still present is upserted, one already torn down is
   *  dropped — then clears the set. Tracking the change as a set + store lookup (rather than a single per-turn
   *  value) keeps the dirty state from ever drifting from the store. */
  private readonly touchedInstances = new Set<InstanceId>();
  private turnOwnerId: InstanceId | undefined;

  constructor(
    private readonly projectId: ProjectId,
    private readonly ir: IrSource,
    private readonly prims: PrimRunner,
    private readonly blobs: BlobStore,
    /** The project's shared scope store (also wrapped by the `ResourcePool` below), so the engine and the
     *  pool touch the same scopes in place. */
    private readonly store: ProjectStore,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  currentTurnOwner(): InstanceId {
    if (this.turnOwnerId === undefined) {
      throw new Error("CoreReactor.currentTurnOwner read with no turn instance (engine bug)");
    }
    return this.turnOwnerId;
  }

  /** Stage this turn's persistence: reconcile each instance this turn touched against the engine store (the
   *  source of truth). One still present is upserted — its generic envelope before the Layer 1 rows that
   *  reference it (the base orders that), its core Layer 2 extension after; one already torn down is dropped
   *  (the cascade removes what it owned). */
  async persist(tx: PersistenceTx): Promise<void> {
    // Stage each touched instance's change for the base, then let it write the whole generic half (envelopes +
    // this reactor's delegations / escalations + drops) in FK order. The core Layer 2 extension is added after,
    // on its own port, for the instances still present.
    for (const id of this.touchedInstances) {
      const instance = this.store.instances[id];
      if (instance !== undefined)
        this.markInstance(id, {
          delegationId: instance.delegationId,
          callerReactor: instance.callerReactor,
          status: instance.status,
        });
      else this.markInstanceDropped(id);
    }
    await this.persistBase(tx.base);
    for (const id of this.touchedInstances) {
      const instance = this.store.instances[id];
      if (instance !== undefined)
        await tx.core.putCoreInstance(serializeCoreInstance(this.projectId, instance));
    }
    this.touchedInstances.clear();
  }

  /** Drop all warm engine state (so reactivation rebuilds it from durable rows after a poisoned commit). */
  reset(): void {
    super.reset();
    this.store.instances = {};
    this.store.scopes = {};
    this.store.scopesByOwner = new Map();
    this.store.nextScopeId = 0;
    this.store.blobs = {};
    this.touchedInstances.clear();
    this.turnOwnerId = undefined;
  }

  // ─── reactivation (rebuilt from durable rows; called by the actor's reactivate) ─────────────────

  /** Reload core's own warm state from durable rows: the engine store + routing (each surviving
   *  `DelegateThread` names its delegation's caller; each instance's `delegationId` names its child), the
   *  live delegations it issued (`from = core`, its sub-calls), and the open escalations it raised
   *  (`from = core` — so the base can retire them when their `escalateAck` returns). Each set is
   *  self-selected from the loader; no cross-reactor classification. */
  async load(loader: Loader): Promise<void> {
    const engine = await loader.core.engine();
    this.store.instances = engine.instances;
    this.store.scopes = engine.scopes;
    this.store.blobs = engine.blobs;
    this.store.nextScopeId = engine.nextScopeId;
    // The loaded scopes replaced the map wholesale; rebuild the owner index over them before any sweep reads it.
    rebuildScopeOwnerIndex(this.store);
    // Re-seed the handled-delegation index (delegation → child instance) from each instance's own summoning
    // delegation — the instance (its payload) is the source of truth. The caller side (the proxy to resume on
    // an ack) needs no rebuild here: it reads the issued delegations reloaded just below (`callerInstanceOf`).
    for (const instance of Object.values(this.store.instances)) {
      if (instance.delegationId !== null) {
        this.acceptDelegation(instance.delegationId, instance.id, instance.callerReactor);
      }
    }
    // The delegations core issued and the escalations it raised reload through the base, uniformly.
    await this.loadBase(loader.base);
  }

  // ─── delegate / delegateAck ─────────────────────────────────────────────────────────────────

  protected async onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): Promise<void> {
    // Only named / closure targets route to core; an external target goes to the ffi reactor, never here.
    // Resolving the target reads the IR. A *deterministic* resolution failure (a missing module / unknown
    // agent — e.g. a bad qualified name from a run command) is a program failure, so fail it as a panic to the
    // caller (an unhandled panic fails the run). A *transient* infra failure (a `TransientError` — an IR DB
    // read blip) is NOT a program failure: rethrow it so the substrate retries the delegate from durable state
    // (turning it into a panic would wrongly fail the run forever). A panic opens no row and needs no turn
    // owner, so the failure path births no instance.
    let resolved: { agentBlockId: number; capturedScopeId: ScopeId | null; snapshot: SnapshotId };
    try {
      await this.ir.preload(agentSnapshot(event.target));
      resolved = this.resolveTarget(event.target);
    } catch (error) {
      if (isTransientError(error)) throw error;
      this.raisePanic(event.delegation, messageOf(error), event.from);
      return;
    }
    const instance = createInstance(this.store, {
      delegationId: event.delegation,
      // The summoner's reactor: a reply this instance emits routes back here (core for a sub-call, api for a
      // run root) — recorded now from the delegate's `from`, never re-inferred.
      callerReactor: event.from,
      target: event.target,
      argument: event.argument,
      agentBlockId: resolved.agentBlockId,
      capturedScopeId: resolved.capturedScopeId,
      snapshotId: resolved.snapshot,
      ...(event.generics !== undefined ? { ambientGenerics: event.generics } : {}),
    });
    // Record the handled delegation (the callee-side index → this child instance + its summoner), so an inbound
    // terminate / escalateAck for it finds the child and its replies route back. The caller-side delegation row
    // was already opened by its caller (core's issuing turn, or the api root's startRun); this turn only summons
    // the child and runs it.
    this.acceptDelegation(event.delegation, instance.id, event.from);
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }]);
  }

  /** A core sub-call returned: the base has already retired the delegation; hand its value to the caller's
   *  pending proxy slot. `context.caller` is the delegation's caller (undefined ⇒ it already cascaded away,
   *  so there is nothing to resume). */
  protected async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    context: { caller: InstanceId | undefined },
  ): Promise<void> {
    const caller = this.coreInstance(context.caller);
    if (caller === undefined) return;
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    // Claim the resources the returned value carries up (a returned closure's captured scope chain, a
    // returned blob — released to in-transit when the child sent its delegateAck): they now belong to this
    // caller. Reown only after the proxy is found — i.e. the value is actually delivered into the caller's
    // resume turn (whose scope re-flush persists the new ownership and whose GC can later reclaim it). If the
    // proxy is gone (the branch was cancelled) the value is undeliverable, so we do not reown it onto a
    // caller that would never reference it (which would leave a durable scope owned-but-unreachable).
    this.reownIncoming(event.value, caller.id);
    delete caller.threads[proxy.id];
    await this.runTurn(caller, [
      { kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value },
    ]);
  }

  // ─── escalate / escalateAck (a request / control ask crossing the instance boundary) ────────────

  /** A sub-call's escalation reached a core caller: re-raise it inside the caller from the proxy's position
   *  so it bubbles toward a handle (or escapes again as a fresh escalate). `context.caller` is the escalating
   *  child's caller. */
  protected async onEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    context: { caller: InstanceId | undefined },
  ): Promise<void> {
    const caller = this.coreInstance(context.caller);
    const proxy = caller !== undefined ? delegateProxyOf(caller, event.delegation) : undefined;
    if (caller === undefined || proxy === undefined) return;
    // The escalation's carried value (a request argument, or a control escape's value) was released to
    // in-transit when the child sent it; reown it to this caller, which now holds it as the ask is re-raised
    // inward from the proxy's position.
    const carried = escalateValue(event.ask);
    if (carried !== null) this.reownIncoming(carried, caller.id);
    await this.runTurnWith(caller, (ctx) => {
      relayEscalate(ctx, proxy.id, event.escalation, event.ask);
    });
  }

  /** The answer to a core-raised escalation reached its raiser: the base has already retired the escalation
   *  row; hand the value to the raiser's Agent root in external vocabulary `(escalation, value)`, which maps it
   *  back to the internal askId and re-enters it. `context.raiser` is the raiser instance. */
  protected async onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
    context: { raiser: InstanceId | undefined },
  ): Promise<void> {
    const instance = this.coreInstance(context.raiser);
    if (instance === undefined) return;
    await this.runTurnWith(instance, (ctx) => resumeEscalation(ctx, event.escalation, event.value));
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  protected async onTerminate(
    _event: Extract<ExternalEvent, { kind: "terminate" }>,
    context: { callee: InstanceId | undefined },
  ): Promise<void> {
    const child = this.coreInstance(context.callee);
    if (child === undefined) return;
    child.status = "cancelling";
    // The delegation's `cancelling` state is recorded by the base on the caller's `send(terminate)`, not here
    // on the callee side.
    await this.runTurn(child, [{ kind: "cancel", target: child.rootThreadId }]);
  }

  /** A core sub-call's terminate cascade confirmed: the base has retired the delegation; retire the proxy and
   *  cancelAck the caller's parent so the cancel cascade continues. `context.caller` is the delegation's caller. */
  protected async onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    context: { caller: InstanceId | undefined },
  ): Promise<void> {
    const caller = this.coreInstance(context.caller);
    if (caller === undefined) return;
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    delete caller.threads[proxy.id];
    delete caller.cancelExits[proxy.id];
    await this.runTurn(caller, [
      { kind: "cancelAck", target: proxy.parent, callId: proxy.parentCallId },
    ]);
  }

  // ─── one instance turn ────────────────────────────────────────────────────────────────────────

  private runTurn(instance: CoreInstance, initial: InternalEvent[]): Promise<void> {
    return this.runTurnWith(instance, (ctx) => {
      ctx.buffers.internalQueue.push(...initial);
    });
  }

  /** Drive one instance's turn after `seed` queues its initial internal events, then `send` the external
   *  events it produced (recording the caller-side / raiser-side Layer 1 transitions they imply) and stage
   *  the instance's Layer 2 for `persist`. */
  private async runTurnWith(
    instance: CoreInstance,
    seed: (ctx: StepContext) => void,
  ): Promise<void> {
    const snapshot = agentSnapshot(instance.target);
    await this.ir.preload(snapshot);
    const ctx = makeStepContext({
      projectId: this.projectId,
      store: this.store,
      instance,
      ir: this.ir.access(snapshot, moduleOf(instance.target)),
      prims: this.prims,
      blobs: this.blobs,
      // Stamped as `from` on every event the engine emits; each emit site supplies its own `to` from edge
      // knowledge (the callee's reactor, or the summoner), so the harvest below only buffers routed events.
      reactorName: this.name,
    });
    seed(ctx);
    await drive(ctx);
    this.turnOwnerId = instance.id;
    // Emit each engine outbound (already routed by the emit edge); the base `send` derives the Layer 1 edge it
    // implies — opening this instance's delegation, cancelling it, or opening a user-facing escalation.
    for (const event of ctx.buffers.outbound) this.send(event);
    // DB reflection at the turn boundary. A completed instance is dropped (the cascade reclaims the scopes it
    // still owns; the ones its result released to in-transit survive — the receiver reowns them, the pool
    // re-writes them). A still-running one is persisted, and the pool flushes the scopes it touched (the
    // engine mutates them in place, so the turn marks the instance's scopes dirty wholesale). The `delegateAck`
    // result's resources were already released to in-transit by the base-class `send`.
    this.touchedInstances.add(instance.id);
    if (isInstanceComplete(instance)) {
      if (instance.delegationId !== null) this.dropHandled(instance.delegationId);
      teardownInstance(this.store, instance.id);
    } else {
      // Intra-instance GC: reclaim the scopes this instance owns but no longer references (a completed
      // sub-thread's scope, unless its result captured it). Free them before flushing the survivors.
      for (const dead of unreachableOwnedScopes(this.store, instance)) this.pool.free(dead);
      this.pool.markOwnedDirty(instance.id);
    }
  }

  /** The loaded core instance under `id` (the engine store holds only core instances). */
  private coreInstance(id: InstanceId | undefined): CoreInstance | undefined {
    return id !== undefined ? this.store.instances[id] : undefined;
  }

  private resolveTarget(target: DelegateTarget): {
    agentBlockId: number;
    capturedScopeId: ScopeId | null;
    snapshot: SnapshotId;
  } {
    switch (target.kind) {
      case "named":
        return {
          agentBlockId: this.ir.locate(target.snapshot, target.name).blockId,
          capturedScopeId: null,
          snapshot: target.snapshot,
        };
      case "closure":
        return {
          agentBlockId: target.blockId,
          capturedScopeId: target.scopeId,
          snapshot: target.snapshot,
        };
      case "external":
        // An external target is routed to the ffi reactor, never summoned as a core instance — core resolves
        // only the named / closure agents it runs.
        throw new Error("core cannot summon an external (ffi) target as an instance");
    }
  }
}

/** The module a delegate target's agent lives in (block ids are module-local). External targets run in the
 *  ffi reactor (no module), so a core instance never carries one. */
function moduleOf(target: DelegateTarget): string {
  switch (target.kind) {
    case "named":
      return moduleOfName(target.name);
    case "closure":
      return target.module;
    case "external":
      throw new Error("an external target has no module (it runs in the ffi reactor, not the IR)");
  }
}
