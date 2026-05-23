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

/** Discriminator key for an opaque secret string (sidecar wire form).
 * The value behind the discriminator is the **plaintext** secret —
 * acceptable on the outbound side (sidecar trust assumption) but
 * forbidden on the inbound side (sidecar must not return credentials
 * up to the runtime). For storage, see 'value-tree-walk'. */
export const SECRET_DISCRIMINATOR = "$secret";

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
      // NaN / ±Infinity serialise as `null` under JSON.stringify, which
      // would silently corrupt a sidecar round-trip. Refuse at the
      // boundary so the bug surfaces where it originates.
      if (!Number.isFinite(value.value)) {
        throw new RawValueDecodeError(
          `valueToRaw: non-finite number ${value.value} cannot be serialized`,
        );
      }
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
      // NOTE: closure ids are machine-local + persistent-state-coupled.
      // The encoded `closure:N` string is stable WITHIN a single
      // snapshot's lifetime but MUST NOT be persisted by FFI handlers
      // or relayed to LLMs as a stable callable identifier — across
      // snapshots the N space is reassigned. Pass agent-literal qnames
      // back when the value needs to survive a snapshot swap.
      return { [CALLABLE_DISCRIMINATOR]: `closure:${value.closureId}` };
    case "agentLiteral":
      return { [CALLABLE_DISCRIMINATOR]: value.qualifiedName };
    case "secret":
      // Outbound to sidecar: emit the plaintext under '$secret'. The
      // sidecar lives in the same trust boundary (same host, same
      // operator) and is the only party that legitimately consumes
      // the cleartext (e.g. an HTTP Authorization header). For the
      // **storage** boundary the secret is intercepted upstream by
      // 'value-tree-walk' → 'secret-crypto', so the plaintext never
      // reaches the JSONB column.
      return { [SECRET_DISCRIMINATOR]: value.value };
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
      if (!Number.isFinite(raw)) {
        throw new RawValueDecodeError(
          `valueFromRaw: non-finite number ${raw}`,
        );
      }
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
  if (SECRET_DISCRIMINATOR in obj) {
    // Sidecar IPC trust direction is one-way: secrets flow OUT to the
    // sidecar (which uses them, e.g. as Authorization headers) but
    // MUST NOT flow back. A sidecar handler returning a `$secret`
    // is either a bug or a deliberate exfiltration attempt; refuse
    // loudly. Storage decryption uses a separate walker
    // ('value-tree-walk.decryptSecretsInValueTree') rather than
    // routing through 'valueFromRaw'.
    throw new RawValueDecodeError(
      `valueFromRaw: refusing to decode '${SECRET_DISCRIMINATOR}' — secrets must not cross the sidecar→runtime boundary`,
    );
  }
  // Bare object with no discriminator: every object-shaped Value in
  // Katari is either a tagged ctor instance (carrying `$ctor`) or a
  // callable reference (carrying `$callable`). A raw object missing
  // both means the wire shape contradicts the schema — fail loudly so
  // the boundary surfaces the bug instead of producing a sentinel
  // value that pretends to be a record.
  throw new RawValueDecodeError(
    `valueFromRaw: object missing '${CTOR_DISCRIMINATOR}' / '${CALLABLE_DISCRIMINATOR}' discriminator: ${JSON.stringify(obj).slice(0, 80)}`,
  );
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
  // Use a null-prototype object so a hostile payload carrying
  // `__proto__` / `constructor` / `prototype` can't reach
  // Object.prototype via the `fields` record.
  const fields: Record<string, Value> = Object.create(null);
  for (const [k, v] of Object.entries(obj)) {
    if (k === CTOR_DISCRIMINATOR) continue;
    if (k === "__proto__" || k === "constructor" || k === "prototype") {
      throw new RawValueDecodeError(
        `valueFromRaw: forbidden tagged field name '${k}'`,
      );
    }
    fields[k] = valueFromRaw(v);
  }
  return { kind: "tagged", ctorId: ctorRaw as QualifiedName, fields };
}
