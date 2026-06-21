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
  return id;
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
