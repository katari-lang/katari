// Scope operations over the per-project, CORE-global scope store. A scope is a lexical-binding node
// (`parentId` -> enclosing scope); variable resolution walks the parent chain. Because lowering draws
// every `VariableId` from one module-global counter, a given id keys at most one scope along any single
// chain, so the walk is unambiguous (sibling iteration scopes reuse ids, but they never share a chain).
//
// Ownership (`owner`) drives cascade / ascent / intra-instance GC; it is set at allocation and only
// changes when an escaping value carries the scope to another instance (ascent). These helpers are
// pure structural operations on the store — lifecycle (cascade / ascent) lives in the instance layer.

import type { InstanceId } from "../ids.js";
import { type ScopeId, toScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { ProjectStore, Scope } from "./types.js";

/** Allocate a fresh, empty scope under `parentId`, owned by `owner` (`null` only while in-transit). */
export function allocateScope(
  store: ProjectStore,
  parentId: ScopeId | null,
  owner: InstanceId | null,
): ScopeId {
  const id = toScopeId(store.nextScopeId);
  store.nextScopeId += 1;
  store.scopes[id] = { id, parentId, owner, values: {} };
  addOwnedScope(store, id, owner);
  return id;
}

/** Add `scopeId` to `owner`'s bucket in the `scopesByOwner` index (a no-op for an in-transit scope). */
function addOwnedScope(store: ProjectStore, scopeId: ScopeId, owner: InstanceId | null): void {
  if (owner === null) return;
  let owned = store.scopesByOwner.get(owner);
  if (owned === undefined) {
    owned = new Set();
    store.scopesByOwner.set(owner, owned);
  }
  owned.add(scopeId);
}

/** Drop `scopeId` from `owner`'s bucket, removing the bucket once it empties (a no-op for an in-transit
 *  scope or a missing bucket). */
function removeOwnedScope(store: ProjectStore, scopeId: ScopeId, owner: InstanceId | null): void {
  if (owner === null) return;
  const owned = store.scopesByOwner.get(owner);
  if (owned === undefined) return;
  owned.delete(scopeId);
  if (owned.size === 0) store.scopesByOwner.delete(owner);
}

/** Re-own a scope, keeping the `scopesByOwner` index in step with `scope.owner`. */
export function setScopeOwner(
  store: ProjectStore,
  scope: Scope,
  newOwner: InstanceId | null,
): void {
  removeOwnedScope(store, scope.id, scope.owner);
  scope.owner = newOwner;
  addOwnedScope(store, scope.id, newOwner);
}

/** The scope ids `owner` currently owns (the live `scopesByOwner` bucket, copied so callers may mutate the
 *  store while iterating). */
export function scopesOwnedBy(store: ProjectStore, owner: InstanceId): ScopeId[] {
  return [...(store.scopesByOwner.get(owner) ?? [])];
}

/** Delete a scope from the store and drop it from its owner's bucket. */
export function deleteScope(store: ProjectStore, scopeId: ScopeId): void {
  const scope = store.scopes[scopeId];
  if (scope !== undefined) removeOwnedScope(store, scopeId, scope.owner);
  delete store.scopes[scopeId];
}

/** Rebuild `scopesByOwner` from the current `scopes` map — used after a bulk load / reset replaces the
 *  scopes wholesale (the incremental helpers maintain it during normal operation). */
export function rebuildScopeOwnerIndex(store: ProjectStore): void {
  store.scopesByOwner = new Map();
  for (const key of Object.keys(store.scopes)) {
    const scopeId = toScopeId(Number(key));
    const scope = store.scopes[scopeId];
    if (scope !== undefined) addOwnedScope(store, scopeId, scope.owner);
  }
}

/** Look up a scope by id; throws if it is absent (a corrupt graph, never a normal path). */
export function getScope(store: ProjectStore, scopeId: ScopeId): Scope {
  const scope = store.scopes[scopeId];
  if (scope === undefined) {
    throw new Error(`scope not found: ${scopeId}`);
  }
  return scope;
}

/**
 * Resolve a variable by walking from `scopeId` up the parent chain, returning the first binding found.
 * `undefined` means unbound — callers that expect a binding (an op reading its input) treat that as a
 * bug, while readers of an optional slot (a record field) map it to a `null` value.
 */
export function readVariable(
  store: ProjectStore,
  scopeId: ScopeId,
  variable: number,
): Value | undefined {
  let current: ScopeId | null = scopeId;
  while (current !== null) {
    const scope: Scope | undefined = store.scopes[current];
    if (scope === undefined) {
      return undefined;
    }
    if (variable in scope.values) {
      return scope.values[variable];
    }
    current = scope.parentId;
  }
  return undefined;
}

/** Bind a variable in the given scope (always the local scope — bindings never write through the chain). */
export function writeVariable(
  store: ProjectStore,
  scopeId: ScopeId,
  variable: number,
  value: Value,
): void {
  getScope(store, scopeId).values[variable] = value;
}

/**
 * Delete a binding from the given scope — the exact mirror of `writeVariable`, local-only: the compiler
 * emits a `drop` only for variables the SAME sequence wrote, and every one of that sequence's writes
 * landed in the executing thread's own scope, so the binding being released is local by construction
 * (deleting up the chain could never be right — an ancestor's binding is someone else's to release).
 */
export function dropVariable(store: ProjectStore, scopeId: ScopeId, variable: number): void {
  delete getScope(store, scopeId).values[variable];
}
