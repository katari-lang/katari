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

import type { Json, Literal, TypeTag } from "@katari-lang/types";
import type { Value } from "./types.js";

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
  const fields: Record<string, Value> = {};
  for (const [key, child] of Object.entries(json)) {
    fields[key] = jsonToValue(child);
  }
  return { kind: "record", fields };
}

/**
 * Tagged runtime value -> bare wire JSON (façade output boundary). Drops the `private` marker; the
 * caller is responsible for the redaction policy. Blob refs surface as a small descriptor rather than
 * their (potentially large, async-fetched) bytes; a callable value is never run-result data and throws.
 */
export function valueToJson(value: Value): Json {
  switch (value.kind) {
    case "null":
      return null;
    case "boolean":
    case "integer":
    case "number":
    case "string":
      return value.value;
    case "array":
      return value.elements.map(valueToJson);
    case "record": {
      const out: { [key: string]: Json } = {};
      for (const [key, child] of Object.entries(value.fields)) {
        out[key] = valueToJson(child);
      }
      return out;
    }
    case "ref":
      // A file/blob handle: expose the addressable metadata, not the bytes (fetch is a separate, async
      // download path). A semantic string blob would be materialised before reaching here.
      return {
        kind: "ref",
        semanticKind: value.semanticKind,
        blobId: value.blobId,
        size: value.size,
      };
    case "closure":
    case "agent":
      throw new Error(`a ${value.kind} value cannot cross the JSON boundary (it is not data)`);
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
      if (right.kind !== "record") return false;
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

/** The runtime-checkable tag a `T(pattern)` type filter narrows on (mirrors IR `TypeTag`). */
export function valueTag(value: Value): TypeTag {
  switch (value.kind) {
    case "null":
      return "null";
    case "boolean":
      return "boolean";
    case "integer":
      return "integer";
    case "number":
      return "number";
    case "string":
      return "string";
    case "array":
      return "array";
    case "record":
      return "record";
    case "ref":
      return value.semanticKind === "file" ? "file" : "string";
    case "closure":
    case "agent":
      return "agent";
  }
}
