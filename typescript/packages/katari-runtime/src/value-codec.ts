// Bidirectional codec between the runtime `Value` tagged union and a
// schema-less raw JSON form. Decoding routes plain objects by
// discriminator priority:
//
//   1. `{$constructor: "...", ...fieldsRaw}`  → tagged value
//   2. `{$agent: "module.name" | "closure:N"}` → callable
//   3. `{$ref: {module, id}, as, hash, size}`  → value reference (string/file)
//   4. `{$secret: "..."}` (inbound)            → refused (one-way out)
//   5. plain object (none of the above)        → record
//
// Byte sequences (`string` / `file` / `secret`) carry a `rep` (inline text
// or a content-addressed ref). v0.1.0 produces only the inline rep at the
// codec level; `valueToRaw` is **as-is** (it does NOT promote inline → ref —
// promotion happens at the persist boundary, not the wire). A ref value
// serialises to the `$ref` envelope and the consumer fetches the bytes via
// the data plane (see docs/2026-05-30-value-and-streaming.md §11).
//
// Round-trip guarantee is *one-way*: `valueFromRaw(valueToRaw(v))` recovers
// every Value variant except records whose keys coincide with a reserved
// discriminator.
//
// Primitives ←→ themselves; arrays ←→ arrays (tuples share this form).

import type { ClosureId } from "./engine/id.js";
import { mkString, type RefModule, type RefRep, type Value } from "./engine/value.js";
import type { QualifiedName } from "./ir/types.js";

// Re-export the canonical RawValue type from @katari-lang/types.
export type { RawValue } from "@katari-lang/types";

import type { RawValue } from "@katari-lang/types";

/** Discriminator key for the constructor identity of a tagged value. */
export const CTOR_DISCRIMINATOR = "$constructor";

/** Discriminator key for a callable reference. */
export const CALLABLE_DISCRIMINATOR = "$agent";

/** Discriminator key for a value reference (string / file blob). */
export const REF_DISCRIMINATOR = "$ref";

/** Discriminator key for an opaque secret string (sidecar wire form, plaintext). */
export const SECRET_DISCRIMINATOR = "$secret";

const REF_MODULES: ReadonlySet<string> = new Set(["core", "ffi", "api"]);

/**
 * Encode a runtime 'Value' to its raw JSON form. As-is: byte-sequence
 * values are serialised in their current rep (inline → bare text, ref →
 * `$ref` envelope). No inline → ref promotion (that is a persist-boundary
 * concern, not the wire).
 */
export function valueToRaw(value: Value): RawValue {
  switch (value.kind) {
    case "number":
      if (!Number.isFinite(value.value)) {
        throw new RawValueDecodeError(
          `valueToRaw: non-finite number ${value.value} cannot be serialized`,
        );
      }
      return value.value;
    case "boolean":
      return value.value;
    case "null":
      return null;
    case "string":
      return value.rep.kind === "inline" ? value.rep.text : refToRaw(value.rep, "string");
    case "file":
      // file is always a ref by design.
      return refToRaw(value.rep, "file");
    case "secret":
      // Outbound to sidecar: emit the plaintext under '$secret'. v0.1.0
      // secrets are inline-only; a ref secret is not produced yet.
      if (value.rep.kind !== "inline") {
        throw new RawValueDecodeError("valueToRaw: secret ref not supported in v0.1.0");
      }
      return { [SECRET_DISCRIMINATOR]: value.rep.text };
    case "array":
      return value.elements.map(valueToRaw);
    case "tagged": {
      const out: Record<string, RawValue> = { [CTOR_DISCRIMINATOR]: value.ctorId };
      for (const [k, v] of Object.entries(value.fields)) out[k] = valueToRaw(v);
      return out;
    }
    case "record": {
      const out: Record<string, RawValue> = {};
      for (const [k, v] of Object.entries(value.entries)) out[k] = valueToRaw(v);
      return out;
    }
    case "closure":
      // Content-ref form (#5): a closure that has crossed (or is crossing) a
      // shard boundary is a content-addressed ref to its serialized
      // {blockId, snapshot, env} blob — the canonical wire form (clean bus:
      // just a hash). The local-id form is in-shard only and is serialized to
      // a ref before the true bus boundary; the `$agent: closure:N` encoding
      // is kept for in-process round-trips / tests.
      if ("ref" in value) return refToRaw(value.ref, "closure");
      return { [CALLABLE_DISCRIMINATOR]: `closure:${value.closureId}` };
    case "agentLiteral":
      return { [CALLABLE_DISCRIMINATOR]: value.qualifiedName };
  }
}

/** Build the `$ref` envelope for a ref rep. `as` distinguishes how the
 *  consumer interprets the blob: a byte sequence (`string` / `file`) or a
 *  serialized closure (`closure`, #5). The store + handle are identical. */
function refToRaw(rep: RefRep, as: "string" | "file" | "closure"): RawValue {
  const out: Record<string, RawValue> = {
    [REF_DISCRIMINATOR]: { module: rep.module, id: rep.id },
    as,
    hash: rep.hash,
    size: rep.size,
  };
  if (rep.contentType !== undefined) out.contentType = rep.contentType;
  return out;
}

/**
 * Decode a raw JSON value into a runtime 'Value'. Schema-less: routes plain
 * objects by discriminator priority. Throws 'RawValueDecodeError' on
 * un-mappable input.
 */
export function valueFromRaw(raw: unknown): Value {
  if (raw === null) return { kind: "null" };
  switch (typeof raw) {
    case "number":
      if (!Number.isFinite(raw)) {
        throw new RawValueDecodeError(`valueFromRaw: non-finite number ${raw}`);
      }
      return { kind: "number", value: raw };
    case "string":
      return mkString(raw);
    case "boolean":
      return { kind: "boolean", value: raw };
    case "object":
      break;
    default:
      throw new RawValueDecodeError(`valueFromRaw: cannot decode '${typeof raw}' value`);
  }
  if (Array.isArray(raw)) {
    return { kind: "array", elements: raw.map(valueFromRaw) };
  }
  const obj = raw as Record<string, unknown>;
  if (CTOR_DISCRIMINATOR in obj) return decodeTagged(obj);
  if (CALLABLE_DISCRIMINATOR in obj) return decodeCallable(obj[CALLABLE_DISCRIMINATOR]);
  if (REF_DISCRIMINATOR in obj) return decodeRef(obj);
  if (SECRET_DISCRIMINATOR in obj) {
    // Sidecar IPC trust direction is one-way: secrets flow OUT but MUST
    // NOT flow back. Storage decryption uses a separate walker.
    throw new RawValueDecodeError(
      `valueFromRaw: refusing to decode '${SECRET_DISCRIMINATOR}' — secrets must not cross the sidecar→runtime boundary`,
    );
  }
  return decodeRecord(obj);
}

/** Decoding error surfaced from the codec for un-mappable inputs. */
export class RawValueDecodeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RawValueDecodeError";
  }
}

function decodeCallable(rawId: unknown): Value {
  if (typeof rawId !== "string") {
    throw new RawValueDecodeError(`valueFromRaw: $agent must be a string, got ${typeof rawId}`);
  }
  if (rawId.startsWith("closure:")) {
    const n = Number(rawId.slice("closure:".length));
    if (!Number.isInteger(n) || n < 0) {
      throw new RawValueDecodeError(`valueFromRaw: malformed closure callable '${rawId}'`);
    }
    return { kind: "closure", closureId: n as ClosureId };
  }
  return { kind: "agentLiteral", qualifiedName: rawId as QualifiedName };
}

function decodeRef(obj: Record<string, unknown>): Value {
  const ref = obj[REF_DISCRIMINATOR];
  if (typeof ref !== "object" || ref === null) {
    throw new RawValueDecodeError("valueFromRaw: $ref must be an object {module, id}");
  }
  const { module, id } = ref as Record<string, unknown>;
  if (typeof module !== "string" || !REF_MODULES.has(module)) {
    throw new RawValueDecodeError(`valueFromRaw: $ref.module invalid: ${String(module)}`);
  }
  if (typeof id !== "string") {
    throw new RawValueDecodeError("valueFromRaw: $ref.id must be a string");
  }
  const as = obj.as;
  if (as !== "string" && as !== "file" && as !== "closure") {
    throw new RawValueDecodeError(
      `valueFromRaw: $ref.as must be 'string'|'file'|'closure', got ${String(as)}`,
    );
  }
  const hash = obj.hash;
  const size = obj.size;
  if (typeof hash !== "string") {
    throw new RawValueDecodeError("valueFromRaw: $ref.hash must be a string");
  }
  if (typeof size !== "number" || !Number.isFinite(size)) {
    throw new RawValueDecodeError("valueFromRaw: $ref.size must be a number");
  }
  const rep: RefRep = {
    kind: "ref",
    module: module as RefModule,
    id,
    hash,
    size,
  };
  if (typeof obj.contentType === "string") rep.contentType = obj.contentType;
  if (as === "closure") return { kind: "closure", ref: rep };
  return as === "string" ? { kind: "string", rep } : { kind: "file", rep };
}

/** Reject `__proto__` / `constructor` / `prototype` keys. */
function assertSafeKeys(obj: Record<string, unknown>): void {
  for (const k of Object.keys(obj)) {
    if (k === "__proto__" || k === "constructor" || k === "prototype") {
      throw new RawValueDecodeError(`valueFromRaw: forbidden key '${k}'`);
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
