// Instance lifecycle: an instance is one agent activation (a thread tree) and the unit of ownership and
// of load/persist. It is summoned by a delegate and self-deletes at its terminal. This layer creates an
// instance (root scope + root AgentThread) and tears it down (cascade its owned scopes). A returned
// value that carries escaping scopes (a closure / blob) would ascend to the parent instead of cascading;
// that ascent is a refinement on top of this cascade.

import type { BlockId } from "@katari-lang/types";
import type { DelegateTarget } from "../event/types.js";
import {
  type DelegationId,
  type InstanceId,
  newInstanceId,
  type ScopeId,
  type SnapshotId,
  toThreadId,
} from "../ids.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { allocateScope } from "./scope.js";
import { allocateThreadId } from "./store.js";
import type { Instance, ProjectStore } from "./types.js";

/**
 * Create a fresh instance: its root scope (chained to a captured closure scope, if any) and its root
 * `AgentThread`. The caller then drives a `create` event for `rootThreadId` to start it. The argument is
 * stored for the AgentThread to default + seed; generics ride as the activation's ambient substitution.
 */
export function createInstance(
  store: ProjectStore,
  args: {
    delegationId: DelegationId | null;
    target: DelegateTarget;
    argument: Value | null;
    agentBlockId: BlockId;
    capturedScopeId: ScopeId | null;
    snapshotId: SnapshotId;
    ambientGenerics?: GenericSubstitution;
  },
): Instance {
  const id = newInstanceId();
  const instance: Instance = {
    id,
    delegationId: args.delegationId,
    target: args.target,
    argument: args.argument,
    status: "running",
    rootThreadId: toThreadId(0),
    threads: {},
    pendingDelegations: {},
    askRoutes: {},
    escalationContinuations: {},
    cancelExits: {},
    nextThreadId: 0,
    nextCallId: 0,
    nextAskId: 0,
    ...(args.ambientGenerics !== undefined ? { ambientGenerics: args.ambientGenerics } : {}),
  };
  store.instances[id] = instance;

  const scopeId = allocateScope(store, args.capturedScopeId, id);
  const rootThreadId = allocateThreadId(instance);
  instance.rootThreadId = rootThreadId;
  instance.threads[rootThreadId] = {
    id: rootThreadId,
    parent: null,
    parentCallId: null,
    scopeId,
    blockId: args.agentBlockId,
    status: "running",
    kind: "agent",
    pending: null,
  };
  return instance;
}

/** Whether an instance has finished (its thread tree is empty — the agent root completed). */
export function isInstanceComplete(instance: Instance): boolean {
  return Object.keys(instance.threads).length === 0;
}

/** Tear down a finished instance: cascade-drop the scopes it owns, then drop the instance. (Escaping
 *  values that should ascend to the parent are a refinement; a scalar / self-contained result needs none.) */
export function teardownInstance(store: ProjectStore, instanceId: InstanceId): void {
  for (const key of Object.keys(store.scopes)) {
    const scopeId = Number(key);
    if (store.scopes[scopeId]?.owner === instanceId) {
      delete store.scopes[scopeId];
    }
  }
  delete store.instances[instanceId];
}
