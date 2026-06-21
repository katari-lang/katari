// ProjectActor: the warm, per-project external consumer. It owns the project's `ProjectStore` (the
// loaded instances + shared scopes) and a serial mailbox of external events. The loop pulls one message
// at a time, routes it to the owning instance, drives that instance's internal turn to quiescence,
// persists at the turn boundary, then flushes the turn's outbound external events back onto the mailbox.
// Everything is serial; concurrency is the ack model (a parent that fanned out several delegates resumes
// each branch as its delegateAck lands). FFI completions and the inter-instance escalate / terminate
// halves arrive through the same mailbox and are handled in their respective (later) layers.

import type { QualifiedName } from "@katari-lang/types";
import { makeStepContext, type PrimRunner } from "../engine/context.js";
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

  /** A pending delegate's caller instance, for routing its delegateAck home (the `delegations` row's
   *  caller). Absent for a run-root delegate, whose ack resolves the run instead (see `runResolvers`). */
  private readonly delegationCaller: Record<DelegationId, InstanceId> = {};
  /** Resolvers for run-root delegations: the run's delegateAck settles the caller's `startRun` promise. */
  private readonly runResolvers: Record<DelegationId, (value: Value) => void> = {};

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
    const result = new Promise<Value>((resolve) => {
      this.runResolvers[delegation] = resolve;
    });
    this.feed({
      kind: "delegate",
      delegation,
      target: { kind: "named", name: qualifiedName, snapshot },
      argument,
    });
    return result;
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
      case "escalateAck":
      case "terminate":
      case "terminateAck":
        throw new Error(`external event "${message.kind}" is wired in the effect-system layer`);
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
    await this.runTurn(instance, [{ kind: "create", thread: instance.rootThreadId }]);
  }

  private async onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
  ): Promise<void> {
    const callerId = this.delegationCaller[event.delegation];
    if (callerId === undefined) {
      // A run-root delegateAck: settle the run promise.
      const resolver = this.runResolvers[event.delegation];
      if (resolver !== undefined) {
        delete this.runResolvers[event.delegation];
        resolver(event.value);
      }
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

  // ─── FFI completion ──────────────────────────────────────────────────────────────────────────

  /** Resume the suspended `ExternalThread` an FFI call belongs to by acking its parent (the external
   *  agent's AgentThread) with the result, which completes the call's instance and emits its delegateAck. */
  private async onFfiResult(result: FfiResult): Promise<void> {
    const instance = this.store.instances[result.instance];
    if (instance === undefined) return; // its instance was torn down (cancelled) — drop the late result
    const thread = instance.threads[result.thread];
    if (thread === undefined || thread.kind !== "external") return;
    if (thread.parent === null || thread.parentCallId === null) return;
    delete instance.threads[thread.id];
    // Error propagation (an FFI failure reaching the run as an error / escalation) is future work; for
    // now a failed call resolves to null so the actor stays live rather than dropping the run.
    const value: Value = result.kind === "ffiResult" ? result.value : { kind: "null" };
    await this.runTurn(instance, [
      { kind: "callAck", target: thread.parent, callId: thread.parentCallId, value },
    ]);
  }

  // ─── one instance turn ────────────────────────────────────────────────────────────────────────

  private async runTurn(instance: Instance, initial: InternalEvent[]): Promise<void> {
    const ctx = makeStepContext({
      projectId: this.projectId,
      store: this.store,
      instance,
      ir: this.registry.access(instance.target.snapshot),
      prims: this.prims,
      blobs: this.blobs,
      external: this.external,
    });
    ctx.buffers.internalQueue.push(...initial);
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

  /** Send a turn's outbound external event onward: a delegate records its caller for ack routing, then
   *  every event re-enters the serial mailbox (looping back to its target instance, or the run resolver). */
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
