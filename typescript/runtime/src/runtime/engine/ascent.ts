// Resource reachability: the pure walker that finds every resource a value captures — a `closure`'s scope
// chain and a blob `ref`'s id, through nested records / arrays. The *ownership transition* a captured set
// undergoes when a value escapes one owner and lands in another (release → in-transit → reown) lives in the
// shared `ResourcePool` (`actor/resource-pool.ts`), which is what keeps a returned closure callable, and a
// returned blob readable, after the instance that built them is gone — for a sub-call (a core caller re-owns)
// and a run alike (the api root re-owns).
//
// NOTE: blob ownership is now real and persisted (`store.blobs` → the `blobs` table, via the `ResourcePool`),
// but the only producer today is a file upload, owned by the api root and retained for its lifetime — so no
// *engine* instance yet owns a blob whose ownership this walker would hand across a boundary (that arrives
// with large-value promotion / a blob prim). The walker is symmetric over scopes and blobs, so the moment an
// engine instance produces one its reachability is already correct.

import type { BlobId, ScopeId } from "../ids.js";
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
      case "tool":
        // A tool's reactor context may hold resources (a blob-backed value); keep them reachable.
        visit(current.context);
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
