// Instance lifecycle: an instance is one agent activation (a thread tree) and the unit of ownership and
// of load/persist. It is summoned by a delegate and self-deletes at its terminal. This layer creates an
// instance (root scope + root AgentThread) and tears it down (cascade its owned scopes). A returned
// value that carries escaping scopes (a closure / blob) would ascend to the parent instead of cascading;
// that ascent is a refinement on top of this cascade.

import type { BlockId } from "@katari-lang/types";
import type { DelegateTarget, ReactorName } from "../event/types.js";
import {
  type DelegationId,
  type InstanceId,
  newInstanceId,
  type ScopeId,
  type SnapshotId,
  toThreadId,
} from "../ids.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { allocateScope, deleteScope, scopesOwnedBy } from "./scope.js";
import { allocateThreadId } from "./store.js";
import type { CoreInstance, ProjectStore } from "./types.js";

/**
 * Create a fresh `core` instance: its root scope (chained to a captured closure scope, if any) and its
 * root `AgentThread`. The caller then drives a `create` event for `rootThreadId` to start it. The argument
 * is stored for the AgentThread to default + seed; generics ride as the activation's ambient substitution.
 */
export function createInstance(
  store: ProjectStore,
  args: {
    delegationId: DelegationId | null;
    callerReactor: ReactorName;
    runId: InstanceId;
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
    callerReactor: args.callerReactor,
    runId: args.runId,
    target: args.target,
    argument: args.argument,
    status: "running",
    rootThreadId: toThreadId(0),
    threads: {},
    cancelExits: {},
    finalizers: [],
    phase: { kind: "running" },
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
    // The instance root is user code (the finalizer drain runs as its children, stamped `finalizer`).
    origin: "user",
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

/** Tear down a finished instance: cascade-drop the scopes it still owns, then drop the instance. Resources
 *  its returned value captured were already released to in-transit (`owner = null`) by the base reactor's
 *  `send` (`pool.release`), so they are not owned by this instance here and survive for the caller to re-own.
 *  Blobs are NOT touched here: blob ownership is a pure resource the `ResourcePool` manages (not engine-local
 *  like scopes), so the base reactor's instance-drop path (`markInstanceDropped` → `pool.reclaimBlobsOwnedBy`)
 *  reclaims a dropping instance's owned blobs uniformly for a core instance and an ffi call alike. */
export function teardownInstance(store: ProjectStore, instanceId: InstanceId): void {
  for (const scopeId of scopesOwnedBy(store, instanceId)) deleteScope(store, scopeId);
  delete store.instances[instanceId];
}
