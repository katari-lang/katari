// Pattern matching shared between MatchThread (refutable, multiple arms) and
// UserThread (irrefutable, single bind via statementBindPattern). Lives at the
// machine layer so neither thread file needs to import the other.
//
// `tryMatch` returns either a flat Map<VarId, Value> of all variable bindings
// produced by the pattern, or null when the pattern does not match the value.
// Linear-pattern violations (the same VarId bound twice within one pattern) are
// surfaced as an Error: the compiler's exhaustiveness/linearity checks ought to
// prevent them, so reaching this case at runtime indicates a compiler bug.

import type { LiteralValue, MatchPattern, VarId } from "../ir/types.js";
import type { Value } from "./value.js";

export function tryMatch(
  pattern: MatchPattern,
  value: Value,
): Map<VarId, Value> | null {
  const bindings = new Map<VarId, Value>();
  return tryMatchInto(pattern, value, bindings) ? bindings : null;
}

function tryMatchInto(
  pattern: MatchPattern,
  value: Value,
  bindings: Map<VarId, Value>,
): boolean {
  switch (pattern.kind) {
    case "matchPatternAny":
      return true;

    case "matchPatternVariable":
      bindOnce(bindings, pattern.body, value);
      return true;

    case "matchPatternLiteral":
      return matchLiteral(pattern.body, value);

    case "matchPatternConstructor": {
      const [ctorId, fieldPatterns] = pattern.body;
      if (value.kind !== "tagged" || value.ctorId !== ctorId) return false;
      for (const [fieldName, fieldPattern] of fieldPatterns) {
        const fieldValue = value.fields[fieldName];
        if (fieldValue === undefined) return false;
        if (!tryMatchInto(fieldPattern, fieldValue, bindings)) return false;
      }
      return true;
    }

    case "matchPatternTuple": {
      if (value.kind !== "tuple") return false;
      if (value.elements.length !== pattern.body.length) return false;
      for (let i = 0; i < pattern.body.length; i++) {
        const subPattern = pattern.body[i];
        const subValue = value.elements[i];
        if (subPattern === undefined || subValue === undefined) return false;
        if (!tryMatchInto(subPattern, subValue, bindings)) return false;
      }
      return true;
    }
  }
}

function bindOnce(
  bindings: Map<VarId, Value>,
  varId: VarId,
  value: Value,
): void {
  if (bindings.has(varId)) {
    throw new Error(
      `pattern.tryMatch: VarId ${varId} bound more than once in a single pattern (linear-pattern violation; compiler bug)`,
    );
  }
  bindings.set(varId, value);
}

export function matchLiteral(literal: LiteralValue, value: Value): boolean {
  switch (literal.kind) {
    case "literalValueInteger":
      return value.kind === "number" && value.value === literal.integer;
    case "literalValueNumber":
      return value.kind === "number" && value.value === literal.number;
    case "literalValueString":
      return value.kind === "string" && value.value === literal.string;
    case "literalValueBoolean":
      return value.kind === "boolean" && value.value === literal.boolean;
    case "literalValueNull":
      return value.kind === "null";
  }
}
