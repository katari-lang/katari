// Pattern matching shared between MatchThread (refutable, multi-arm) and
// UserThread (irrefutable, single bind). Returns either the bindings
// produced by the pattern or null if the pattern doesn't match the value.
//
// A linear-pattern violation (same VarId bound twice) is a compiler bug —
// surfaced as Error so the host poisons. The compiler's K0291 / K0301
// checks should make this unreachable.

import type { LiteralValue, MatchPattern, TypePatternTag } from "../ir/types.js";
import { bytesEqualsText, type Value } from "./value.js";

/** Returns a flat Record<varId, Value> on match, or null on miss. */
export function tryMatch(pattern: MatchPattern, value: Value): Record<number, Value> | null {
  const bindings: Record<number, Value> = {};
  return tryMatchInto(pattern, value, bindings) ? bindings : null;
}

function tryMatchInto(
  pattern: MatchPattern,
  value: Value,
  bindings: Record<number, Value>,
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
      const [ctorQName, fieldPatterns] = pattern.body;
      if (value.kind !== "tagged" || value.ctorId !== ctorQName) return false;
      for (const [fieldName, fieldPattern] of fieldPatterns) {
        const fv = value.fields[fieldName];
        if (fv === undefined) return false;
        if (!tryMatchInto(fieldPattern, fv, bindings)) return false;
      }
      return true;
    }
    case "matchPatternTuple": {
      // Tuples are stored as arrays at runtime; the pattern enforces
      // exact arity (matching the static type's tuple length, which
      // the solver already pins via 'tuple arity mismatch' / K0220).
      if (value.kind !== "array") return false;
      if (value.elements.length !== pattern.body.length) return false;
      for (let i = 0; i < pattern.body.length; i++) {
        const sp = pattern.body[i]!;
        const sv = value.elements[i]!;
        if (!tryMatchInto(sp, sv, bindings)) return false;
      }
      return true;
    }
    case "matchPatternTypeGuard": {
      const [tag, inner] = pattern.body;
      if (!matchesTypeTag(tag, value)) return false;
      return tryMatchInto(inner, value, bindings);
    }
    case "matchPatternRecord": {
      if (value.kind !== "record") return false;
      for (const [entryKey, sub] of pattern.body) {
        const fv = value.entries[entryKey];
        if (fv === undefined) return false;
        if (!tryMatchInto(sub, fv, bindings)) return false;
      }
      return true;
    }
    default: {
      const _exhaustive: never = pattern;
      throw new Error(
        `engine.pattern: unknown pattern kind: ${(_exhaustive as MatchPattern).kind}`,
      );
    }
  }
}

// Returns true when `value`'s runtime kind matches the type-guard `tag`.
// `integer` requires the underlying number to be integral (Number.isInteger);
// `number` accepts any number value. The `agent` tag accepts closure /
// agent-ref values (both `closure` and `agentLiteral` runtime kinds).
function matchesTypeTag(tag: TypePatternTag, value: Value): boolean {
  switch (tag) {
    case "typePatternTagInteger":
      return value.kind === "number" && Number.isInteger(value.value);
    case "typePatternTagNumber":
      return value.kind === "number";
    case "typePatternTagString":
      return value.kind === "string";
    case "typePatternTagBoolean":
      return value.kind === "boolean";
    case "typePatternTagAgent":
      return value.kind === "closure" || value.kind === "agentLiteral";
    default: {
      const _exhaustive: never = tag;
      throw new Error(`engine.pattern: unknown type pattern tag: ${_exhaustive}`);
    }
  }
}

function bindOnce(bindings: Record<number, Value>, varId: number, value: Value): void {
  if (Object.hasOwn(bindings, varId)) {
    throw new Error(
      `engine.pattern: VarId ${varId} bound more than once in one pattern (linear-pattern violation; compiler bug)`,
    );
  }
  bindings[varId] = value;
}

export function matchLiteral(literal: LiteralValue, value: Value): boolean {
  switch (literal.kind) {
    case "literalValueInteger":
      return value.kind === "number" && value.value === literal.integer;
    case "literalValueNumber":
      return value.kind === "number" && value.value === literal.number;
    case "literalValueString":
      // Compare CONTENT without fetching: inline reps compare text directly,
      // ref reps compare the literal's hash against the ref's hash.
      return value.kind === "string" && bytesEqualsText(value.rep, literal.string);
    case "literalValueBoolean":
      return value.kind === "boolean" && value.value === literal.boolean;
    case "literalValueNull":
      return value.kind === "null";
    case "literalValueAgent":
      // Agent literals are not used in pattern matching positions.
      return false;
    default: {
      const _exhaustive: never = literal;
      throw new Error(
        `engine.pattern: unknown literal kind: ${(_exhaustive as LiteralValue).kind}`,
      );
    }
  }
}
