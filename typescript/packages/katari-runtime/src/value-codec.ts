// Bidirectional codec between the runtime `Value` tagged union and a
// schema-less raw JSON form. Decoding routes plain objects by
// discriminator priority:
//
//   1. `{$constructor: "...", ...fieldsRaw}`     → tagged value
//   2. `{$agent: "module.name" | "closure:N"}` → callable
//   3. `{$secret: "..."}` (inbound)       → refused (one-way out)
//   4. plain object (none of the above)   → record
//
// Round-trip guarantee is *one-way*: `valueFromRaw(valueToRaw(v))`
// recovers every Value variant **except** records whose keys happen
// to coincide with a reserved discriminator. A record carrying a
// `$constructor` key written to the wire is read back as a tagged value;
// users should not mix reserved discriminator keys into record data.
//
// Other mappings:
//   * Primitives     ←→  themselves (`5`, `"hi"`, `true`, `null`)
//   * Arrays         ←→  arrays. Tuples share this representation
//     (they're a single 'kind: "array"' Value variant; arity is
//     enforced by static typing + pattern matching, not at the
//     runtime level), so no special-casing is needed at the wire.
//
// REST clients / AI tool-call results / sidecar handlers all speak this
// raw form; the runtime adapts at the boundary using these helpers
// instead of forcing callers to hand-write `Value` objects.

import type { ClosureId } from "./engine/id.js";
import type { Value } from "./engine/value.js";
import type { QualifiedName } from "./ir/types.js";

// Re-export the canonical RawValue type from @katari-lang/types for
// backward compatibility — consumers that import from this module
// (`@katari-lang/runtime/value-codec`) continue to get the type.
export type { RawValue } from "@katari-lang/types";
import type { RawValue } from "@katari-lang/types";

/** Discriminator key for the constructor identity of a tagged value. */
export const CTOR_DISCRIMINATOR = "$constructor";

/** Discriminator key for a callable reference. */
export const CALLABLE_DISCRIMINATOR = "$agent";

/** Discriminator key for an opaque secret string (sidecar wire form).
 * The value behind the discriminator is the **plaintext** secret —
 * acceptable on the outbound side (sidecar trust assumption) but
 * forbidden on the inbound side (sidecar must not return credentials
 * up to the runtime). For storage, see 'value-tree-walk'. */
export const SECRET_DISCRIMINATOR = "$secret";

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
    case "record": {
      // Encode as a plain object. Reserved-discriminator keys
      // (`$constructor` / `$agent` / `$secret`) are technically writable
      // here, but the decoder will then misread the value as a
      // tagged / callable / secret on the inbound side — see the
      // module-level note about round-trip caveats.
      const out: Record<string, RawValue> = {};
      for (const [k, v] of Object.entries(value.entries)) {
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
 * on the `$constructor` / `$agent` discriminators when present; primitives
 * and arrays map to their obvious 'Value' variant.
 *
 * Throws 'RawValueDecodeError' if the input contains something that
 * can't be mapped (e.g. `undefined`, a function, or a `$agent` with
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
  // Discriminator priority (Plan D):
  //   1. $constructor       → tagged value
  //   2. $agent   → callable
  //   3. $secret     → refused (one-way out-only flow)
  //   4. (none)      → record
  if (CTOR_DISCRIMINATOR in obj) {
    return decodeTagged(obj);
  }
  if (CALLABLE_DISCRIMINATOR in obj) {
    return decodeCallable(obj[CALLABLE_DISCRIMINATOR]);
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
  return decodeRecord(obj);
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
      `valueFromRaw: $agent must be a string, got ${typeof rawId}`,
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

/** Reject `__proto__` / `constructor` / `prototype` keys that could
 *  pollute Object.prototype when written into a record. */
function assertSafeKeys(obj: Record<string, unknown>): void {
  for (const k of Object.keys(obj)) {
    if (k === "__proto__" || k === "constructor" || k === "prototype") {
      throw new RawValueDecodeError(
        `valueFromRaw: forbidden key '${k}'`,
      );
    }
  }
}

function decodeTagged(obj: Record<string, unknown>): Value {
  const ctorRaw = obj[CTOR_DISCRIMINATOR];
  if (typeof ctorRaw !== "string") {
    throw new RawValueDecodeError(
      `valueFromRaw: $constructor must be a string, got ${typeof ctorRaw}`,
    );
  }
  assertSafeKeys(obj);
  // Use a null-prototype object so a hostile payload carrying
  // `__proto__` / `constructor` / `prototype` can't reach
  // Object.prototype via the `fields` record.
  const fields: Record<string, Value> = Object.create(null);
  for (const [k, v] of Object.entries(obj)) {
    if (k === CTOR_DISCRIMINATOR) continue;
    fields[k] = valueFromRaw(v);
  }
  return { kind: "tagged", ctorId: ctorRaw as QualifiedName, fields };
}

function decodeRecord(obj: Record<string, unknown>): Value {
  assertSafeKeys(obj);
  const entries: Record<string, Value> = Object.create(null);
  for (const [k, v] of Object.entries(obj)) {
    entries[k] = valueFromRaw(v);
  }
  return { kind: "record", entries };
}
