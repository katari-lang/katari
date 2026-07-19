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
// its api-side run instance — a run-root core instance records `callerReactor = api` (the summoning delegate's
// `from`), so a reply it emits routes to `api` without core inferring it.

import { rebuildBlobOwnerIndex } from "../engine/blob.js";
import {
  delegateProxyOf,
  PANIC_REQUEST,
  panicArgument,
  relayEscalate,
  resumeEscalation,
} from "../engine/common.js";
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
import {
  type InstanceId,
  newEscalationId,
  type ProjectId,
  type ScopeId,
  type SnapshotId,
} from "../ids.js";
import { type IrSource, moduleOfName } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import {
  conformValue,
  fillGenericSchema,
  renderConformFailures,
  typeSubstitutionOf,
} from "../value/validation.js";
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
          runId: instance.runId,
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
    this.store.blobsByOwner = new Map();
    this.touchedInstances.clear();
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
    // The loaded scopes / blobs replaced their maps wholesale; rebuild the owner indexes over them before any
    // sweep (or the ownership hoist) reads them.
    rebuildScopeOwnerIndex(this.store);
    rebuildBlobOwnerIndex(this.store);
    // The delegations core issued and the escalations it raised reload through the base, uniformly. Do this
    // first so the handled-index rebuild below can read each child's caller INSTANCE off the reloaded
    // caller-side row (`callerInstanceOf`).
    await this.loadBase(loader.base);
    // Re-seed the handled-delegation index (delegation → child instance) from each instance's own summoning
    // delegation — the instance (its payload) is the source of truth. The caller side (the proxy to resume on
    // an ack) needs no rebuild here: it reads the issued delegations reloaded just above (`callerInstanceOf`).
    // The child's caller instance (the hoist target) is re-derived from that same caller-side row — present
    // for a core sub-call (core owns the row), `undefined` for a run root (the api owns it, and the run→api
    // boundary hoists nothing anyway).
    for (const instance of Object.values(this.store.instances)) {
      if (instance.delegationId !== null) {
        this.acceptDelegation(
          instance.delegationId,
          instance.id,
          instance.callerReactor,
          instance.runId,
          this.callerInstanceOf(instance.delegationId),
        );
      }
    }
  }

  // ─── delegate / delegateAck ─────────────────────────────────────────────────────────────────

  protected async onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): Promise<void> {
    // Dynamic dispatch (`call_agent`, a callee VALUE, a tool) is resolved where the call is EMITTED —
    // the engine's delegate operation, the FFI / webhook boundaries — so a delegate arriving here is
    // already a concrete named / closure target for core to summon. (An external target routes to its
    // own reactor, never here.)
    const target = event.target;
    const argument = event.argument;
    const generics = event.generics;
    // Resolving the target reads the IR. A *deterministic* resolution failure (a missing module / unknown
    // agent — a stale `$katari_agent` reference in a sub-call) is a program failure, so fail it to the caller as a
    // panic. A *transient* infra failure (a `TransientError` — an IR DB read blip) is NOT a program failure:
    // rethrow it so the substrate retries the delegate from durable state (failing it would wrongly fail the
    // run forever). The panic is an escalation like any other, so it opens a durable raiser-owned row — but
    // the callee is not born yet, so the row is owned by the delegate's ISSUER (`preInstanceRaiser`), always
    // a MORTAL sub-call caller (a run / inner delegate is validated at its boundary and never reaches here),
    // whose teardown cascades the row.
    let resolved: { agentBlockId: number; capturedScopeId: ScopeId | null; snapshot: SnapshotId };
    try {
      await this.ir.preload(agentSnapshot(target));
      resolved = this.resolveTarget(target);
    } catch (error) {
      if (isTransientError(error)) throw error;
      this.raisePanic(
        event.delegation,
        messageOf(error),
        event.from,
        event.run,
        this.preInstanceRaiser(event),
      );
      return;
    }
    // The delegate acceptance check: the argument must conform to the target's input schema. This is the
    // last-line DEFENCE, not the enforcement point — every dynamic entry pre-validates its own argument and
    // renders its own error upstream: a `call_agent` args record as a catchable `reflection.call_error`
    // (engine-side), and an mcp / webhook delivery and a run command's JSON argument as a per-request 400
    // (actor-side). So a mismatch reaching HERE is a type-system hole or a genuine defect (an FFI handler
    // passing a malformed argument) — never an anticipated error, so it is a PANIC. Panic (unlike a
    // `call_error`) is orthogonal to the callee's effect row, so injecting it cannot make the row lie by
    // introducing a throw the row does not declare; a `call_error` here would. A statically checked call site
    // conforms by construction, so this never fires for one. The argument is passed through unchanged: the
    // codec already decoded it, and this is a pure check, never a rewrite.
    const targetBlock = this.ir
      .access(resolved.snapshot, moduleOf(target))
      .block(resolved.agentBlockId).block;
    if (targetBlock.kind === "agent") {
      const substitution = typeSubstitutionOf(targetBlock.schema.genericBindings, generics);
      const inputSchema = fillGenericSchema(substitution, targetBlock.schema.input);
      // A missing argument is checked as an empty record — an agent with no required input accepts it, a
      // data / required-field input rightly fails.
      const check = conformValue(argument ?? { kind: "record", fields: {} }, inputSchema);
      if (!check.ok) {
        this.raisePanic(
          event.delegation,
          `${describeTarget(target)}: the argument does not conform to the input schema — ${renderConformFailures(check.failures)}`,
          event.from,
          event.run,
          this.preInstanceRaiser(event),
        );
        return;
      }
    }
    const instance = createInstance(this.store, {
      delegationId: event.delegation,
      // The summoner's reactor: a reply this instance emits routes back here (core for a sub-call, api for a
      // run root) — recorded now from the delegate's `from`, never re-inferred.
      callerReactor: event.from,
      // The run this activation belongs to (the delegate's trace context) — every event it emits carries it.
      runId: event.run,
      target: target,
      argument: argument,
      agentBlockId: resolved.agentBlockId,
      capturedScopeId: resolved.capturedScopeId,
      snapshotId: resolved.snapshot,
      ...(generics !== undefined ? { ambientGenerics: generics } : {}),
    });
    // Record the handled delegation (the callee-side index → this child instance + its summoner), so an inbound
    // terminate / escalateAck for it finds the child and its replies route back. The caller-side delegation row
    // was already opened by its caller (core's issuing turn, or the api root's startRun); this turn only summons
    // the child and runs it. `event.caller` is the issuing instance (the hoist target for this child's upward
    // events) — stamped by the base `send`.
    this.acceptDelegation(event.delegation, instance.id, event.from, event.run, event.caller);
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
    // An external (FFI / http) result crosses an untyped boundary, so the assumed-typing contract is only a
    // promise — the sidecar's JS could return a value that violates the agent's declared output schema (a
    // missing field, a wrong type, a bare/unqualified data constructor). Conform it here, the one seam that
    // has the IR, the wrapper instance's schema, and its generics (mirroring the input conform at
    // `onDelegate`). A violation is a broken contract, not a program-anticipatable error, so it fails the
    // call as a panic raised at the proxy — exactly as an external *error* does — naming the boundary,
    // rather than corrupting a match / field read far downstream. Only the WRAPPER role conforms: there
    // the instance's whole body is the external leaf, so the ack value IS the instance's own result. A
    // `dispatched` proxy (a mid-body dynamically dispatched tool) delivers an ordinary intermediate —
    // conforming that against the CALLER's output schema would wrongly reject a typed caller mid-body;
    // its value meets the ordinary schema boundaries instead (the tool's runtime schema at dispatch, this
    // instance's own output conform when it returns). A core sub-call is statically typed by construction
    // and skips this entirely.
    if (proxy.kind === "external" && proxy.role === "wrapper") {
      const failure = await this.conformExternalResult(caller, event.value);
      if (failure !== null) {
        await this.runTurnWith(caller, (ctx) =>
          relayEscalate(ctx, proxy.id, newEscalationId(), {
            kind: "request",
            request: PANIC_REQUEST,
            argument: panicArgument(failure),
          }),
        );
        return;
      }
    }
    delete caller.threads[proxy.id];
    await this.runTurn(caller, [
      { kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value },
    ]);
  }

  /** Conform an external call's returned value against the calling wrapper instance's declared output schema
   *  (an `external agent` lowers to a wrapper `AgentBlock` whose body is the external leaf; the instance that
   *  issued the external delegation is that wrapper, so its `schema.output` is the external's declared output,
   *  and its `ambientGenerics` fill the type params). Returns a failure message, or `null` when it conforms.
   *  The wrapper is a live running instance, so its snapshot IR is already loaded — but preload defensively
   *  (rethrowing a transient read so the substrate can replay the ack from the durable outbox). */
  private async conformExternalResult(
    instance: CoreInstance,
    value: Value,
  ): Promise<string | null> {
    await this.ir.preload(agentSnapshot(instance.target));
    const resolved = this.resolveTarget(instance.target);
    const block = this.ir
      .access(resolved.snapshot, moduleOf(instance.target))
      .block(resolved.agentBlockId).block;
    if (block.kind !== "agent") return null;
    const substitution = typeSubstitutionOf(block.schema.genericBindings, instance.ambientGenerics);
    const check = conformValue(value, fillGenericSchema(substitution, block.schema.output));
    if (check.ok) return null;
    return `${describeTarget(instance.target)}: the external result does not conform to the output schema — ${renderConformFailures(check.failures)}`;
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
    event: Extract<ExternalEvent, { kind: "terminate" }>,
    context: { callee: InstanceId | undefined },
  ): Promise<void> {
    const child = this.coreInstance(context.callee);
    if (child === undefined) {
      // No instance handles this delegation — its delegate failed at the acceptance surface (an
      // unresolvable name, a schema violation: the panic path births no instance), or it is already
      // gone. Confirm the terminate anyway so the caller's cancel cascade completes; a caller whose
      // proxy has meanwhile resolved ignores a stray ack.
      this.send({
        kind: "terminateAck",
        delegation: event.delegation,
        from: this.name,
        to: event.from,
        run: event.run,
      });
      return;
    }
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
      irSource: this.ir,
      prims: this.prims,
      blobs: this.blobs,
      // Stamped as `from` on every event the engine emits; each emit site supplies its own `to` from edge
      // knowledge (the callee's reactor, or the summoner), so the harvest below only buffers routed events.
      reactorName: this.name,
      // The blob write seams the effectful file prims (`from_base64` / `free`) reach through: a produced blob
      // is owned by the running instance (so its next upward event hoists it up, like an FFI-produced blob),
      // and a free reclaims a blob only when this instance's run owns it. Closing over `this.pool` + the
      // instance keeps the pool an actor-layer concept the engine never imports.
      produceBlob: (blobId, entry) =>
        this.pool.registerBlob(blobId, { owner: instance.id, ...entry }),
      freeBlobInRun: (blobId) => this.pool.deleteBlobOwnedInRun(blobId, instance.runId),
    });
    seed(ctx);
    await drive(ctx);
    // Emit each engine outbound (already routed by the emit edge); the base `send` derives the Layer 1 edge it
    // implies — opening this instance's delegation, cancelling it, or opening a user-facing escalation — from
    // the issuing instance (this turn's `instance`), passed explicitly.
    for (const event of ctx.buffers.outbound) this.send(event, instance.id);
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

  /** The raiser a pre-instance failure (an unresolvable / non-conforming delegate, before the callee is
   *  born) is attributed to: the delegate's ISSUER, which core owns the caller-side row for (a mortal core
   *  instance — its teardown cascades the failure row). A pre-instance failure can ONLY happen for a
   *  sub-call (`from = core`): a RUN delegate is validated at the run-start boundary (an unresolvable /
   *  malformed entry is a 400, never launched), and an INNER delegate (ffi / mcp / webhook) has its target +
   *  argument validated at that reactor's own boundary — so neither ever reaches this pre-instance panic.
   *  Attributing to the permanent run instance (the old `?? event.run`) would make it the raiser of an
   *  ephemeral row that no cascade reclaims, which the design forbids (the run instance is the run's
   *  permanent result container). So a missing caller here is an engine invariant break — fail loudly rather
   *  than resurrect the permanent-raiser leak. */
  private preInstanceRaiser(event: Extract<ExternalEvent, { kind: "delegate" }>): InstanceId {
    const caller = this.callerInstanceOf(event.delegation);
    if (caller === undefined) {
      throw new Error(
        `core pre-instance failure for ${event.delegation} has no issuer core owns (a run / inner delegate reached the acceptance surface unvalidated — engine bug)`,
      );
    }
    return caller;
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

/** A target's user-facing label for a panic message (a closure has no qualified name). */
function describeTarget(target: DelegateTarget): string {
  switch (target.kind) {
    case "named":
      return String(target.name);
    case "closure":
      return `closure (block ${target.blockId} of module "${target.module}")`;
    case "external":
      return `external "${target.key}"`;
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
