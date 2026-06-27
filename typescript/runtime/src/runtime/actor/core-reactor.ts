// CoreReactor: the engine as a reactor. It runs the IR — owning the project's `ProjectStore` (the loaded
// instances + shared scopes) and the delegation routing graph (which instance issued / handles each
// delegation) — and reacts to the external events a delegation's two halves exchange: a `delegate` summons a
// child instance, an ack/escalate resumes the proxying `DelegateThread`, a `terminate` cancels a subtree.
// Each `react` drives one instance's internal turn to quiescence, `send`s the events it produced, and stages
// the turn's persistence (the instance's Layer 2 + the Layer 1 rows it owns) for the substrate to commit.
//
// Ownership is caller-side: core owns a *sub-call* delegation row (it is the caller) and *all* escalation
// rows (it is always the raiser); it records each row's transitions at the point it acts as caller / raiser
// (open when it issues a delegate, cancelling when it issues a terminate, done / gone when it receives the
// ack, escalation-open when it escalates, answered when the answer returns). A *run* delegation is owned by
// the api root — core never inspects it; a run-root instance records `callerReactor = api` (the summoning
// delegate's `from`), so a reply it emits routes to `api` without core inferring it. FFI completions arrive
// via `reactFfi` until the FFI reactor lands.

import { delegateProxyOf, relayEscalate, resumeEscalation } from "../engine/common.js";
import { makeStepContext, type PrimRunner, type StepContext } from "../engine/context.js";
import { drive } from "../engine/drive.js";
import { unreachableOwnedScopes } from "../engine/gc.js";
import { createInstance, isInstanceComplete, teardownInstance } from "../engine/instance.js";
import { rebuildScopeOwnerIndex } from "../engine/scope.js";
import type { CoreInstance, ProjectStore } from "../engine/types.js";
import { isUserFacingRequest } from "../escalation-filter.js";
import {
  agentSnapshot,
  calleeReactorForTarget,
  type DelegateTarget,
  type ExternalEvent,
  escalateValue,
  type InternalEvent,
  type ReactorName,
} from "../event/types.js";
import {
  type InstanceId,
  newInstanceId,
  type ProjectId,
  type ScopeId,
  type SnapshotId,
} from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import { isTransientError, messageOf } from "./failure.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { serializeCoreInstance } from "./persistence-codec.js";
import { Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";

/** Where this turn's engine continuation (Layer 2) goes when the substrate commits: the still-running
 *  instance is persisted (its scopes flush separately through the pool), a completed / torn-down one is
 *  dropped (cascade), or the turn touched no instance (`none`). */
type TurnLayer2 =
  | { kind: "none" }
  | { kind: "persist"; instance: CoreInstance }
  | { kind: "drop"; instanceId: InstanceId };

export class CoreReactor extends Reactor {
  readonly name: ReactorName = "core";

  /** This turn's Layer 2 + issuer, set by `runTurnWith` and consumed by `persist`. Reset at each react. */
  private turnLayer2: TurnLayer2 = { kind: "none" };
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

  /** React to one external event a delegation routes to a core instance: summon a child (`delegate`), resume
   *  the proxying `DelegateThread` (`delegateAck` / `terminateAck` from a *core* caller), relay an escalation
   *  inward (`escalate`), answer the raiser (`escalateAck`), or cancel a subtree (`terminate`). */
  async react(event: ExternalEvent): Promise<void> {
    this.beginTurn();
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

  currentTurnOwner(): InstanceId {
    if (this.turnOwnerId === undefined) {
      throw new Error("CoreReactor.currentTurnOwner read with no turn instance (engine bug)");
    }
    return this.turnOwnerId;
  }

  /** Stage this turn's persistence: write the still-running instance before the Layer 1 rows that reference
   *  it; for a completed instance, write its terminal Layer 1 rows first, then drop it (the cascade removes
   *  what it owned). */
  async persist(tx: PersistenceTx): Promise<void> {
    const layer2 = this.turnLayer2;
    // Stage this turn's instance change for the base, then let it write the whole generic half (envelope +
    // this reactor's delegations / escalations + drop). The core extension is added after, on its own port.
    if (layer2.kind === "persist")
      this.markInstance(layer2.instance.id, {
        delegationId: layer2.instance.delegationId,
        status: layer2.instance.status,
      });
    else if (layer2.kind === "drop") this.markInstanceDropped(layer2.instanceId);
    await this.persistBase(tx.base);
    if (layer2.kind === "persist")
      await tx.core.putCoreInstance(serializeCoreInstance(this.projectId, layer2.instance));
  }

  private beginTurn(): void {
    this.turnLayer2 = { kind: "none" };
  }

  /** Drop all warm engine state (so reactivation rebuilds it from durable rows after a poisoned commit). */
  reset(): void {
    super.reset();
    this.store.instances = {};
    this.store.scopes = {};
    this.store.scopesByOwner = new Map();
    this.store.nextScopeId = 0;
    this.store.blobs = {};
    this.turnLayer2 = { kind: "none" };
    this.turnOwnerId = undefined;
  }

  // ─── reactivation (rebuilt from durable rows; called by the actor's reactivate) ─────────────────

  /** Reload core's own warm state from durable rows: the engine store + routing (each surviving
   *  `DelegateThread` names its delegation's caller; each instance's `delegationId` names its child), the
   *  live delegations it issued (`from = core`, its sub-calls), and the open escalations it raised
   *  (`from = core` — it is the raiser of all of them, so it can mark them answered). Each set is
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
        this.acceptDelegation(instance.delegationId, instance.id);
      }
    }
    // The delegations core issued and the escalations it raised reload through the base, uniformly.
    await this.loadBase(loader.base);
  }

  // ─── delegate / delegateAck ─────────────────────────────────────────────────────────────────

  private async onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): Promise<void> {
    // Only named / closure targets route to core; an external target goes to the ffi reactor, never here.
    // Resolving the target reads the IR. A *deterministic* resolution failure (a missing module / unknown
    // agent — e.g. a bad qualified name from a run command) is a program failure, so fail it as a panic to the
    // caller (an unhandled panic fails the run). A *transient* infra failure (a `TransientError` — an IR DB
    // read blip) is NOT a program failure: rethrow it so the substrate retries the delegate from durable state
    // (turning it into a panic would wrongly fail the run forever). No instance is born here, so the panic's
    // outbox issuer is a throwaway id (the outbox issuer is not a foreign key).
    let resolved: { agentBlockId: number; capturedScopeId: ScopeId | null; snapshot: SnapshotId };
    try {
      await this.ir.preload(agentSnapshot(event.target));
      resolved = this.resolveTarget(event.target);
    } catch (error) {
      if (isTransientError(error)) throw error;
      this.turnOwnerId = newInstanceId();
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
    // Record the handled delegation (the callee-side index → this child instance), so an inbound terminate /
    // escalateAck for it finds the child. The caller-side delegation row was already opened by its caller
    // (core's issuing turn, or the api root's startRun); this turn only summons the child and runs it.
    this.acceptDelegation(event.delegation, instance.id);
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }]);
  }

  /** A core sub-call returned: record the delegation `done`, then hand its value to the caller's pending
   *  proxy slot. The caller is resolved from the routing graph (gone ⇒ the delegation already cascaded away,
   *  so there is nothing to record or resume). */
  private async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): Promise<void> {
    const caller = this.coreInstance(this.callerInstanceOf(event.delegation));
    if (caller === undefined) return;
    this.transitionDelegation(event.delegation, "done", { result: event.value });
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
   *  so it bubbles toward a handle (or escapes again as a fresh escalate). */
  private async onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): Promise<void> {
    const caller = this.coreInstance(this.callerInstanceOf(event.delegation));
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

  /** The answer to a core-raised escalation reached its raiser: mark the escalation answered and hand the
   *  value to the raiser's Agent root in external vocabulary `(escalation, value)`; the Agent maps it back to
   *  the internal askId and re-enters it. (The raiser is always a `core` instance — the api root never
   *  raises.) */
  private async onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
  ): Promise<void> {
    const instance = this.coreInstance(this.handledInstanceOf(event.delegation));
    if (instance === undefined) return;
    this.answerEscalation(event.escalation, event.value);
    await this.runTurnWith(instance, (ctx) => resumeEscalation(ctx, event.escalation, event.value));
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  private async onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): Promise<void> {
    const child = this.coreInstance(this.handledInstanceOf(event.delegation));
    if (child === undefined) return;
    child.status = "cancelling";
    // The delegation's `cancelling` state is recorded by the caller (the core caller's cancel turn that
    // emitted this terminate, or the api root's cancelRun), not here on the callee side.
    await this.runTurn(child, [{ kind: "cancel", target: child.rootThreadId }]);
  }

  /** A core sub-call's terminate cascade confirmed: record the delegation `gone`, retire the proxy, and
   *  cancelAck the caller's parent so the cancel cascade continues. */
  private async onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
  ): Promise<void> {
    const caller = this.coreInstance(this.callerInstanceOf(event.delegation));
    if (caller === undefined) return;
    this.transitionDelegation(event.delegation, "gone");
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
    // Route each routing-less engine outbound (a reply to its summoner, a request to its callee) and record
    // the Layer 1 row core owns as caller / raiser — the receiving side (done / gone / answered) is recorded
    // in the react handlers.
    for (const event of ctx.buffers.outbound) {
      this.recordOutbound(event, instance);
      this.send(event);
    }
    // DB reflection at the turn boundary. A completed instance is dropped (the cascade reclaims the scopes it
    // still owns; the ones its result released to in-transit survive — the receiver reowns them, the pool
    // re-writes them). A still-running one is persisted, and the pool flushes the scopes it touched (the
    // engine mutates them in place, so the turn marks the instance's scopes dirty wholesale). The `delegateAck`
    // result's resources were already released to in-transit by the base-class `send`.
    if (isInstanceComplete(instance)) {
      if (instance.delegationId !== null) this.dropHandled(instance.delegationId);
      teardownInstance(this.store, instance.id);
      this.turnLayer2 = { kind: "drop", instanceId: instance.id };
    } else {
      // Intra-instance GC: reclaim the scopes this instance owns but no longer references (a completed
      // sub-thread's scope, unless its result captured it). Free them before flushing the survivors.
      for (const dead of unreachableOwnedScopes(this.store, instance)) this.pool.free(dead);
      this.pool.markOwnedDirty(instance.id);
      this.turnLayer2 = { kind: "persist", instance };
    }
  }

  /** Record the Layer 1 transition an engine outbound implies on the side core owns — caller for a `delegate`
   *  it issues / `terminate` it sends, raiser for a user-facing `escalate`. The escalation row's `peer` is the
   *  escalate's already-routed destination (`event.to`). (done / gone / answered are recorded by the receiving
   *  caller / raiser in the react handlers.) */
  private recordOutbound(event: ExternalEvent, instance: CoreInstance): void {
    switch (event.kind) {
      case "delegate":
        // The callee: a core sub-call, or — for an `external` target — the ffi reactor (an external call is a
        // delegate to ffi, owned by core just like a sub-call). The run path delegates from the api root, not
        // here, so `from` is always core. The issued row's `caller` (read back via `callerInstanceOf`) is the
        // single record of who issued it — no parallel caller map.
        this.openDelegation(event.delegation, {
          caller: instance.id,
          peer: calleeReactorForTarget(event.target),
          target: event.target,
          argument: event.argument,
        });
        break;
      case "terminate":
        this.transitionDelegation(event.delegation, "cancelling");
        break;
      case "escalate":
        // Open a durable escalation row only for a user-facing request — one a user can answer. A panic /
        // control escape reaching the run root fails the run (recorded on the run delegation, not as an
        // answerable escalation), so it gets no row: an open escalation addressed to `api` is then answerable
        // by construction, and the api root needs no re-classification on load. `delegation` is the raiser's
        // (the run, when `to` is api).
        if (event.ask.kind === "request" && isUserFacingRequest(event.ask.request)) {
          this.openEscalation(event.escalation, {
            raiser: instance.id,
            peer: event.to,
            delegation: event.delegation,
            request: event.ask.request,
            argument: event.ask.argument,
          });
        }
        break;
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
