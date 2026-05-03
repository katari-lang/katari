import type { BlockId, CtorId } from "../../ir/types.js";
import { ScopeId } from "./id.js";

export type ClosureId = string;

/** Runtime value. */
export type Value =
  | { kind: "number"; value: number }
  | { kind: "string"; value: string }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "tuple"; elements: Value[] }
  | { kind: "tagged"; ctorId: CtorId; fields: Record<string, Value> }
  | { kind: "closure"; blockId: BlockId; scopeId: ScopeId };
