// The `json` data type's runtime bridge. `prelude.json` models a JSON document as tagged `data`
// values (`json_object` / `json_array` / ... — see `stdlib/prelude/json.ktr`); this module converts
// between three shapes:
//
//   - `jsonValueFromJson`:  bare `Json`  ->  tagged `json` value   (parse / schema embedding)
//   - `jsonValueToJson`:    tagged `json` value  ->  bare `Json`   (stringify / decode)
//   - `encodeValue`:        any runtime `Value`  ->  tagged `json` value   (`json.encode`)
//
// `encodeValue` composes with `jsonValueFromJson` over the value codec's wire conventions: a `data`
// value keeps its `$constructor` as an entry, a file ref becomes its `$ref` handle object, an agent
// its `$agent` reference object — so `json.decode` (which is `jsonValueToJson` piped through
// `jsonToValue`) inverts it. A value that is ALREADY a `json` data value passes through unchanged,
// which is what lets `json.encode({ name = ..., input_schema = m.input })` mix plain fields with
// schema values from `get_metadata` without double-tagging.
//
// Privacy: these walks keep private subtree *content* (nothing here crosses a user boundary — the
// result is an ordinary in-engine value), and the primitive layer's monotonic taint rule marks the
// whole result private whenever any input part is. Blob-backed strings are materialised through the
// caller-supplied reader (the prims hand in a `BlobStore`-bound one).

import { createAgentName, type Json } from "@katari-lang/types";
import { jsonToValue } from "../value/codec.js";
import type { Value } from "../value/types.js";

export const JSON_NULL = "prelude.json.json_null";
export const JSON_BOOLEAN = "prelude.json.json_boolean";
export const JSON_INTEGER = "prelude.json.json_integer";
export const JSON_NUMBER = "prelude.json.json_number";
export const JSON_STRING = "prelude.json.json_string";
export const JSON_ARRAY = "prelude.json.json_array";
export const JSON_OBJECT = "prelude.json.json_object";

/** Reads a string value's content: inline directly, a semantic-string blob through the store. */
export type StringReader = (value: Value) => Promise<string>;

function tagged(ctor: string, fields: Record<string, Value>): Value {
  return { kind: "record", fields, ctor: createAgentName(ctor) };
}

/** Whether a value is one of the seven `prelude.json` data values (by its constructor tag). */
export function isJsonValue(value: Value): boolean {
  if (value.kind !== "record" || value.ctor === undefined) return false;
  switch (String(value.ctor)) {
    case JSON_NULL:
    case JSON_BOOLEAN:
    case JSON_INTEGER:
    case JSON_NUMBER:
    case JSON_STRING:
    case JSON_ARRAY:
    case JSON_OBJECT:
      return true;
    default:
      return false;
  }
}

/** Lift bare JSON into the tagged `json` data tree. A fraction-less number becomes `json_integer`
 *  (mirroring the codec's boundary heuristic — JSON itself has one number type). */
export function jsonValueFromJson(json: Json): Value {
  if (json === null) return tagged(JSON_NULL, {});
  switch (typeof json) {
    case "boolean":
      return tagged(JSON_BOOLEAN, { value: { kind: "boolean", value: json } });
    case "number":
      return Number.isInteger(json)
        ? tagged(JSON_INTEGER, { value: { kind: "integer", value: json } })
        : tagged(JSON_NUMBER, { value: { kind: "number", value: json } });
    case "string":
      return tagged(JSON_STRING, { value: { kind: "string", value: json } });
  }
  if (Array.isArray(json)) {
    return tagged(JSON_ARRAY, {
      items: { kind: "array", elements: json.map(jsonValueFromJson) },
    });
  }
  const entries: Record<string, Value> = {};
  for (const [key, child] of Object.entries(json)) {
    entries[key] = jsonValueFromJson(child);
  }
  return tagged(JSON_OBJECT, { entries: { kind: "record", fields: entries } });
}

/** Flatten a tagged `json` data tree back to bare JSON. A non-`json` value is a type error upstream
 *  (the checker guarantees the argument), so it throws — which the prim layer turns into a panic. */
export async function jsonValueToJson(value: Value, readString: StringReader): Promise<Json> {
  if (value.kind !== "record" || value.ctor === undefined) {
    throw new Error(`expected a json value, got ${value.kind}`);
  }
  const fields = value.fields;
  switch (String(value.ctor)) {
    case JSON_NULL:
      return null;
    case JSON_BOOLEAN:
      return scalarField(fields, "value", "boolean");
    case JSON_INTEGER:
      return scalarField(fields, "value", "integer");
    case JSON_NUMBER: {
      const inner = fields.value;
      // An integer is a number by subtyping, so `json_number(value = 1)` is legitimate.
      if (inner === undefined || (inner.kind !== "number" && inner.kind !== "integer")) {
        throw new Error("json_number carries no number value");
      }
      return inner.value;
    }
    case JSON_STRING: {
      const inner = fields.value;
      if (inner === undefined) throw new Error("json_string carries no string value");
      return readString(inner);
    }
    case JSON_ARRAY: {
      const items = fields.items;
      if (items === undefined || items.kind !== "array") {
        throw new Error("json_array carries no items array");
      }
      const out: Json[] = [];
      for (const item of items.elements) {
        out.push(await jsonValueToJson(item, readString));
      }
      return out;
    }
    case JSON_OBJECT: {
      const entries = fields.entries;
      if (entries === undefined || entries.kind !== "record") {
        throw new Error("json_object carries no entries record");
      }
      const out: { [key: string]: Json } = {};
      for (const [key, child] of Object.entries(entries.fields)) {
        out[key] = await jsonValueToJson(child, readString);
      }
      return out;
    }
    default:
      throw new Error(`expected a json value, got a "${value.ctor}" value`);
  }
}

function scalarField(
  fields: Record<string, Value>,
  name: string,
  kind: "boolean" | "integer",
): Json {
  const inner = fields[name];
  if (inner === undefined || inner.kind !== kind) {
    throw new Error(`json_${kind} carries no ${kind} value`);
  }
  return inner.value;
}

/**
 * Embed any runtime value into the tagged `json` tree (`json.encode`). A value that is already
 * `json` passes through unchanged; otherwise the value codec's wire conventions apply — a `data`
 * value keeps its `$constructor` as an entry, a blob-backed string is materialised, a file ref
 * becomes its `$ref` handle object, an agent value its `$agent` reference object. A closure captures
 * engine-local scope and cannot be encoded.
 */
export async function encodeValue(value: Value, readString: StringReader): Promise<Value> {
  if (isJsonValue(value)) return value;
  switch (value.kind) {
    case "null":
      return tagged(JSON_NULL, {});
    case "boolean":
      return tagged(JSON_BOOLEAN, { value: { kind: "boolean", value: value.value } });
    case "integer":
      return tagged(JSON_INTEGER, { value: { kind: "integer", value: value.value } });
    case "number":
      return tagged(JSON_NUMBER, { value: { kind: "number", value: value.value } });
    case "string":
      return tagged(JSON_STRING, { value: { kind: "string", value: value.value } });
    case "ref": {
      if (value.semanticKind === "string") {
        return tagged(JSON_STRING, { value: { kind: "string", value: await readString(value) } });
      }
      // A file handle encodes as its `$ref` descriptor object (the wire shape `valueToJson` emits),
      // so `json.decode` reconstructs the same handle.
      return jsonValueFromJson({
        $ref: value.blobId,
        semanticKind: value.semanticKind,
        size: value.size,
        hash: value.hash,
      });
    }
    case "agent":
      return jsonValueFromJson({ $agent: String(value.name) });
    case "closure":
      throw new Error("json.encode: a closure value cannot cross the JSON boundary");
    case "array": {
      const elements: Value[] = [];
      for (const element of value.elements) {
        elements.push(await encodeValue(element, readString));
      }
      return tagged(JSON_ARRAY, { items: { kind: "array", elements } });
    }
    case "record": {
      const entries: Record<string, Value> = {};
      if (value.ctor !== undefined) {
        entries.$constructor = tagged(JSON_STRING, {
          value: { kind: "string", value: String(value.ctor) },
        });
      }
      for (const [key, child] of Object.entries(value.fields)) {
        entries[key] = await encodeValue(child, readString);
      }
      return tagged(JSON_OBJECT, { entries: { kind: "record", fields: entries } });
    }
  }
}

/** Read a `json` value back into a plain value (`json.decode`): flatten to bare JSON, then lift
 *  through the standard codec — so `$constructor` entries re-tag data values, `$ref` handles
 *  reconstruct blob refs, and a `$agent` reference throws (a callable cannot be built from JSON). */
export async function decodeValue(value: Value, readString: StringReader): Promise<Value> {
  return jsonToValue(await jsonValueToJson(value, readString));
}
