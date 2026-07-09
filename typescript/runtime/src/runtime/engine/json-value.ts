// The `json` data type's runtime bridge. `prelude.json` models a JSON document as tagged `data` values
// (`json_object` / `json_array` / ... — see `stdlib/prelude/json.ktr`); this module converts between three
// shapes:
//
//   - `jsonValueFromJson`:  bare `Json`  ->  tagged `json` tree     (`parse`, and embedding a schema)
//   - `jsonValueToJson`:    tagged `json` tree  ->  bare `Json`     (`stringify`)
//   - `encodeValue`:        any runtime `Value`  ->  tagged `json` tree   (`json.encode`)
//   - `treeToValue`:        tagged `json` tree  ->  any runtime `Value`   (`json.decode`)
//
// `parse` / `stringify` treat a `json` tree as a *literal* JSON document: every object key is kept as
// written (`$constructor` is just a key, no interpretation). `encode` / `decode` instead apply the value
// wire conventions (`value/codec.ts`) — a `data` value nests under `value`, an agent/closure/file becomes
// its reference object, a record escapes `$`-keys — so `decode(encode(x)) == x` for every `x`, including a
// `json` value itself (which is an ordinary `data` value here, no special case). integer vs number is
// preserved (the tree distinguishes `json_integer` / `json_number`, which bare JSON cannot).
//
// A blob-backed string is materialised to text by `encode` (a JSON document's string is text); `decode`
// keeps a string leaf as-is (inline or ref — both are strings). Privacy: these walks keep private subtree
// content (nothing here crosses a user boundary — the result is an ordinary in-engine value), and the
// primitive layer's monotonic taint rule marks the whole result private whenever any input part is.

import { createAgentName, type Json } from "@katari-lang/types";
import { type BlobId, toScopeId, toSnapshotId } from "../ids.js";
import {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  CONTENT_TYPE_KEY,
  CONTEXT_KEY,
  DESCRIPTION_KEY,
  escapeRecordKey,
  FILE_KEY,
  GENERICS_KEY,
  genericsFromJson,
  genericsToJson,
  HASH_KEY,
  INPUT_SCHEMA_KEY,
  MODULE_KEY,
  OUTPUT_SCHEMA_KEY,
  REACTOR_KEY,
  SCOPE_KEY,
  SEMANTIC_KIND_KEY,
  SIZE_KEY,
  SNAPSHOT_KEY,
  TOOL_KEY,
  unescapeRecordKey,
  VALUE_KEY,
  wireKindOf,
} from "../value/codec.js";
import { jsonToSchema, schemaToJson } from "../value/schema-json.js";
import type { AgentValue, ClosureValue, SemanticKind, Value } from "../value/types.js";

export const JSON_NULL = "prelude.json.json_null";
export const JSON_BOOLEAN = "prelude.json.json_boolean";
export const JSON_INTEGER = "prelude.json.json_integer";
export const JSON_NUMBER = "prelude.json.json_number";
export const JSON_STRING = "prelude.json.json_string";
export const JSON_ARRAY = "prelude.json.json_array";
export const JSON_OBJECT = "prelude.json.json_object";

/** Reads a string value's content: inline directly, a semantic-string blob through the store. */
export type StringReader = (value: Value) => Promise<string>;

// ─── `json` tree constructors ─────────────────────────────────────────────────────────────────────

function tagged(ctor: string, fields: Record<string, Value>): Value {
  return { kind: "record", fields, ctor: createAgentName(ctor) };
}
const jsonNull = (): Value => tagged(JSON_NULL, {});
const jsonBoolean = (value: boolean): Value =>
  tagged(JSON_BOOLEAN, { value: { kind: "boolean", value } });
const jsonInteger = (value: number): Value =>
  tagged(JSON_INTEGER, { value: { kind: "integer", value } });
const jsonNumber = (value: number): Value =>
  tagged(JSON_NUMBER, { value: { kind: "number", value } });
const jsonStringOf = (value: Value): Value => tagged(JSON_STRING, { value });
const jsonText = (value: string): Value => jsonStringOf({ kind: "string", value });
const jsonArray = (elements: Value[]): Value =>
  tagged(JSON_ARRAY, { items: { kind: "array", elements } });

/** A `json_object` from a prototype-less entries map (so a `__proto__` / `$`-key is an ordinary field). */
function jsonObject(entries: Record<string, Value>): Value {
  return tagged(JSON_OBJECT, { entries: { kind: "record", fields: entries } });
}

function requireFinite(value: number): number {
  if (!Number.isFinite(value)) {
    throw new Error("a non-finite number (NaN / Infinity) has no JSON representation");
  }
  return value;
}

// ─── bare Json -> `json` tree (`parse`) ────────────────────────────────────────────────────────────

/** Lift bare JSON into the *literal* tagged `json` tree (no key interpretation). A fraction-less number
 *  becomes `json_integer` (JSON has one number type; the boundary splits on integer-ness). */
export function jsonValueFromJson(json: Json): Value {
  if (json === null) return jsonNull();
  switch (typeof json) {
    case "boolean":
      return jsonBoolean(json);
    case "number":
      return Number.isInteger(json) ? jsonInteger(json) : jsonNumber(json);
    case "string":
      return jsonText(json);
  }
  if (Array.isArray(json)) return jsonArray(json.map(jsonValueFromJson));
  const entries: Record<string, Value> = Object.create(null);
  for (const [key, child] of Object.entries(json)) {
    entries[key] = jsonValueFromJson(child);
  }
  return jsonObject(entries);
}

// ─── `json` tree -> bare Json (`stringify`) ─────────────────────────────────────────────────────────

/** Flatten a *literal* `json` tree back to bare JSON (keys unchanged). A non-`json` value is a type error
 *  upstream (the checker guarantees the argument), so it throws — which the prim layer turns into a panic. */
export async function jsonValueToJson(value: Value, readString: StringReader): Promise<Json> {
  if (value.kind !== "record" || value.ctor === undefined) {
    throw new Error(`expected a json value, got ${value.kind}`);
  }
  const fields = value.fields;
  switch (String(value.ctor)) {
    case JSON_NULL:
      return null;
    case JSON_BOOLEAN:
      return scalarField(fields, "boolean");
    case JSON_INTEGER:
      return scalarField(fields, "integer");
    case JSON_NUMBER: {
      const inner = fields.value;
      // An integer is a number by subtyping, so `json_number(value = 1)` is legitimate.
      if (inner === undefined || (inner.kind !== "number" && inner.kind !== "integer")) {
        throw new Error("json_number carries no number value");
      }
      return requireFinite(inner.value);
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
      const out: { [key: string]: Json } = Object.create(null);
      for (const [key, child] of Object.entries(entries.fields)) {
        out[key] = await jsonValueToJson(child, readString);
      }
      return out;
    }
    default:
      throw new Error(`expected a json value, got a "${value.ctor}" value`);
  }
}

function scalarField(fields: Record<string, Value>, kind: "boolean" | "integer"): Json {
  const inner = fields.value;
  if (inner === undefined || inner.kind !== kind) {
    throw new Error(`json_${kind} carries no ${kind} value`);
  }
  return inner.value;
}

// ─── Value -> `json` tree (`json.encode`) ───────────────────────────────────────────────────────────

/**
 * Embed any runtime value into the tagged `json` tree by the value wire conventions (`value/codec.ts`): a
 * `data` value nests its fields under `value`, a record escapes `$`-keys, an agent / closure / file
 * becomes its reference object, a blob-backed string is materialised to text. A closure's captured scope
 * ids ride along so it reconstructs. `decode` (`treeToValue`) inverts this.
 */
export async function encodeValue(value: Value, readString: StringReader): Promise<Value> {
  switch (value.kind) {
    case "null":
      return jsonNull();
    case "boolean":
      return jsonBoolean(value.value);
    case "integer":
      return jsonInteger(value.value);
    case "number":
      return jsonNumber(requireFinite(value.value));
    case "string":
      return jsonText(value.value);
    case "ref": {
      if (value.semanticKind === "string") return jsonText(await readString(value));
      const entries: Record<string, Value> = Object.create(null);
      entries[FILE_KEY] = jsonText(value.blobId);
      entries[SEMANTIC_KIND_KEY] = jsonText(value.semanticKind);
      entries[SIZE_KEY] = jsonInteger(value.size);
      entries[HASH_KEY] = jsonText(value.hash);
      if (value.contentType !== undefined) entries[CONTENT_TYPE_KEY] = jsonText(value.contentType);
      return jsonObject(entries);
    }
    case "agent": {
      const entries: Record<string, Value> = Object.create(null);
      entries[AGENT_KEY] = jsonText(String(value.name));
      entries[SNAPSHOT_KEY] = jsonText(String(value.snapshot));
      if (value.generics !== undefined) {
        entries[GENERICS_KEY] = jsonValueFromJson(genericsToJson(value.generics));
      }
      return jsonObject(entries);
    }
    case "closure": {
      const entries: Record<string, Value> = Object.create(null);
      entries[CLOSURE_KEY] = jsonInteger(value.blockId);
      entries[SCOPE_KEY] = jsonInteger(value.scopeId);
      entries[SNAPSHOT_KEY] = jsonText(String(value.snapshot));
      entries[MODULE_KEY] = jsonText(value.module);
      if (value.generics !== undefined) {
        entries[GENERICS_KEY] = jsonValueFromJson(genericsToJson(value.generics));
      }
      return jsonObject(entries);
    }
    case "tool": {
      const entries: Record<string, Value> = Object.create(null);
      entries[TOOL_KEY] = jsonText(value.name);
      entries[REACTOR_KEY] = jsonText(value.reactor);
      entries[CONTEXT_KEY] = await encodeValue(value.context, readString);
      entries[SNAPSHOT_KEY] = jsonText(String(value.snapshot));
      entries[DESCRIPTION_KEY] = jsonText(value.description);
      entries[INPUT_SCHEMA_KEY] = jsonValueFromJson(schemaToJson(value.inputSchema));
      if (value.outputSchema !== undefined) {
        entries[OUTPUT_SCHEMA_KEY] = jsonValueFromJson(schemaToJson(value.outputSchema));
      }
      return jsonObject(entries);
    }
    case "array": {
      const elements: Value[] = [];
      for (const element of value.elements) {
        elements.push(await encodeValue(element, readString));
      }
      return jsonArray(elements);
    }
    case "record": {
      const entries: Record<string, Value> = Object.create(null);
      for (const [key, child] of Object.entries(value.fields)) {
        entries[escapeRecordKey(key)] = await encodeValue(child, readString);
      }
      if (value.ctor === undefined) return jsonObject(entries);
      const wrapper: Record<string, Value> = Object.create(null);
      wrapper[CONSTRUCTOR_KEY] = jsonText(String(value.ctor));
      wrapper[VALUE_KEY] = jsonObject(entries);
      return jsonObject(wrapper);
    }
  }
}

// ─── `json` tree -> Value (`json.decode`) ───────────────────────────────────────────────────────────

/**
 * Reconstruct a runtime value from its tagged `json` tree by the inverse wire conventions — the total
 * inverse of `encodeValue`. Scalars keep their `json_integer` / `json_number` tag; an object dispatches
 * on its reserved discriminator key. `readString` is needed only to flatten an embedded `generics`
 * subtree (which never holds a blob), so a string leaf is otherwise kept as-is.
 */
export async function treeToValue(value: Value, readString: StringReader): Promise<Value> {
  if (value.kind !== "record" || value.ctor === undefined) {
    throw new Error(`expected a json value, got ${value.kind}`);
  }
  const fields = value.fields;
  switch (String(value.ctor)) {
    case JSON_NULL:
      return { kind: "null" };
    case JSON_BOOLEAN:
      return leafScalar(fields, "boolean");
    case JSON_INTEGER:
      return leafScalar(fields, "integer");
    case JSON_NUMBER: {
      const inner = fields.value;
      if (inner === undefined || (inner.kind !== "number" && inner.kind !== "integer")) {
        throw new Error("json_number carries no number value");
      }
      return { kind: "number", value: inner.value };
    }
    case JSON_STRING: {
      const inner = fields.value;
      // A string leaf is already a string value (inline or blob ref); keep it as-is (no materialisation).
      if (inner === undefined || (inner.kind !== "string" && inner.kind !== "ref")) {
        throw new Error("json_string carries no string value");
      }
      return inner;
    }
    case JSON_ARRAY: {
      const items = fields.items;
      if (items === undefined || items.kind !== "array") {
        throw new Error("json_array carries no items array");
      }
      const elements: Value[] = [];
      for (const item of items.elements) {
        elements.push(await treeToValue(item, readString));
      }
      return { kind: "array", elements };
    }
    case JSON_OBJECT:
      return objectTreeToValue(objectEntries(fields), readString);
    default:
      throw new Error(`expected a json value, got a "${value.ctor}" value`);
  }
}

function leafScalar(fields: Record<string, Value>, kind: "boolean" | "integer"): Value {
  const inner = fields.value;
  if (inner === undefined || inner.kind !== kind) {
    throw new Error(`json_${kind} carries no ${kind} value`);
  }
  return inner;
}

/** The entries record of a `json_object` tree node. */
function objectEntries(fields: Record<string, Value>): Record<string, Value> {
  const entries = fields.entries;
  if (entries === undefined || entries.kind !== "record") {
    throw new Error("json_object carries no entries record");
  }
  return entries.fields;
}

/** Dispatch a `json_object`'s entries on its reserved discriminator key (mirrors `codec.jsonToValue`). */
async function objectTreeToValue(
  entries: Record<string, Value>,
  readString: StringReader,
): Promise<Value> {
  switch (wireKindOf((key) => Object.hasOwn(entries, key))) {
    case "data": {
      const ctor = leafText(entries[CONSTRUCTOR_KEY]);
      const valueNode = entries[VALUE_KEY];
      const inner = valueNode !== undefined ? entriesOfNode(valueNode) : Object.create(null);
      return {
        kind: "record",
        ctor: createAgentName(ctor),
        fields: await recordFrom(inner, readString),
      };
    }
    case "file":
      return fileFromTree(entries);
    case "agent":
      return agentFromTree(entries, readString);
    case "closure":
      return closureFromTree(entries, readString);
    case "tool":
      return toolFromTree(entries, readString);
    case "redacted":
      throw new Error(
        "a redacted value cannot be decoded (its content was withheld at a boundary)",
      );
    case undefined:
      return { kind: "record", fields: await recordFrom(entries, readString) };
  }
}

/** The inner entries map of a `json_object` tree value (a `data` value's `value` wrapper). */
function entriesOfNode(node: Value): Record<string, Value> {
  if (node.kind !== "record" || node.ctor === undefined || String(node.ctor) !== JSON_OBJECT) {
    throw new Error("a data value's `value` must be a json object");
  }
  return objectEntries(node.fields);
}

/** Decode a `json_object`'s entries into record fields, unescaping keys, into a prototype-less map. */
async function recordFrom(
  entries: Record<string, Value>,
  readString: StringReader,
): Promise<Record<string, Value>> {
  const fields: Record<string, Value> = Object.create(null);
  for (const [key, child] of Object.entries(entries)) {
    fields[unescapeRecordKey(key)] = await treeToValue(child, readString);
  }
  return fields;
}

function fileFromTree(entries: Record<string, Value>): Value {
  // A partial handle (an AI replaying just the `$ref`) is the common failure here — name the full
  // shape, so the message fed back to the model as a tool error is itself the correction.
  if (entries[SIZE_KEY] === undefined || entries[HASH_KEY] === undefined) {
    throw new Error(
      'an incomplete file handle: replay the FULL handle object exactly as it appears, e.g. {"$ref": "...", "semanticKind": "file", "size": ..., "hash": "..."}',
    );
  }
  const blobId = leafText(entries[FILE_KEY]);
  const size = leafNumber(entries[SIZE_KEY]);
  const hash = leafText(entries[HASH_KEY]);
  const semanticKind: SemanticKind =
    leafTextMaybe(entries[SEMANTIC_KIND_KEY]) === "string" ? "string" : "file";
  const contentType = leafTextMaybe(entries[CONTENT_TYPE_KEY]);
  const ref: Value = { kind: "ref", semanticKind, blobId: blobId as BlobId, hash, size };
  return contentType !== undefined ? { ...ref, contentType } : ref;
}

async function agentFromTree(
  entries: Record<string, Value>,
  readString: StringReader,
): Promise<Value> {
  const agent: AgentValue = {
    kind: "agent",
    name: createAgentName(leafText(entries[AGENT_KEY])),
    snapshot: toSnapshotId(leafText(entries[SNAPSHOT_KEY])),
  };
  const generics = entries[GENERICS_KEY];
  if (generics === undefined) return agent;
  return { ...agent, generics: genericsFromJson(await jsonValueToJson(generics, readString)) };
}

async function closureFromTree(
  entries: Record<string, Value>,
  readString: StringReader,
): Promise<Value> {
  const closure: ClosureValue = {
    kind: "closure",
    blockId: leafNumber(entries[CLOSURE_KEY]),
    scopeId: toScopeId(leafNumber(entries[SCOPE_KEY])),
    snapshot: toSnapshotId(leafText(entries[SNAPSHOT_KEY])),
    module: leafText(entries[MODULE_KEY]),
  };
  const generics = entries[GENERICS_KEY];
  if (generics === undefined) return closure;
  return { ...closure, generics: genericsFromJson(await jsonValueToJson(generics, readString)) };
}

async function toolFromTree(
  entries: Record<string, Value>,
  readString: StringReader,
): Promise<Value> {
  const contextNode = entries[CONTEXT_KEY];
  if (contextNode === undefined) throw new Error("a tool carries no context");
  const inputSchemaNode = entries[INPUT_SCHEMA_KEY];
  const outputSchemaNode = entries[OUTPUT_SCHEMA_KEY];
  const tool: Value = {
    kind: "tool",
    reactor: leafText(entries[REACTOR_KEY]),
    name: leafText(entries[TOOL_KEY]),
    description: leafText(entries[DESCRIPTION_KEY]),
    context: await treeToValue(contextNode, readString),
    snapshot: toSnapshotId(leafText(entries[SNAPSHOT_KEY])),
    inputSchema:
      inputSchemaNode === undefined
        ? {}
        : jsonToSchema(await jsonValueToJson(inputSchemaNode, readString)),
  };
  if (outputSchemaNode === undefined) return tool;
  return {
    ...tool,
    outputSchema: jsonToSchema(await jsonValueToJson(outputSchemaNode, readString)),
  };
}

// ─── leaf extractors (a `json_string` / `json_integer` tree node -> its scalar) ─────────────────────

function leafText(value: Value | undefined): string {
  const text = leafTextMaybe(value);
  if (text === undefined) throw new Error("expected a string leaf");
  return text;
}

function leafTextMaybe(value: Value | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (value.kind === "record" && value.ctor !== undefined && String(value.ctor) === JSON_STRING) {
    return leafTextMaybe(value.fields.value);
  }
  return value.kind === "string" ? value.value : undefined;
}

function leafNumber(value: Value | undefined): number {
  if (value !== undefined && value.kind === "record" && value.ctor !== undefined) {
    const ctor = String(value.ctor);
    if (ctor === JSON_INTEGER || ctor === JSON_NUMBER) return leafNumber(value.fields.value);
  }
  if (value === undefined || (value.kind !== "integer" && value.kind !== "number")) {
    throw new Error("expected a number leaf");
  }
  return value.value;
}
