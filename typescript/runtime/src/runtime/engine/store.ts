// The per-project warm state and its allocators. `ProjectStore` is the in-memory working set a
// ProjectActor holds: every loaded instance plus the CORE-global scope store they share. Persistent ids
// (instance / delegation / …) are UUIDs minted in `ids.ts`; the cheap engine-local ids (thread / call /
// ask) are monotonic counters living on the instance, and scopes on the store — allocated here.

import {
  type AskId,
  type CallId,
  type InstanceId,
  type ThreadId,
  toAskId,
  toCallId,
  toThreadId,
} from "../ids.js";
import type { CoreInstance, ProjectStore } from "./types.js";

/** A fresh, empty warm store for a project (scope ids start at 0). */
export function createProjectStore(): ProjectStore {
  return { instances: {}, scopes: {}, scopesByOwner: new Map(), nextScopeId: 0, blobs: {} };
}

/** Look up a loaded core instance; throws if absent (the caller routed to an instance not in the store). */
export function getInstance(store: ProjectStore, instanceId: InstanceId): CoreInstance {
  const instance = store.instances[instanceId];
  if (instance === undefined) {
    throw new Error(`instance not loaded: ${instanceId}`);
  }
  return instance;
}

/** Look up a loaded core instance, or `undefined` if it is not in the warm set. */
export function findInstance(
  store: ProjectStore,
  instanceId: InstanceId,
): CoreInstance | undefined {
  return store.instances[instanceId];
}

/** Allocate the next thread id within an instance's local thread tree. */
export function allocateThreadId(instance: CoreInstance): ThreadId {
  const id = toThreadId(instance.nextThreadId);
  instance.nextThreadId += 1;
  return id;
}

/** Allocate the next call id (a parent's handle on one outstanding child) within an instance. */
export function allocateCallId(instance: CoreInstance): CallId {
  const id = toCallId(instance.nextCallId);
  instance.nextCallId += 1;
  return id;
}

/** Allocate the next ask id (a thread's handle on one outstanding upward ask) within an instance. */
export function allocateAskId(instance: CoreInstance): AskId {
  const id = toAskId(instance.nextAskId);
  instance.nextAskId += 1;
  return id;
}
