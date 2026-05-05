import type { VarId } from "../ir/types.js";
import { createScopeId, type ScopeId } from "./id.js";
import type { MachineState } from "./machine.js";
import type { Value } from "./value.js";

// ─── Types ──────────────────────────────────────────────────────────────────

export type Scope = {
  id: ScopeId;
  parentId: ScopeId | null;
  values: Map<VarId, Value>;
};

// ─── Scope Operations ───────────────────────────────────────────────────────

export function getScope(state: MachineState, scopeId: ScopeId): Scope {
  const scope = state.scopes.get(scopeId);
  if (!scope) {
    throw new Error(`Scope with id ${scopeId} not found`);
  }
  return scope;
}

export function createScope(
  state: MachineState,
  parentId: ScopeId | null,
): Scope {
  const id = createScopeId();
  const scope: Scope = {
    id,
    parentId,
    values: new Map(),
  };
  state.scopes.set(id, scope);
  return scope;
}

export function setValueInScope(
  state: MachineState,
  scopeId: ScopeId,
  varId: VarId,
  value: Value,
): void {
  const scope = getScope(state, scopeId);
  scope.values.set(varId, value);
}

export function getValueFromScope(
  state: MachineState,
  scopeId: ScopeId,
  varId: VarId,
): Value {
  let currentScopeId: ScopeId | null = scopeId;
  while (currentScopeId) {
    const scope = getScope(state, currentScopeId);
    if (scope.values.has(varId)) {
      return scope.values.get(varId)!;
    }
    currentScopeId = scope.parentId;
  }
  throw new Error(
    `Variable ${varId} not found in scope ${scopeId} or its ancestors`,
  );
}

// ─── Garbage Collection ─────────────────────────────────────────────────────

/**
 * Collect all ScopeIds reachable from a Value (recursively).
 * Adds newly discovered scopeIds to both the reachable set and the worklist.
 */
function collectScopeIdsFromValue(
  value: Value,
  reachable: Set<ScopeId>,
  worklist: ScopeId[],
): void {
  switch (value.kind) {
    case "closure":
      if (!reachable.has(value.scopeId)) {
        reachable.add(value.scopeId);
        worklist.push(value.scopeId);
      }
      break;
    case "tuple":
    case "array":
      for (const element of value.elements) {
        collectScopeIdsFromValue(element, reachable, worklist);
      }
      break;
    case "tagged":
      for (const fieldValue of Object.values(value.fields)) {
        collectScopeIdsFromValue(fieldValue, reachable, worklist);
      }
      break;
    default:
      break;
  }
}

/**
 * Mark-and-sweep GC for scopes.
 * Call this after all synchronous processing of an external event is complete.
 *
 * At GC time, all values are committed to scopes (no in-flight values on threads).
 * Roots: all live threads' scopeIds.
 * Trace: follow parentId chains and closure scopeIds within scope values.
 * Sweep: delete all scopes not in the reachable set.
 */
export function collectGarbage(state: MachineState): void {
  const reachable = new Set<ScopeId>();
  const worklist: ScopeId[] = [];

  // 1. Roots: all live threads' scopeIds
  for (const thread of state.threads.values()) {
    if (!reachable.has(thread.scopeId)) {
      reachable.add(thread.scopeId);
      worklist.push(thread.scopeId);
    }
  }

  // 2. Trace: expand reachable set
  while (worklist.length > 0) {
    const scopeId = worklist.pop()!;
    const scope = state.scopes.get(scopeId);
    if (!scope) continue;

    // Follow parent chain
    if (scope.parentId && !reachable.has(scope.parentId)) {
      reachable.add(scope.parentId);
      worklist.push(scope.parentId);
    }

    // Follow closure references within scope values
    for (const value of scope.values.values()) {
      collectScopeIdsFromValue(value, reachable, worklist);
    }
  }

  // 3. Sweep: delete unreachable scopes
  for (const scopeId of state.scopes.keys()) {
    if (!reachable.has(scopeId)) {
      state.scopes.delete(scopeId);
    }
  }
}
