import { BlockId, VarId } from "../ir/types.js";
import { ScopeId } from "./types/id.js";
import {
  MemoryCell,
  MemoryKey,
  memoryKeyToString,
  Scope,
} from "./types/memory.js";
import { MachineState } from "./types/state.js";
import { Value } from "./types/value.js";

export function incrementReferenceCount(
  state: MachineState,
  scopeId: ScopeId,
): void {
  const scope = getScope(state, scopeId);
  scope.referenceCount++;
}

export function decrementReferenceCount(
  state: MachineState,
  scopeId: ScopeId,
): void {
  const scope = getScope(state, scopeId);
  scope.referenceCount--;
  // If reference count drops to 0, we can clean up this scope's memory cells
  if (scope.referenceCount === 0) {
    releaseScope(state, scopeId);
  }
}

export function createScope(
  state: MachineState,
  parentId: ScopeId | null,
): Scope {
  const id = crypto.randomUUID() as ScopeId;
  const scope: Scope = {
    id,
    memoryCells: new Map(),
    latestVarVersions: new Map(),
    referenceCount: 0,
    parentId,
  };
  state.scopes.set(id, scope);
  // increment parent scope's reference count
  if (parentId) {
    const parentScope = state.scopes.get(parentId);
    if (!parentScope) {
      throw new Error(`Parent scope not found for id: ${parentId}`);
    }
    parentScope.referenceCount++;
  }
  return scope;
}

export function getScope(state: MachineState, scopeId: ScopeId): Scope {
  const scope = state.scopes.get(scopeId);
  if (!scope) {
    throw new Error(`Scope not found for id: ${scopeId}`);
  }
  return scope;
}

export function releaseScope(state: MachineState, scopeId: ScopeId): void {
  const scope = getScope(state, scopeId);
  // decrement closure reference count for all closures captured by this scope
  for (const cell of scope.memoryCells.values()) {
    if (cell.status === "filled" && cell.value.kind === "closure") {
      const closureScope = getScope(state, cell.value.scopeId);
      decrementReferenceCount(state, closureScope.id);
    }
  }
  // decrement parent scope's reference count
  if (scope.parentId) {
    const parentScope = getScope(state, scope.parentId);
    decrementReferenceCount(state, parentScope.id);
  }
  // remove the scope itself
  state.scopes.delete(scopeId);
}

export function lookupMemoryCell(
  state: MachineState,
  scopeId: ScopeId,
  key: MemoryKey,
): MemoryCell | null {
  const scope = getScope(state, scopeId);
  const cellKey = memoryKeyToString(key);
  const cell = scope.memoryCells.get(cellKey);
  if (cell) {
    return cell;
  }
  // If not found in current scope, look up in parent scope
  if (scope.parentId) {
    return lookupMemoryCell(state, scope.parentId, key);
  }
  return null; // not found in any scope
}

export function allocateMemoryCell(
  state: MachineState,
  scopeId: ScopeId,
  varId: VarId,
): [MemoryKey, MemoryCell] {
  const version = getLatestVarVersion(state, scopeId, varId) + 1 || 0;
  const key: MemoryKey = { varId, version };
  const scope = getScope(state, scopeId);
  const cellKey = memoryKeyToString(key);
  if (scope.memoryCells.has(cellKey)) {
    throw new Error(`Memory cell already exists for key: ${cellKey}`);
  }
  const cell: MemoryCell = { key, status: "wait", waiters: new Set() };
  scope.memoryCells.set(cellKey, cell);
  return [key, cell];
}

export function fillMemoryCell(
  state: MachineState,
  scopeId: ScopeId,
  key: MemoryKey,
  value: Value,
): void {
  const scope = getScope(state, scopeId);
  const cellKey = memoryKeyToString(key);
  const cell = scope.memoryCells.get(cellKey);
  if (!cell) {
    throw new Error(`Memory cell not found for key: ${cellKey}`);
  }
  if (cell.status === "filled") {
    throw new Error(`Memory cell already filled for key: ${cellKey}`);
  }
  // Update the cell to filled status with the value
  scope.memoryCells.set(cellKey, { key, status: "filled", value });
}

export function getLatestVarVersion(
  state: MachineState,
  scopeId: ScopeId,
  varId: VarId,
): number {
  const scope = getScope(state, scopeId);
  const version = scope.latestVarVersions.get(varId);
  if (version === undefined) {
    throw new Error(
      `Variable version not found for varId: ${varId} in scopeId: ${scopeId}`,
    );
  }
  return version;
}

export function makeClosureValue(
  state: MachineState,
  blockId: BlockId,
  scopeId: ScopeId,
): Value {
  const scope = getScope(state, scopeId);
  scope.referenceCount++;
  return { kind: "closure", blockId, scopeId };
}
