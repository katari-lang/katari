import type { VarId } from "../ir/types.js";
import type { ScopeId } from "./id.js";
import type { Value } from "./value.js";

// ─── Types ──────────────────────────────────────────────────────────────────

export type Scope = {
  id: ScopeId;
  parentId: ScopeId | null;
  /** Memory cells keyed by `${varId}:${version}`. */
  cells: Map<string, MemoryCell>;
  /** Reference count for GC (closures, child scopes). */
  referenceCount: number;
};

export type MemoryCell =
  | { status: "empty" }
  | { status: "filled"; value: Value };

export type MemoryKey = {
  varId: VarId;
  version: number;
};

export function memoryKeyToString(key: MemoryKey): string {
  return `${key.varId}:${key.version}`;
}
