import { VarId } from "../../ir/types.js";
import { ScopeId, ThreadId, WaitId } from "./id.js";
import { Value } from "./value.js";

export type Scope = {
  id: ScopeId;
  memoryCells: Map<string, MemoryCell>;
  // 0 ~ n versions
  latestVarVersions: Map<VarId, number>;
  referenceCount: number;
  parentId: ScopeId | null;
};

export type MemoryKey = {
  varId: VarId;
  version: number;
};

/** Serialize a MemoryKey to a string for use as a Map key. */
export function memoryKeyToString(key: MemoryKey): string {
  return `${key.varId}:${key.version}`;
}

/**
 * A memory cell is either waiting for a value to be filled,
 * or already filled (immutable once filled).
 */
export type MemoryCell =
  | { key: MemoryKey; status: "wait"; waiters: Set<WaitId> }
  | { key: MemoryKey; status: "filled"; value: Value };
