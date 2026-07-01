// Pure serialisation between the engine's in-memory graph and its persisted row shapes. The value model
// is already JSON (a tagged union of JSON leaves), so this is near-identity: a thread is stored whole in
// `payload` with its routing/identity columns denormalised for queries; an instance's bookkeeping is its
// `engine_state` JSON; scopes and blob ownership are row-per-resource. Deserialisation rebuilds the engine
// half (`DeserializedEngine` — instances + scopes + blobs); each reactor then loads the Layer 1 rows it owns
// and derives
// its routing maps from the instances' threads. Kept separate from the DB so the round-trip is unit-testable
// without Postgres.

import type {
  BlobEntry,
  CoreInstance,
  EngineState,
  InstanceKind,
  InstanceStatus,
  ProjectStore,
  Scope,
  Thread,
} from "../engine/types.js";
import { agentSnapshot, type DelegateTarget, type ReactorName } from "../event/types.js";
import {
  type BlobId,
  type DelegationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
  toScopeId,
} from "../ids.js";
import type { GenericSubstitution, SemanticKind } from "../value/types.js";

/** The engine half a reactor's `load` reconstructs from rows (instances + scopes + blob ownership). The
 *  Layer 1 delegation edges are loaded by each reactor from its own rows, not derivable here. */
export interface DeserializedEngine {
  instances: ProjectStore["instances"];
  scopes: ProjectStore["scopes"];
  blobs: ProjectStore["blobs"];
  nextScopeId: number;
}

/** The generic instance *envelope* row (the columns every kind shares), written by the base reactor with
 *  `kind = its own reactor name`. `projectId` is injected by the project-scoped transaction. */
export interface PersistedInstanceEnvelope {
  id: InstanceId;
  kind: InstanceKind;
  delegationId: DelegationId | null;
  /** The reactor that summoned this instance (its reply-to), the instance's ambient — `null` only for the
   *  `api` management root, which nothing delegates to. Base-owned, uniform across reactor kinds. */
  callerReactor: ReactorName | null;
  status: InstanceStatus;
}

/** The `core` instance extension row (`core_instances`) — what a CORE activation runs plus its engine
 *  bookkeeping. Written by the CoreReactor; its threads ride alongside in the `threads` table. */
export interface PersistedCoreInstance {
  instanceId: InstanceId;
  target: DelegateTarget;
  snapshotId: SnapshotId;
  ambientGenerics: GenericSubstitution | null;
  engineState: EngineState;
}

/** The joined core row a reactivation reads (envelope ⋈ `core_instances`) — the shape `deserializeProject`
 *  rebuilds a `CoreInstance` from. The engine load returns only `core` instances, so every field is present.
 *  (No `projectId`: the load is already project-scoped and a `CoreInstance` carries none.) */
export interface PersistedInstance {
  id: InstanceId;
  delegationId: DelegationId | null;
  /** The summoner, read from the generic envelope (`instances.caller_reactor`). A `core` instance is always
   *  summoned, so this is non-null here (the engine load guards a corrupt null). */
  callerReactor: ReactorName;
  target: DelegateTarget;
  snapshotId: SnapshotId;
  status: InstanceStatus;
  ambientGenerics: GenericSubstitution | null;
  engineState: EngineState;
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

/** A blob's ownership + descriptor row (the bytes live in the `BlobStore`). `ownerInstanceId` is `null` for
 *  one in transit mid-ascent; it cascades with its owner on teardown. */
export interface PersistedBlob {
  projectId: ProjectId;
  blobId: BlobId;
  ownerInstanceId: InstanceId | null;
  hash: string;
  size: number;
  contentType: string | null;
  semanticKind: SemanticKind;
}

/** The `core` instance extension write: its `core_instances` row + its thread tree. The generic envelope is
 *  written separately by the base reactor; scopes are an independent `ResourcePool` resource. */
export interface SerializedCoreInstance {
  instance: PersistedCoreInstance;
  threads: PersistedThread[];
}

/** Serialise a still-running `core` instance's extension (`core_instances`) + its threads into their row
 *  shapes. The generic envelope (id / kind / delegation / status) is written by the base reactor; scopes are
 *  the `ResourcePool`'s. */
export function serializeCoreInstance(
  projectId: ProjectId,
  instance: CoreInstance,
): SerializedCoreInstance {
  return {
    instance: {
      instanceId: instance.id,
      target: instance.target,
      snapshotId: agentSnapshot(instance.target),
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
  };
}

/** Serialise the project's permanent `api` management root as a bare instance row — kind `api`, no IR payload
 *  (no target / snapshot / engine state / threads). The api root is the only instance with no producing
 *  `delegate` turn of its own, yet it is the FK target of every run delegation's caller and of a run result's
/** Serialise one scope into its row shape — the unit the `ResourcePool` persists (`owner = null` for a scope
 *  in transit between owners). Scopes are CORE-global, owned by whichever instance (or the api root) holds a
 *  value that captures them, and live independently of any one instance's Layer 2. */
export function serializeScope(projectId: ProjectId, scope: Scope): PersistedScope {
  return {
    projectId,
    scopeId: scope.id,
    parentScopeId: scope.parentId,
    ownerInstanceId: scope.owner,
    values: scope.values,
  };
}

/** Serialise one blob's warm entry into its row shape — the unit the `ResourcePool` persists alongside
 *  scopes (`owner = null` for one in transit between owners). */
export function serializeBlob(
  projectId: ProjectId,
  blobId: BlobId,
  blob: BlobEntry,
): PersistedBlob {
  return {
    projectId,
    blobId,
    ownerInstanceId: blob.owner,
    hash: blob.hash,
    size: blob.size,
    contentType: blob.contentType ?? null,
    semanticKind: blob.semanticKind,
  };
}

/** The instance bookkeeping that has no dedicated column (its threads live in the threads table). The
 *  summoner (`callerReactor`) is NOT here — it is the instance's ambient on the generic envelope. */
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
  blobs: PersistedBlob[],
): DeserializedEngine {
  const threadsByInstance = new Map<InstanceId, Record<number, Thread>>();
  for (const row of threads) {
    const tree = threadsByInstance.get(row.instanceId) ?? {};
    tree[row.threadId] = row.payload;
    threadsByInstance.set(row.instanceId, tree);
  }

  const instanceMap: Record<InstanceId, CoreInstance> = {};
  for (const row of instances) {
    // The engine load returns only `core` instances (envelope ⋈ core_instances), so every row is complete.
    instanceMap[row.id] = {
      kind: "core",
      id: row.id,
      delegationId: row.delegationId,
      callerReactor: row.callerReactor,
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

  const blobMap: ProjectStore["blobs"] = {};
  for (const row of blobs) {
    blobMap[row.blobId] = {
      owner: row.ownerInstanceId,
      hash: row.hash,
      size: row.size,
      ...(row.contentType !== null ? { contentType: row.contentType } : {}),
      semanticKind: row.semanticKind,
    };
  }

  return { instances: instanceMap, scopes: scopeMap, blobs: blobMap, nextScopeId: maxScopeId + 1 };
}
