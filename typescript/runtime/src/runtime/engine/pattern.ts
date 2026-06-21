// Pattern matching: walk an IR `Pattern` against a `Value`, binding each `PatternVariable` position into
// `scopeId`, and report whether it matched. The whole nested pattern is kept (no tag-cascade lowering),
// so this is a direct structural recursion. Bindings are written eagerly; on a failed match the partial
// bindings are harmless — a `match` arm that fails is abandoned and its scope is never read.

import type { Pattern } from "@katari-lang/types";
import type { ScopeId } from "../ids.js";
import { literalToValue, valueEquals, valueMatchesTag } from "../value/codec.js";
import type { Value } from "../value/types.js";
import type { StepContext } from "./context.js";
import { writeVariable } from "./scope.js";

/** A missing record / constructor field reads as `null` (mirrors `obj.field` on an absent optional). */
const NULL_VALUE: Value = { kind: "null" };

export function matchPattern(
  ctx: StepContext,
  scopeId: ScopeId,
  pattern: Pattern,
  value: Value,
): boolean {
  switch (pattern.kind) {
    case "any":
      return true;
    case "variable":
      writeVariable(ctx.store, scopeId, pattern.variable, value);
      return true;
    case "literal":
      return valueEquals(value, literalToValue(pattern.value));
    case "constructor":
      // A tagged `data` value of exactly this constructor; recurse into the named fields.
      if (value.kind !== "record" || value.ctor !== pattern.name) return false;
      return matchFields(ctx, scopeId, pattern.fields, value.fields);
    case "record":
      // Width subtyping (`data <: object`): only the listed keys must match; extras + any ctor ignored.
      if (value.kind !== "record") return false;
      return matchFields(ctx, scopeId, pattern.fields, value.fields);
    case "tuple": {
      if (value.kind !== "array" || value.elements.length !== pattern.elements.length) return false;
      for (let index = 0; index < pattern.elements.length; index += 1) {
        const element = value.elements[index];
        const elementPattern = pattern.elements[index];
        if (element === undefined || elementPattern === undefined) return false;
        if (!matchPattern(ctx, scopeId, elementPattern, element)) return false;
      }
      return true;
    }
    case "typeGuard":
      // Narrow on the runtime tag, then match the inner pattern against the same value.
      return (
        valueMatchesTag(value, pattern.tag) && matchPattern(ctx, scopeId, pattern.pattern, value)
      );
  }
}

/** Match a list of `(field, pattern)` against a record's fields (each absent field reads as `null`). */
function matchFields(
  ctx: StepContext,
  scopeId: ScopeId,
  fields: Array<[string, Pattern]>,
  values: Record<string, Value>,
): boolean {
  for (const [field, fieldPattern] of fields) {
    const fieldValue = values[field] ?? NULL_VALUE;
    if (!matchPattern(ctx, scopeId, fieldPattern, fieldValue)) return false;
  }
  return true;
}
