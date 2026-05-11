// Pattern matching shared between MatchThread (refutable, multi-arm) and
// UserThread (irrefutable, single bind). Returns either the bindings
// produced by the pattern or null if the pattern doesn't match the value.
//
// A linear-pattern violation (same VarId bound twice) is a compiler bug —
// surfaced as Error so the host poisons. The compiler's K0291 / K0301
// checks should make this unreachable.

import { match, P } from "ts-pattern";
import type { LiteralValue, MatchPattern } from "../ir/types.js";
import type { Value } from "./value.js";

/** Returns a flat Record<varId, Value> on match, or null on miss. */
export function tryMatch(
  pattern: MatchPattern,
  value: Value,
): Record<number, Value> | null {
  const bindings: Record<number, Value> = {};
  return tryMatchInto(pattern, value, bindings) ? bindings : null;
}

function tryMatchInto(
  pattern: MatchPattern,
  value: Value,
  bindings: Record<number, Value>,
): boolean {
  return match(pattern)
    .with({ kind: "matchPatternAny" }, () => true)
    .with({ kind: "matchPatternVariable" }, (p) => {
      bindOnce(bindings, p.body, value);
      return true;
    })
    .with({ kind: "matchPatternLiteral" }, (p) => matchLiteral(p.body, value))
    .with({ kind: "matchPatternConstructor" }, (p) => {
      const [ctorQName, fieldPatterns] = p.body;
      if (value.kind !== "tagged" || value.ctorId !== ctorQName) return false;
      for (const [fieldName, fieldPattern] of fieldPatterns) {
        const fv = value.fields[fieldName];
        if (fv === undefined) return false;
        if (!tryMatchInto(fieldPattern, fv, bindings)) return false;
      }
      return true;
    })
    .with({ kind: "matchPatternTuple" }, (p) => {
      if (value.kind !== "tuple") return false;
      if (value.elements.length !== p.body.length) return false;
      for (let i = 0; i < p.body.length; i++) {
        const sp = p.body[i]!;
        const sv = value.elements[i]!;
        if (!tryMatchInto(sp, sv, bindings)) return false;
      }
      return true;
    })
    .exhaustive();
}

function bindOnce(
  bindings: Record<number, Value>,
  varId: number,
  value: Value,
): void {
  if (Object.prototype.hasOwnProperty.call(bindings, varId)) {
    throw new Error(
      `engine.pattern: VarId ${varId} bound more than once in one pattern (linear-pattern violation; compiler bug)`,
    );
  }
  bindings[varId] = value;
}

export function matchLiteral(literal: LiteralValue, value: Value): boolean {
  return match([literal, value] as const)
    .with([{ kind: "literalValueInteger" }, { kind: "number" }], ([l, v]) => v.value === l.integer)
    .with([{ kind: "literalValueNumber" }, { kind: "number" }], ([l, v]) => v.value === l.number)
    .with([{ kind: "literalValueString" }, { kind: "string" }], ([l, v]) => v.value === l.string)
    .with([{ kind: "literalValueBoolean" }, { kind: "boolean" }], ([l, v]) => v.value === l.boolean)
    .with([{ kind: "literalValueNull" }, { kind: "null" }], () => true)
    .with([P._, P._], () => false)
    .exhaustive();
}
