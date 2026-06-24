// Resource ascent: a value that escapes an instance (returned to its caller) may capture resources — a
// `closure`'s scope (and that scope's ancestors the instance owns) and a blob `ref`'s bytes. Those must
// outlive the instance, so at teardown they are not dropped but set *in-transit* (`owner = null`), and the
// instance that receives the value re-owns them. This is what keeps a returned closure callable, and a
// returned blob readable, after the instance that built them is gone.
//
// NOTE: blobs have no producer in the runtime yet (no large-value promotion, no blob prim), so the blob
// half is currently inert — `store.blobOwners` stays empty. It is wired symmetrically to scopes so the
// moment blobs are produced their lifecycle is already correct. Two follow-ups remain: GC of a dropped
// blob's *bytes* (a `BlobStore.delete`, which needs the async store), and making `blobOwners` durable
// (persisted + rebuilt on reactivate, like scopes); today it is warm-store-only.

import type { BlobId, InstanceId, ScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { ProjectStore, Scope } from "./types.js";

/** The scopes and blobs a value captures: every scope id along each closure's lexical chain, and every
 *  blob id referenced. Records and arrays are walked into. The full set regardless of owner — callers
 *  filter by owner for the actual transition. */
export interface ReachableResources {
  scopes: Set<ScopeId>;
  blobs: Set<BlobId>;
}

export function reachableResources(store: ProjectStore, value: Value): ReachableResources {
  const scopes = new Set<ScopeId>();
  const blobs = new Set<BlobId>();
  const visit = (current: Value): void => {
    switch (current.kind) {
      case "closure":
        addScopeChain(store, current.scopeId, scopes);
        return;
      case "ref":
        blobs.add(current.blobId);
        return;
      case "record":
        for (const field of Object.values(current.fields)) visit(field);
        return;
      case "array":
        for (const element of current.elements) visit(element);
        return;
      default:
        return; // scalars / named agent capture no resources
    }
  };
  visit(value);
  return { scopes, blobs };
}

/** Walk a scope's parent chain to the root, adding every id (stopping at an already-seen id). */
function addScopeChain(store: ProjectStore, scopeId: ScopeId, into: Set<ScopeId>): void {
  let current: ScopeId | null = scopeId;
  while (current !== null && !into.has(current)) {
    const scope: Scope | undefined = store.scopes[current];
    if (scope === undefined) return;
    into.add(current);
    current = scope.parentId;
  }
}

/**
 * At an instance's teardown: lift the resources its escaping `value` captures out of the drop set — set
 * them in-transit (`owner = null`) instead of letting teardown drop them, so the value's recipient can
 * re-own them. Only the instance's own resources ascend; ancestors / blobs owned by others are untouched.
 */
export function ascendResources(store: ProjectStore, owner: InstanceId, value: Value): void {
  const { scopes, blobs } = reachableResources(store, value);
  for (const scopeId of scopes) {
    const scope = store.scopes[scopeId];
    if (scope?.owner === owner) scope.owner = null;
  }
  for (const blobId of blobs) {
    if (store.blobOwners[blobId] === owner) store.blobOwners[blobId] = null;
  }
}

/**
 * When an escaping value lands in an instance: claim the in-transit resources it captures (`owner = null`
 * → this instance). Resources already owned (by this caller or an ancestor) are left as they are.
 */
export function reownResources(store: ProjectStore, owner: InstanceId, value: Value): void {
  const { scopes, blobs } = reachableResources(store, value);
  for (const scopeId of scopes) {
    const scope = store.scopes[scopeId];
    if (scope?.owner === null) scope.owner = owner;
  }
  for (const blobId of blobs) {
    if (store.blobOwners[blobId] === null) store.blobOwners[blobId] = owner;
  }
}
