// ProjectActor: the warm, per-project external consumer. It owns the project's `ProjectStore` (the
// loaded instances + shared scopes) and a serial mailbox of external events. The loop pulls one message
// at a time, routes it to the owning instance, drives that instance's internal turn to quiescence,
// persists at the turn boundary, then flushes the turn's outbound external events back onto the mailbox.
// Everything is serial; concurrency is the ack model (a parent that fanned out several delegates resumes
// each branch as its delegateAck lands). FFI completions and the inter-instance escalate / terminate
// halves arrive through the same mailbox and are handled in their respective (later) layers.

import type { QualifiedName } from "@katari-lang/types";
import { PANIC_REQUEST, raisePanic, relayEscalate } from "../engine/common.js";
import { makeStepContext, type PrimRunner, type StepContext } from "../engine/context.js";
import { drive } from "../engine/drive.js";
import { createInstance, isInstanceComplete, teardownInstance } from "../engine/instance.js";
import { createProjectStore } from "../engine/store.js";
import type { Instance, ProjectStore } from "../engine/types.js";
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
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  type ProjectId,
  type ScopeId,
  type SnapshotId,
} from "../ids.js";
import type { SnapshotRegistry } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import type { Persistence } from "./persistence.js";

export interface ProjectActorDependencies {
  projectId: ProjectId;
  registry: SnapshotRegistry;
  prims: PrimRunner;
  blobs: BlobStore;
  external: ExternalRunner;
  persistence: Persistence;
}

export class ProjectActor {
  private readonly projectId: ProjectId;
  private readonly registry: SnapshotRegistry;
  private readonly prims: PrimRunner;
  private readonly blobs: BlobStore;
  private readonly external: ExternalRunner;
  private readonly persistence: Persistence;

  private readonly store: ProjectStore = createProjectStore();
  private readonly mailbox: ActorMessage[] = [];
  private pumping = false;

  /** A pending delegate's caller instance, for routing its delegateAck / escalate home (the `delegations`
   *  row's caller). Absent for a run-root delegate, whose ack resolves the run instead (`runResolvers`). */
  private readonly delegationCaller: Record<DelegationId, InstanceId> = {};
  /** A delegation's spawned child instance, for routing a `terminate` to it. */
  private readonly delegationChild: Record<DelegationId, InstanceId> = {};
  /** An outbound escalation's raiser instance, for routing its `escalateAck` back to it. */
  private readonly escalationRaiser: Record<EscalationId, InstanceId> = {};
  /** Settle / reject a run-root delegation: its delegateAck resolves the `startRun` promise; an
   *  unhandled escalation (e.g. a panic) at the run root rejects it. */
  private readonly runResolvers: Record<DelegationId, (value: Value) => void> = {};
  private readonly runRejecters: Record<DelegationId, (error: Error) => void> = {};

  constructor(dependencies: ProjectActorDependencies) {
    this.projectId = dependencies.projectId;
    this.registry = dependencies.registry;
    this.prims = dependencies.prims;
    this.blobs = dependencies.blobs;
    this.external = dependencies.external;
    this.persistence = dependencies.persistence;
    // FFI completions re-enter through the same serial mailbox as every other external message.
    this.external.onResult((result) => this.feed(result));
  }

  /** Start a run: summon a root instance for `qualifiedName@snapshot` and resolve with its result. */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): Promise<Value> {
    const delegation = newDelegationId();
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
    return result;
  }

  /** Settle a run-root delegation either way and drop both handlers. */
  private settleRun(delegation: DelegationId, outcome: { value: Value } | { error: Error }): void {
    const resolver = this.runResolvers[delegation];
    const rejecter = this.runRejecters[delegation];
    delete this.runResolvers[delegation];
    delete this.runRejecters[delegation];
    if ("value" in outcome) resolver?.(outcome.value);
    else rejecter?.(outcome.error);
  }

  /** Enqueue an external message and ensure the serial loop is running. */
  feed(message: ActorMessage): void {
    this.mailbox.push(message);
    void this.pump();
  }

  // ─── serial loop ──────────────────────────────────────────────────────────────────────────────

  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    try {
      while (this.mailbox.length > 0) {
        const message = this.mailbox.shift();
        if (message === undefined) break;
        await this.handle(message);
      }
    } finally {
      this.pumping = false;
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
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }]);
  }

  private async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): Promise<void> {
    delete this.delegationChild[event.delegation];
    const callerId = this.delegationCaller[event.delegation];
    if (callerId === undefined) {
      this.settleRun(event.delegation, { value: event.value }); // a run-root delegateAck
      return;
    }
    delete this.delegationCaller[event.delegation];
    const instance = this.store.instances[callerId];
    if (instance === undefined) return;
    const proxyId = instance.pendingDelegations[event.delegation];
    delete instance.pendingDelegations[event.delegation];
    const proxy = proxyId !== undefined ? instance.threads[proxyId] : undefined;
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    delete instance.threads[proxy.id];
    await this.runTurn(instance, [
      { kind: "callAck", target: proxy.parent, callId: proxy.parentCallId, value: event.value },
    ]);
  }

  // ─── escalate / escalateAck (a request / control ask crossing the instance boundary) ────────────

  private async onEscalate(event: Extract<ExternalEvent, { kind: "escalate" }>): Promise<void> {
    const callerId = this.delegationCaller[event.delegation];
    if (callerId === undefined) {
      // The escalation reached the run root with no handler. A panic fails the run; any other unhandled
      // request is, for now, also surfaced as a run error (user-facing escalation answering is Phase C).
      this.settleRun(event.delegation, {
        error: new Error(escalationErrorMessage(event)),
      });
      return;
    }
    const instance = this.store.instances[callerId];
    if (instance === undefined) return;
    const proxyId = instance.pendingDelegations[event.delegation];
    if (proxyId === undefined) return;
    // Re-raise the ask inside the caller from the proxy's position; it bubbles toward a handle.
    await this.runTurnWith(instance, (ctx) => {
      relayEscalate(ctx, proxyId, event.escalation, event.ask);
    });
  }

  private async onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
  ): Promise<void> {
    const raiserId = this.escalationRaiser[event.escalation];
    delete this.escalationRaiser[event.escalation];
    if (raiserId === undefined) return;
    const instance = this.store.instances[raiserId];
    if (instance === undefined) return;
    const continuation = instance.escalationContinuations[event.escalation];
    delete instance.escalationContinuations[event.escalation];
    if (continuation === undefined || continuation.kind !== "resumeThread") return;
    await this.runTurn(instance, [
      {
        kind: "askAck",
        target: continuation.thread,
        askId: continuation.askId,
        value: event.value,
      },
    ]);
  }

  // ─── terminate / terminateAck (graceful cross-instance cancel) ──────────────────────────────────

  private async onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): Promise<void> {
    const childId = this.delegationChild[event.delegation];
    if (childId === undefined) return;
    const instance = this.store.instances[childId];
    if (instance === undefined) return;
    instance.status = "cancelling";
    // Cancel the root; once its subtree is torn down it emits terminateAck and retires the instance.
    await this.runTurn(instance, [{ kind: "cancel", target: instance.rootThreadId }]);
  }

  private async onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
  ): Promise<void> {
    delete this.delegationChild[event.delegation];
    const callerId = this.delegationCaller[event.delegation];
    delete this.delegationCaller[event.delegation];
    if (callerId === undefined) return; // a run-root terminate (cancelled run) — nothing to resume
    const instance = this.store.instances[callerId];
    if (instance === undefined) return;
    const proxyId = instance.pendingDelegations[event.delegation];
    delete instance.pendingDelegations[event.delegation];
    const proxy = proxyId !== undefined ? instance.threads[proxyId] : undefined;
    if (proxy === undefined || proxy.parent === null || proxy.parentCallId === null) return;
    // The child confirmed teardown: retire the proxy and cancelAck its parent (the cancel cascade continues).
    delete instance.threads[proxy.id];
    delete instance.cancelExits[proxy.id];
    await this.runTurn(instance, [
      { kind: "cancelAck", target: proxy.parent, callId: proxy.parentCallId },
    ]);
  }

  // ─── FFI completion ──────────────────────────────────────────────────────────────────────────

  /** Resume the suspended `ExternalThread` an FFI call belongs to by acking its parent (the external
   *  agent's AgentThread) with the result, which completes the call's instance and emits its delegateAck. */
  private async onFfiResult(result: FfiResult): Promise<void> {
    const instance = this.store.instances[result.instance];
    if (instance === undefined) return; // its instance was torn down (cancelled) — drop the late result
    const thread = instance.threads[result.thread];
    if (thread === undefined || thread.kind !== "external") return;
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

  private runTurn(instance: Instance, initial: InternalEvent[]): Promise<void> {
    return this.runTurnWith(instance, (ctx) => {
      ctx.buffers.internalQueue.push(...initial);
    });
  }

  /** Drive one instance's turn after `seed` queues its initial internal events (directly, or via a
   *  helper that needs the StepContext such as `relayEscalate`); then persist and flush. */
  private async runTurnWith(instance: Instance, seed: (ctx: StepContext) => void): Promise<void> {
    const ctx = makeStepContext({
      projectId: this.projectId,
      store: this.store,
      instance,
      ir: this.registry.access(instance.target.snapshot),
      prims: this.prims,
      blobs: this.blobs,
      external: this.external,
    });
    seed(ctx);
    await drive(ctx);
    // DB reflection happens once the internal queue is empty (the turn boundary).
    await this.persistence.persistTurn(this.projectId, this.store);
    if (isInstanceComplete(instance)) {
      teardownInstance(this.store, instance.id);
    }
    for (const event of ctx.buffers.outbound) {
      this.routeOutbound(instance.id, event);
    }
  }

  /** Send a turn's outbound external event onward: a delegate records its caller for ack routing and an
   *  escalate its raiser for escalateAck routing; then every event re-enters the serial mailbox. */
  private routeOutbound(fromInstanceId: InstanceId, event: ExternalEvent): void {
    if (event.kind === "delegate") {
      this.delegationCaller[event.delegation] = fromInstanceId;
    } else if (event.kind === "escalate") {
      this.escalationRaiser[event.escalation] = fromInstanceId;
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
        agentBlockId: this.registry.access(target.snapshot).resolveName(target.name).blockId,
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
