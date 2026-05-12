// Bidirectional codec between the runtime `Value` tagged union and a
// schema-less raw JSON form. The codec is reversible by relying on the
// `$ctor` / `$callable` discriminators the compiler emits in JSON
// Schema:
//
//   * Tagged values  ←→  `{$ctor: "module.name", ...fieldsRaw}`
//   * Callables      ←→  `{$callable: "module.name" | "closure:N"}`
//   * Primitives     ←→  themselves (`5`, `"hi"`, `true`, `null`)
//   * Arrays         ←→  arrays. Tuples share this representation
//     (they're a single 'kind: "array"' Value variant; arity is
//     enforced by static typing + pattern matching, not at the
//     runtime level), so no special-casing is needed at the wire.
//
// REST clients / AI tool-call results / sidecar handlers all speak this
// raw form; the runtime adapts at the boundary using these helpers
// instead of forcing callers to hand-write `Value` objects.
//
// **Schema-less round-trip guarantee**: `valueFromRaw(valueToRaw(v))`
// equals `v` for every Value variant. Tuple and array are the same
// Value variant at runtime, so there is no ambiguity to recover.

import type { ClosureId } from "./engine/id.js";
import type { Value } from "./engine/value.js";
import type { QualifiedName } from "./ir/types.js";

/** Discriminator key for the constructor identity of a tagged value. */
export const CTOR_DISCRIMINATOR = "$ctor";

/** Discriminator key for a callable reference. */
export const CALLABLE_DISCRIMINATOR = "$callable";

/** Raw value: a JSON-shaped subset (numbers, strings, booleans, null,
 * arrays, objects). Object shapes carrying a `$ctor` / `$callable`
 * discriminator are decoded into the corresponding 'Value' variant. */
export type RawValue =
  | number
  | string
  | boolean
  | null
  | RawValue[]
  | { [key: string]: RawValue };

/**
 * Encode a runtime 'Value' to its raw JSON form. The encoding is
 * total: every 'Value' variant has a well-defined raw representation
 * (see module-level doc for the mapping).
 */
export function valueToRaw(value: Value): RawValue {
  switch (value.kind) {
    case "number":
      return value.value;
    case "string":
      return value.value;
    case "boolean":
      return value.value;
    case "null":
      return null;
    case "array":
      return value.elements.map(valueToRaw);
    case "tagged": {
      const out: Record<string, RawValue> = {
        [CTOR_DISCRIMINATOR]: value.ctorId,
      };
      for (const [k, v] of Object.entries(value.fields)) {
        out[k] = valueToRaw(v);
      }
      return out;
    }
    case "closure":
      return { [CALLABLE_DISCRIMINATOR]: `closure:${value.closureId}` };
    case "agentLiteral":
      return { [CALLABLE_DISCRIMINATOR]: value.qualifiedName };
  }
}

/**
 * Decode a raw JSON value into a runtime 'Value'. Schema-less: relies
 * on the `$ctor` / `$callable` discriminators when present; primitives
 * and arrays map to their obvious 'Value' variant.
 *
 * Throws 'RawValueDecodeError' if the input contains something that
 * can't be mapped (e.g. `undefined`, a function, or a `$callable` with
 * a malformed value).
 */
export function valueFromRaw(raw: unknown): Value {
  if (raw === null) return { kind: "null" };
  switch (typeof raw) {
    case "number":
      return { kind: "number", value: raw };
    case "string":
      return { kind: "string", value: raw };
    case "boolean":
      return { kind: "boolean", value: raw };
    case "object":
      break;
    default:
      throw new RawValueDecodeError(
        `valueFromRaw: cannot decode '${typeof raw}' value`,
      );
  }
  if (Array.isArray(raw)) {
    return { kind: "array", elements: raw.map(valueFromRaw) };
  }
  const obj = raw as Record<string, unknown>;
  if (CALLABLE_DISCRIMINATOR in obj) {
    return decodeCallable(obj[CALLABLE_DISCRIMINATOR]);
  }
  if (CTOR_DISCRIMINATOR in obj) {
    return decodeTagged(obj);
  }
  // Bare object with no discriminator. Default to the anonymous-record
  // sentinel ctor so the value survives unchanged through the runtime
  // (the receiver of an anonymous record can still walk fields).
  const fields: Record<string, Value> = {};
  for (const [k, v] of Object.entries(obj)) {
    fields[k] = valueFromRaw(v);
  }
  return { kind: "tagged", ctorId: "<anonymous>.record", fields };
}

/** Decoding error surfaced from 'valueFromRaw' for inputs that can't be
 * mapped to any 'Value' variant. */
export class RawValueDecodeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RawValueDecodeError";
  }
}

function decodeCallable(rawId: unknown): Value {
  if (typeof rawId !== "string") {
    throw new RawValueDecodeError(
      `valueFromRaw: $callable must be a string, got ${typeof rawId}`,
    );
  }
  if (rawId.startsWith("closure:")) {
    const n = Number(rawId.slice("closure:".length));
    if (!Number.isInteger(n) || n < 0) {
      throw new RawValueDecodeError(
        `valueFromRaw: malformed closure callable '${rawId}'`,
      );
    }
    return { kind: "closure", closureId: n as ClosureId };
  }
  return { kind: "agentLiteral", qualifiedName: rawId as QualifiedName };
}

function decodeTagged(obj: Record<string, unknown>): Value {
  const ctorRaw = obj[CTOR_DISCRIMINATOR];
  if (typeof ctorRaw !== "string") {
    throw new RawValueDecodeError(
      `valueFromRaw: $ctor must be a string, got ${typeof ctorRaw}`,
    );
  }
  const fields: Record<string, Value> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (k === CTOR_DISCRIMINATOR) continue;
    fields[k] = valueFromRaw(v);
  }
  return { kind: "tagged", ctorId: ctorRaw as QualifiedName, fields };
}
