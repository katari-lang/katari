import type { CtorId } from "../ir/types.js";

export type ClosureId = string;

/** Runtime value. */
export type Value =
  | { kind: "number"; value: number }
  | { kind: "string"; value: string }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "tuple"; elements: Value[] }
  | { kind: "tagged"; ctorId: CtorId; fields: Record<string, Value> }
  | { kind: "closure"; closureId: ClosureId };
