// Instance lifecycle: an instance is one agent activation (a thread tree) and the unit of ownership and
// of load/persist. It is summoned by a delegate and self-deletes at its terminal. This layer creates an
// instance (root scope + root AgentThread) and tears it down (cascade its owned scopes). A returned
// value that carries escaping scopes (a closure / blob) would ascend to the parent instead of cascading;
// that ascent is a refinement on top of this cascade.

import type { BlockId } from "@katari-lang/types";
import type { DelegateTarget } from "../event/types.js";
import {
  type BlobId,
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
import type { ApiInstance, CoreInstance, ProjectStore } from "./types.js";

/**
 * Create a fresh `core` instance: its root scope (chained to a captured closure scope, if any) and its
 * root `AgentThread`. The caller then drives a `create` event for `rootThreadId` to start it. The argument
 * is stored for the AgentThread to default + seed; generics ride as the activation's ambient substitution.
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
): CoreInstance {
  const id = newInstanceId();
  const instance: CoreInstance = {
    kind: "core",
    id,
    delegationId: args.delegationId,
    target: args.target,
    argument: args.argument,
    status: "running",
    rootThreadId: toThreadId(0),
    threads: {},
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
    forwardRoutes: {},
    kind: "agent",
    pending: null,
    escalations: {},
  };
  return instance;
}

/** Whether a `core` instance has finished (its thread tree is empty — the agent root completed). */
export function isInstanceComplete(instance: CoreInstance): boolean {
  return Object.keys(instance.threads).length === 0;
}

/**
 * Get (or create) the project's permanent `api` management root. It runs no IR — it only holds the runs
 * it issues and the escalations that bubble to it (tracked by the actor / audit). Its id is deterministic
 * per project so a restart recovers the same root.
 */
export function ensureApiRoot(store: ProjectStore, apiRootId: InstanceId): ApiInstance {
  const existing = store.instances[apiRootId];
  if (existing !== undefined && existing.kind === "api") return existing;
  const root: ApiInstance = { kind: "api", id: apiRootId, status: "running" };
  store.instances[apiRootId] = root;
  return root;
}

/** Tear down a finished instance: cascade-drop the scopes (and blob ownerships) it still owns, then drop
 *  the instance. Resources its returned value captured were already lifted to in-transit (`owner = null`)
 *  by `ascendResources`, so they are not owned by this instance here and survive for the caller to re-own.
 *  (Dropping a blob's actual bytes — a `BlobStore.delete` — is a follow-up; `blobOwners` is empty until a
 *  blob producer exists.) */
export function teardownInstance(store: ProjectStore, instanceId: InstanceId): void {
  for (const key of Object.keys(store.scopes)) {
    const scopeId = Number(key);
    if (store.scopes[scopeId]?.owner === instanceId) {
      delete store.scopes[scopeId];
    }
  }
  for (const key of Object.keys(store.blobOwners)) {
    const blobId = key as BlobId;
    if (store.blobOwners[blobId] === instanceId) {
      delete store.blobOwners[blobId];
    }
  }
  delete store.instances[instanceId];
}
