// Resource reachability: the pure walker that finds every resource a value captures — a `closure`'s scope
// chain (and, transitively, the chains of the closures those scopes bind) and a blob `ref`'s id, through
// nested records / arrays. The *ownership transition* a captured set undergoes when a value escapes one owner
// and lands in another (release → in-transit → reown) lives in the shared `ResourcePool`
// (`actor/resource-pool.ts`), which is what keeps a returned closure callable, and a returned blob readable,
// after the instance that built them is gone — for a sub-call (a core caller re-owns) and a run alike (the api
// root re-owns).
//
// NOTE: blob ownership is now real and persisted (`store.blobs` → the `blobs` table, via the `ResourcePool`),
// but the only producer today is a file upload, owned by the api root and retained for its lifetime — so no
// *engine* instance yet owns a blob whose ownership this walker would hand across a boundary (that arrives
// with large-value promotion / a blob prim). The walker is symmetric over scopes and blobs, so the moment an
// engine instance produces one its reachability is already correct.

import type { BlobId, ScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { ProjectStore, Scope } from "./types.js";

/** The scopes and blobs a value captures: every scope id along each closure's lexical chain, every scope
 *  reachable through those scopes' own bindings (transitively), and every blob id referenced. Records and
 *  arrays are walked into. The full set regardless of owner — callers filter by owner for the actual
 *  transition. */
export interface ReachableResources {
  scopes: Set<ScopeId>;
  blobs: Set<BlobId>;
}

/**
 * Walk a value's captured resources by the SAME rule the intra-instance GC marks with (`engine/gc.ts`): a
 * closure reaches its lexical chain, and each scope on that chain reaches whatever its bindings hold —
 * including a NESTED closure over a different chain. The two walks must agree, because they are the two halves
 * of one contract: this one decides what a crossing value carries to its new owner, the GC decides what that
 * owner may free. A shallow walk here made the halves disagree, and the value's nested closures lost their
 * environments — an inner closure parked on a region provide (a forked task closing over another closure) kept
 * only the outer chain, so the inner one's scopes stayed with the forker and died at its teardown.
 *
 * The graph is CYCLIC (a scope binds a closure that captures that same scope — every recursive local is one),
 * so `scopes` doubles as the visited set: a chain walk stops at an already-added id, and only newly added
 * scopes get their bindings drained.
 */
export function reachableResources(store: ProjectStore, value: Value): ReachableResources {
  const scopes = new Set<ScopeId>();
  const blobs = new Set<BlobId>();
  /** Scopes added but whose own bindings have not been walked yet. */
  const pending: ScopeId[] = [];
  const visit = (current: Value): void => {
    switch (current.kind) {
      case "closure":
        addScopeChain(store, current.scopeId, scopes, pending);
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
  while (pending.length > 0) {
    const scopeId = pending.pop();
    if (scopeId === undefined) break;
    const scope: Scope | undefined = store.scopes[scopeId];
    if (scope === undefined) continue;
    for (const bound of Object.values(scope.values)) visit(bound);
  }
  return { scopes, blobs };
}

/** Walk a scope's parent chain to the root, adding every id (stopping at an already-seen id, whose ancestors
 *  a previous walk therefore already added) and queueing each newly added scope for a bindings walk. */
function addScopeChain(
  store: ProjectStore,
  scopeId: ScopeId,
  into: Set<ScopeId>,
  pending: ScopeId[],
): void {
  let current: ScopeId | null = scopeId;
  while (current !== null && !into.has(current)) {
    const scope: Scope | undefined = store.scopes[current];
    if (scope === undefined) return;
    into.add(current);
    pending.push(current);
    current = scope.parentId;
  }
}
