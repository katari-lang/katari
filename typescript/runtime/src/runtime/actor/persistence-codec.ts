// Pure serialisation between the engine's in-memory graph and its persisted row shapes. The value model
// is already JSON (a tagged union of JSON leaves), so this is near-identity: a thread is stored whole in
// `payload` with its routing/identity columns denormalised for queries; an instance's bookkeeping is its
// `engine_state` JSON; scopes are row-per-scope. Deserialisation rebuilds the `ProjectSnapshot` (and the
// actor derives its routing maps from the instances). Kept separate from the DB so the round-trip is
// unit-testable without Postgres.

import type {
  CoreInstance,
  EngineState,
  Instance,
  InstanceKind,
  InstanceStatus,
  ProjectStore,
  Scope,
  Thread,
} from "../engine/types.js";
import type { DelegateTarget } from "../event/types.js";
import {
  type DelegationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
  toScopeId,
} from "../ids.js";
import type { GenericSubstitution } from "../value/types.js";

/** The engine half of a `ProjectSnapshot` the codec reconstructs from rows. The Layer 1 delegation edges
 *  are added by the persistence implementation (from its own `delegations` storage), not derivable here. */
export interface DeserializedEngine {
  instances: ProjectStore["instances"];
  scopes: ProjectStore["scopes"];
  nextScopeId: number;
}

export interface PersistedInstance {
  id: InstanceId;
  projectId: ProjectId;
  kind: InstanceKind;
  delegationId: DelegationId | null;
  /** `null` for the `api` root (which runs no IR). */
  target: DelegateTarget | null;
  snapshotId: SnapshotId | null;
  status: InstanceStatus;
  ambientGenerics: GenericSubstitution | null;
  /** `null` for the `api` root. */
  engineState: EngineState | null;
}

export interface PersistedThread {
  projectId: ProjectId;
  instanceId: InstanceId;
  threadId: number;
  kind: Thread["kind"];
  parentThreadId: number | null;
  parentCallId: number | null;
  scopeId: number;
  blockId: number;
  status: Thread["status"];
  /** The whole thread (a JSON leaf graph); its columns above are denormalised for recovery queries. */
  payload: Thread;
}

export interface PersistedScope {
  projectId: ProjectId;
  scopeId: number;
  parentScopeId: number | null;
  ownerInstanceId: InstanceId | null;
  values: Scope["values"];
}

export interface SerializedInstance {
  instance: PersistedInstance;
  threads: PersistedThread[];
  scopes: PersistedScope[];
}

/** Serialise a still-running `core` instance + the scopes it owns into their row shapes. (Only core
 *  instances carry engine state; the `api` root's runs / escalations persist as the audit, not here.) */
export function serializeInstance(
  projectId: ProjectId,
  instance: CoreInstance,
  ownedScopes: Scope[],
): SerializedInstance {
  return {
    instance: {
      id: instance.id,
      projectId,
      kind: "core",
      delegationId: instance.delegationId,
      target: instance.target,
      snapshotId: instance.target.snapshot,
      status: instance.status,
      ambientGenerics: instance.ambientGenerics ?? null,
      engineState: engineStateOf(instance),
    },
    threads: Object.values(instance.threads).map((thread) => ({
      projectId,
      instanceId: instance.id,
      threadId: thread.id,
      kind: thread.kind,
      parentThreadId: thread.parent,
      parentCallId: thread.parentCallId,
      scopeId: thread.scopeId,
      blockId: thread.blockId,
      status: thread.status,
      payload: thread,
    })),
    scopes: ownedScopes.map((scope) => ({
      projectId,
      scopeId: scope.id,
      parentScopeId: scope.parentId,
      ownerInstanceId: scope.owner,
      values: scope.values,
    })),
  };
}

/** The instance bookkeeping that has no dedicated column (its threads live in the threads table). */
export function engineStateOf(instance: CoreInstance): EngineState {
  return {
    rootThreadId: instance.rootThreadId,
    cancelExits: instance.cancelExits,
    nextThreadId: instance.nextThreadId,
    nextCallId: instance.nextCallId,
    nextAskId: instance.nextAskId,
  };
}

/** Reconstruct a project's warm engine state from its persisted rows. The instance `argument` is not
 *  restored — by the turn boundary the root agent has already consumed it (it lives in the body scope). */
export function deserializeProject(
  instances: PersistedInstance[],
  threads: PersistedThread[],
  scopes: PersistedScope[],
): DeserializedEngine {
  const threadsByInstance = new Map<InstanceId, Record<number, Thread>>();
  for (const row of threads) {
    const tree = threadsByInstance.get(row.instanceId) ?? {};
    tree[row.threadId] = row.payload;
    threadsByInstance.set(row.instanceId, tree);
  }

  const instanceMap: Record<InstanceId, Instance> = {};
  for (const row of instances) {
    if (row.kind === "api") {
      // The management root: no engine state / thread tree — just identity + status.
      instanceMap[row.id] = { kind: "api", id: row.id, status: row.status };
      continue;
    }
    if (row.engineState === null || row.target === null) continue; // a malformed core row
    instanceMap[row.id] = {
      kind: "core",
      id: row.id,
      delegationId: row.delegationId,
      target: row.target,
      argument: null,
      status: row.status,
      ...(row.ambientGenerics !== null ? { ambientGenerics: row.ambientGenerics } : {}),
      rootThreadId: row.engineState.rootThreadId,
      threads: threadsByInstance.get(row.id) ?? {},
      cancelExits: row.engineState.cancelExits,
      nextThreadId: row.engineState.nextThreadId,
      nextCallId: row.engineState.nextCallId,
      nextAskId: row.engineState.nextAskId,
    };
  }

  const scopeMap: Record<number, Scope> = {};
  let maxScopeId = -1;
  for (const row of scopes) {
    scopeMap[row.scopeId] = {
      id: toScopeId(row.scopeId),
      parentId: row.parentScopeId === null ? null : toScopeId(row.parentScopeId),
      owner: row.ownerInstanceId,
      values: row.values,
    };
    maxScopeId = Math.max(maxScopeId, row.scopeId);
  }

  return { instances: instanceMap, scopes: scopeMap, nextScopeId: maxScopeId + 1 };
}
