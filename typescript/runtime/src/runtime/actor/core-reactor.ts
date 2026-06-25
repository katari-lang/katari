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
// the api root — core never inspects it; it routes a run's reply back to `api` simply because the run has no
// in-core caller (`routeOf`). FFI completions arrive via `reactFfi` until the FFI reactor lands.

import type { QualifiedName } from "@katari-lang/types";
import { delegateProxyOf, raisePanic, relayEscalate, resumeEscalation } from "../engine/common.js";
import { makeStepContext, type PrimRunner, type StepContext } from "../engine/context.js";
import { drive } from "../engine/drive.js";
import { unreachableOwnedScopes } from "../engine/gc.js";
import { createInstance, isInstanceComplete, teardownInstance } from "../engine/instance.js";
import { readVariable } from "../engine/scope.js";
import { completeExternalAbort } from "../engine/thread-ops.js";
import type { CoreInstance, ProjectStore } from "../engine/types.js";
import { isUserFacingRequest } from "../escalation-filter.js";
import type {
  DelegateTarget,
  ExternalEvent,
  ExternalEventBody,
  FfiResult,
  InternalEvent,
  ReactorName,
} from "../event/types.js";
import type { ExternalRunner } from "../external/runner.js";
import type { DelegationId, InstanceId, ProjectId, ScopeId, SnapshotId } from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { OpenEscalation } from "./api-reactor.js";
import type { PersistedOpenEscalation, PersistenceTx, ProjectSnapshot } from "./persistence.js";
import { serializeInstance } from "./persistence-codec.js";
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

  /** A pending sub-call's caller instance, for routing its delegateAck / escalate home and finding its
   *  proxy. Set when core issues the `delegate`; absent for a run (the api root is the caller), which is
   *  exactly how `routeOf` distinguishes "reply to core" from "reply to api". */
  private readonly delegationCaller: Record<DelegationId, InstanceId> = {};
  /** A delegation's spawned child instance — for routing a `terminate` to it, and an `escalateAck` back to
   *  the raiser (the escalating child is the delegation's child, so this is its raiser too). */
  private readonly delegationChild: Record<DelegationId, InstanceId> = {};

  /** This turn's Layer 2 + issuer, set by `runTurnWith` and consumed by `persist`. Reset at each react. */
  private turnLayer2: TurnLayer2 = { kind: "none" };
  private turnOwnerId: InstanceId | undefined;

  constructor(
    private readonly projectId: ProjectId,
    private readonly ir: IrSource,
    private readonly prims: PrimRunner,
    private readonly blobs: BlobStore,
    private readonly external: ExternalRunner,
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
    if (layer2.kind === "persist") {
      await tx.putInstance(serializeInstance(this.projectId, layer2.instance));
    }
    await this.flushLayer1(tx);
    if (layer2.kind === "drop") await tx.dropInstance(layer2.instanceId);
  }

  private beginTurn(): void {
    this.turnLayer2 = { kind: "none" };
  }

  // ─── routing (rederived from the engine graph; the api root is never referenced) ────────────────

  /** The destination reactor for an engine-emitted event. A reply (delegateAck / escalate / terminateAck)
   *  routes to the delegation's caller reactor — `core` when this engine still has the caller instance (a
   *  sub-call), else `api` (a run, whose caller is the api root, which core does not model). A request leg
   *  (delegate / terminate / escalateAck) always targets `core` in v0.1.0 (a sub-callee / cancelled child /
   *  core raiser). */
  private routeOf(body: ExternalEventBody): ReactorName {
    switch (body.kind) {
      case "delegateAck":
      case "escalate":
      case "terminateAck":
        return this.delegationCaller[body.delegation] !== undefined ? "core" : "api";
      default:
        return "core";
    }
  }

  // ─── reactivation (rebuilt from durable rows; called by the actor's reactivate) ─────────────────

  /** Reload the engine store and rebuild routing from a snapshot. Each surviving `DelegateThread` names its
   *  delegation's caller (its own instance); each instance's `delegationId` names its child. Core then
   *  reloads the Layer 1 rows it owns: the live delegations whose caller is one of its instances (its
   *  sub-calls — run rows belong to the api root), and all open escalations (it is the raiser). */
  loadState(snapshot: ProjectSnapshot): void {
    this.store.instances = snapshot.instances;
    this.store.scopes = snapshot.scopes;
    this.store.nextScopeId = snapshot.nextScopeId;
    for (const instance of Object.values(this.store.instances)) {
      if (instance.delegationId !== null) this.delegationChild[instance.delegationId] = instance.id;
      for (const thread of Object.values(instance.threads)) {
        if (thread.kind === "delegate") this.delegationCaller[thread.delegationId] = instance.id;
      }
    }
    for (const row of snapshot.liveDelegations) {
      // Core owns a delegation iff its caller is one of core's instances (a sub-call); a run's caller is the
      // api root, which is not in this store, so the api reactor reloads it instead.
      if (this.store.instances[row.caller] !== undefined) {
        this.reloadDelegation(row.delegation, {
          caller: row.caller,
          target: row.target,
          argument: row.argument,
          state: row.state,
        });
      }
    }
    for (const open of snapshot.openEscalations) {
      this.reloadEscalation(open.escalation, {
        raiser: open.raiser,
        request: open.request,
        argument: open.argument,
      });
    }
  }

  /** The user-facing open escalations among `opens`: those a run root raised (their delegation has no
   *  in-core caller, so it is a run) and that are genuine requests (not panics / control escapes, which fail
   *  rather than wait). The api reactor rehydrates these so a suspended run survives a restart. */
  userFacingOpenEscalations(
    opens: PersistedOpenEscalation[],
  ): Array<OpenEscalation & { run: DelegationId }> {
    const result: Array<OpenEscalation & { run: DelegationId }> = [];
    for (const open of opens) {
      const run = this.coreInstance(open.raiser)?.delegationId;
      if (run === undefined || run === null) continue;
      // A run delegation is one with no in-core caller (its caller is the api root).
      if (this.delegationCaller[run] !== undefined) continue;
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
   *  `ExternalThread` row is the recovery handle — key + argument are re-derived from its block + scope. */
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
    // The delegation row was already opened by its caller (core's issuing turn, or the api root's startRun);
    // this turn only summons the child and runs it.
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }]);
  }

  /** A core sub-call returned: record the delegation `done`, then hand its value to the caller's pending
   *  proxy slot. The caller is resolved from the routing graph (gone ⇒ the delegation already cascaded away,
   *  so there is nothing to record or resume). */
  private async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): Promise<void> {
    const caller = this.coreInstance(this.delegationCaller[event.delegation]);
    if (caller === undefined) return;
    this.transitionDelegation(event.delegation, "done", { result: event.value });
    delete this.delegationCaller[event.delegation];
    // Claim the resources the returned value carries up (a returned closure's captured scope chain, a
    // returned blob — released to in-transit when the child sent its delegateAck): they now belong to this
    // caller. The caller's resume turn re-flushes its scopes, so the new ownership is persisted.
    this.reownIncoming(event.value, caller.id);
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    delete caller.threads[proxy.id];
    await this.runTurn(caller, [
      { kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value },
    ]);
  }

  // ─── escalate / escalateAck (a request / control ask crossing the instance boundary) ────────────

  /** A sub-call's escalation reached a core caller: re-raise it inside the caller from the proxy's position
   *  so it bubbles toward a handle (or escapes again as a fresh escalate). */
  private async onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): Promise<void> {
    const caller = this.coreInstance(this.delegationCaller[event.delegation]);
    const proxy = caller !== undefined ? delegateProxyOf(caller, event.delegation) : undefined;
    if (caller === undefined || proxy === undefined) return;
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
    const instance = this.coreInstance(this.delegationChild[event.delegation]);
    if (instance === undefined) return;
    this.answerEscalation(event.escalation, event.value);
    await this.runTurnWith(instance, (ctx) => resumeEscalation(ctx, event.escalation, event.value));
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  private async onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): Promise<void> {
    const child = this.coreInstance(this.delegationChild[event.delegation]);
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
    const caller = this.coreInstance(this.delegationCaller[event.delegation]);
    if (caller === undefined) return;
    this.transitionDelegation(event.delegation, "gone");
    delete this.delegationCaller[event.delegation];
    const proxy = delegateProxyOf(caller, event.delegation);
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    delete caller.threads[proxy.id];
    delete caller.cancelExits[proxy.id];
    await this.runTurn(caller, [
      { kind: "cancelAck", target: proxy.parent, callId: proxy.parentCallId },
    ]);
  }

  // ─── FFI completion (until the FFI reactor lands) ───────────────────────────────────────────────

  /** Feed an FFI completion back to the suspended `ExternalThread` it belongs to: a result resumes it
   *  (ack its parent → completes the call's instance → delegateAck), an error raises a panic, and an abort
   *  confirmation finishes a cancelling thread's graceful cancel. A no-op when the completion is late (its
   *  instance / thread is gone). */
  async reactFfi(result: FfiResult): Promise<void> {
    this.beginTurn();
    const instance = this.coreInstance(result.instance);
    if (instance === undefined) return; // instance torn down — drop the late result
    const thread = instance.threads[result.thread];
    if (thread === undefined || thread.kind !== "external") return;
    if (result.kind === "ffiCancelled" || thread.status === "cancelling") {
      // The thread is being aborted: any completion finishes its graceful cancel. The value is discarded.
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
    this.turnOwnerId = instance.id;
    // Stamp routing on the engine's routing-less outbound and record the Layer 1 rows core owns as caller /
    // raiser: opening a delegation it issues, cancelling one it terminates, opening an escalation it raises.
    // (done / gone / answered are recorded by the receiving caller / raiser, in the react handlers.)
    for (const body of ctx.buffers.outbound) {
      switch (body.kind) {
        case "delegate":
          this.delegationCaller[body.delegation] = instance.id;
          this.openDelegation(body.delegation, {
            caller: instance.id,
            target: body.target,
            argument: body.argument,
          });
          break;
        case "terminate":
          this.transitionDelegation(body.delegation, "cancelling");
          break;
        case "escalate":
          if (body.ask.kind === "request") {
            this.openEscalation(body.escalation, {
              raiser: instance.id,
              request: body.ask.request,
              argument: body.ask.argument,
            });
          }
          break;
      }
      this.send(body, this.routeOf(body));
    }
    // DB reflection at the turn boundary. A completed instance is dropped (the cascade reclaims the scopes it
    // still owns; the ones its result released to in-transit survive — the receiver reowns them, the pool
    // re-writes them). A still-running one is persisted, and the pool flushes the scopes it touched (the
    // engine mutates them in place, so the turn marks the instance's scopes dirty wholesale). The `delegateAck`
    // result's resources were already released to in-transit by the base-class `send`.
    if (isInstanceComplete(instance)) {
      if (instance.delegationId !== null) delete this.delegationChild[instance.delegationId];
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

  /** The loaded core instance under `id` (the engine store holds only core instances). */
  private coreInstance(id: InstanceId | undefined): CoreInstance | undefined {
    return id !== undefined ? this.store.instances[id] : undefined;
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
