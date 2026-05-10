// Runtime Value type. Identical in shape to the previous machine/value.ts
// except that closure values are now machine-local id references into
// `state.closures` (the actual block / captured scope live there). Reasons:
//   - agent-call-via-closure dispatch needs an opaque id to pass around
//   - GC can collect closures when no Value still references the id
//   - keeps Value purely structural, no captured state inside the type

import type { CtorId, LiteralValue, QualifiedName } from "../ir/types.js";
import type { ClosureId } from "./id.js";

export type Value =
  | { kind: "number"; value: number }
  | { kind: "string"; value: string }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "tuple"; elements: Value[] }
  | { kind: "array"; elements: Value[] }
  | { kind: "tagged"; ctorId: CtorId; fields: Record<string, Value> }
  | { kind: "closure"; closureId: ClosureId }
  // Top-level callable reference (agent / prim / ctor / external).
  // Carries only the qualified name; the runtime resolves it through
  // IRModule.entries on dispatch. Distinct from `closure` in that it
  // captures no lexical scope — GC reachability is bounded by the
  // value alone.
  | { kind: "agentLiteral"; qualifiedName: QualifiedName };

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
    case "literalValueAgent":
      return { kind: "agentLiteral", qualifiedName: literal.qualifiedName };
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
