// Value codec + scalar helpers. Three jobs:
//   - lift an IR `Literal` into a runtime `Value` (`literalToValue`);
//   - convert across the HTTP boundary, where the wire speaks bare `Json` and the engine speaks the
//     tagged `Value` model (`jsonToValue` / `valueToJson`);
//   - the value-level operations the engine and pattern matcher need (`valueEquals`, `valueTag`).
//
// A bare JSON number is ambiguous between the runtime's `integer` and `number`; at the untyped wire
// boundary we split on `Number.isInteger`. Inside the engine the distinction is carried explicitly, so
// this heuristic only ever applies to values entering from outside (a run argument, an answered
// escalation), never to values already in flight.

import type { Json, Literal, QualifiedName, TypeTag } from "@katari-lang/types";
import type { BlobId } from "../ids.js";
import type { SemanticKind, Value } from "./types.js";

// The reserved `$`-prefixed discriminator keys the compiler emits in a value's JSON schema (mirrors
// `Katari.Schema`): a `data` value's constructor, a callable reference, a file/blob handle. The engine's
// tagged `Value` keeps these out-of-band; the codec bridges to/from the keyed JSON form at the boundary.
const CONSTRUCTOR_KEY = "$constructor";
const AGENT_KEY = "$agent";
const FILE_KEY = "$ref";
/** The placeholder a private subtree collapses to when emitted under the `redact` policy (a user-facing
 *  boundary). A reserved `$`-prefixed sentinel, like the others, so it never collides with real record data. */
const REDACTED_KEY = "$redacted";

/**
 * How `valueToJson` treats a private (`value.private`) node:
 *   - `redact` (the default) — replace the private subtree with `{ "$redacted": true }`. This is the
 *     fail-closed boundary: a run result, an open escalation's question, anything a user could observe —
 *     a caller that forgets to choose a policy still does not leak a secret.
 *   - `reveal` — emit the real value. An explicit opt-in for the one allowed sink, the FFI sidecar (a secret
 *     API key flows to its external call).
 * Redaction is structural: a private field inside a public record collapses in place, public siblings survive.
 */
export type PrivatePolicy = "reveal" | "redact";

/** Lift an IR literal (the payload of `loadLiteral` / a `PatternLiteral`) into a runtime value. */
export function literalToValue(literal: Literal): Value {
  switch (literal.kind) {
    case "null":
      return { kind: "null" };
    case "boolean":
      return { kind: "boolean", value: literal.value };
    case "integer":
      return { kind: "integer", value: literal.value };
    case "number":
      return { kind: "number", value: literal.value };
    case "string":
      return { kind: "string", value: literal.value };
  }
}

/** Bare wire JSON -> tagged runtime value (façade input boundary). Numbers split on integer-ness. */
export function jsonToValue(json: Json): Value {
  if (json === null) return { kind: "null" };
  switch (typeof json) {
    case "boolean":
      return { kind: "boolean", value: json };
    case "number":
      return Number.isInteger(json)
        ? { kind: "integer", value: json }
        : { kind: "number", value: json };
    case "string":
      return { kind: "string", value: json };
  }
  if (Array.isArray(json)) {
    return { kind: "array", elements: json.map(jsonToValue) };
  }
  // A file handle reconstructs the blob ref it names; a callable cannot be built from JSON (the AI never
  // constructs one). Everything else is an object, tagged (a `data` value) or bare.
  if (FILE_KEY in json) {
    return fileFromJson(json);
  }
  if (AGENT_KEY in json) {
    throw new Error("a callable value cannot be constructed from JSON input");
  }
  const constructorTag = json[CONSTRUCTOR_KEY];
  const fields: Record<string, Value> = {};
  for (const [key, child] of Object.entries(json)) {
    if (key === CONSTRUCTOR_KEY) continue;
    fields[key] = jsonToValue(child);
  }
  return typeof constructorTag === "string"
    ? { kind: "record", fields, ctor: constructorTag as QualifiedName }
    : { kind: "record", fields };
}

/** Reconstruct a blob `ref` from a `{ "$ref": blobId, size, hash, semanticKind?, contentType? }` handle. */
function fileFromJson(json: { [key: string]: Json }): Value {
  const blobId = json[FILE_KEY];
  const size = json.size;
  const hash = json.hash;
  if (typeof blobId !== "string" || typeof size !== "number" || typeof hash !== "string") {
    throw new Error("a file handle must carry a string $ref, a numeric size, and a string hash");
  }
  const semanticKind: SemanticKind = json.semanticKind === "string" ? "string" : "file";
  const ref: Value = { kind: "ref", semanticKind, blobId: blobId as BlobId, hash, size };
  return typeof json.contentType === "string" ? { ...ref, contentType: json.contentType } : ref;
}

/**
 * Tagged runtime value -> bare wire JSON (façade output boundary). The `policy` decides what happens at a
 * private node: `redact` (the default, fail-closed) collapses the private subtree to `{ "$redacted": true }`
 * for any user-facing boundary, while `reveal` emits the real value — an explicit opt-in for the FFI sidecar,
 * the one allowed sink. The marker itself is not part of the wire shape either way. Blob refs surface as a
 * small descriptor rather than their (potentially large, async-fetched) bytes; a callable value is never
 * run-result data and throws.
 */
export function valueToJson(value: Value, policy: PrivatePolicy = "redact"): Json {
  if (policy === "redact" && value.private === true) {
    return { [REDACTED_KEY]: true };
  }
  switch (value.kind) {
    case "null":
      return null;
    case "boolean":
    case "integer":
    case "number":
    case "string":
      return value.value;
    case "array":
      return value.elements.map((element) => valueToJson(element, policy));
    case "record": {
      const out: { [key: string]: Json } = {};
      // A tagged `data` value re-acquires its `$constructor` discriminator; a bare record has none.
      if (value.ctor !== undefined) {
        out[CONSTRUCTOR_KEY] = value.ctor;
      }
      for (const [key, child] of Object.entries(value.fields)) {
        out[key] = valueToJson(child, policy);
      }
      return out;
    }
    case "ref":
      // A file/blob handle: expose the addressable metadata, not the bytes (fetch is a separate, async
      // download path). A semantic string blob would be materialised before reaching here.
      return {
        [FILE_KEY]: value.blobId,
        semanticKind: value.semanticKind,
        size: value.size,
        hash: value.hash,
      };
    case "closure":
      // A closure's captured scope id is meaningless outside the engine — it cannot leave as JSON data.
      throw new Error(
        "a closure value cannot cross the JSON boundary (it captures engine-local scope)",
      );
    case "agent":
      return { [AGENT_KEY]: value.name };
  }
}

/**
 * Structural equality for `==` and `PatternLiteral` matching. Scalars compare by value; a string
 * compares by content whether inline or a blob ref (refs carry a content `hash`, and an inline string
 * against a ref hashes — deferred: for now an inline/ref string mismatch in representation compares
 * unequal, which the >4KB promotion boundary makes rare). Records compare key-wise, arrays positionally.
 */
export function valueEquals(left: Value, right: Value): boolean {
  switch (left.kind) {
    case "null":
      return right.kind === "null";
    case "boolean":
      return right.kind === "boolean" && left.value === right.value;
    case "integer":
      return right.kind === "integer" && left.value === right.value;
    case "number":
      return right.kind === "number" && left.value === right.value;
    case "string":
      return right.kind === "string" && left.value === right.value;
    case "ref":
      return (
        right.kind === "ref" && left.semanticKind === right.semanticKind && left.hash === right.hash
      );
    case "array": {
      if (right.kind !== "array" || left.elements.length !== right.elements.length) return false;
      for (let index = 0; index < left.elements.length; index += 1) {
        const leftElement = left.elements[index];
        const rightElement = right.elements[index];
        if (leftElement === undefined || rightElement === undefined) return false;
        if (!valueEquals(leftElement, rightElement)) return false;
      }
      return true;
    }
    case "record": {
      if (right.kind !== "record" || left.ctor !== right.ctor) return false;
      const leftEntries = Object.entries(left.fields);
      if (leftEntries.length !== Object.keys(right.fields).length) return false;
      for (const [key, leftValue] of leftEntries) {
        const rightValue = right.fields[key];
        if (rightValue === undefined || !valueEquals(leftValue, rightValue)) return false;
      }
      return true;
    }
    // Callable identity is not value-comparable; two callables are equal only as the same reference.
    case "closure":
      return right.kind === "closure" && left === right;
    case "agent":
      return right.kind === "agent" && left === right;
  }
}

/**
 * Whether a value satisfies a `T(pattern)` type-filter tag (mirrors IR `TypeTag`). Subtyping is folded
 * in: `number` accepts an `integer`; `string` accepts both an inline string and a semantic-string blob;
 * `agent` accepts a closure or an agent reference.
 */
export function valueMatchesTag(value: Value, tag: TypeTag): boolean {
  switch (tag) {
    case "null":
      return value.kind === "null";
    case "boolean":
      return value.kind === "boolean";
    case "integer":
      return value.kind === "integer";
    case "number":
      return value.kind === "number" || value.kind === "integer";
    case "string":
      return value.kind === "string" || (value.kind === "ref" && value.semanticKind === "string");
    case "file":
      return value.kind === "ref" && value.semanticKind === "file";
    case "array":
      return value.kind === "array";
    case "record":
      return value.kind === "record";
    case "agent":
      return value.kind === "closure" || value.kind === "agent";
  }
}
