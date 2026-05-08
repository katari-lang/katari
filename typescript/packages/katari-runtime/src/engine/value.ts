// Runtime Value type. Identical in shape to the previous machine/value.ts.
// Closures carry a ScopeId pointing at the captured lexical scope.

import type { BlockId, CtorId, LiteralValue } from "../ir/types.js";
import type { ScopeId } from "./id.js";

export type Value =
  | { kind: "number"; value: number }
  | { kind: "string"; value: string }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "tuple"; elements: Value[] }
  | { kind: "array"; elements: Value[] }
  | { kind: "tagged"; ctorId: CtorId; fields: Record<string, Value> }
  | { kind: "closure"; blockId: BlockId; scopeId: ScopeId };

/** Convert an IR LiteralValue to a runtime Value. */
export function literalToValue(literal: LiteralValue): Value {
  switch (literal.kind) {
    case "literalValueInteger":
      return { kind: "number", value: literal.integer };
    case "literalValueNumber":
      return { kind: "number", value: literal.number };
    case "literalValueString":
      return { kind: "string", value: literal.string };
    case "literalValueBoolean":
      return { kind: "boolean", value: literal.boolean };
    case "literalValueNull":
      return { kind: "null" };
  }
}

/**
 * Singleton null value. Frozen so accidental mutation by any consumer
 * cannot corrupt every other null reference in the system.
 *
 * Immer treats this as auto-frozen too, so it remains immutable across
 * `produce` boundaries.
 */
export const NULL_VALUE: Value = Object.freeze({ kind: "null" }) as Value;
