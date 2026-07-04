// The `JSONSchema` ↔ bare `Json` bijection, in one place. `JSONSchema` (Haskell `Katari.Data.JSONSchema`)
// is a typed subset of a standard JSON Schema document, so both directions are near-identity structural
// walks — but writing them by hand at every use site is exactly how the wire conventions drift (a keyword
// added in one walk, missed in another). This module owns the single traversal each way:
//
//   - `schemaToJson`   — a `JSONSchema` as its standard JSON Schema document (the AI-facing shape
//                        `get_metadata` hands out, and the payload embedded in a serialised generic).
//   - `jsonToSchema`   — the inverse, reconstructing a `JSONSchema` from bare `Json` without an `as`
//                        cast (each keyword is read and validated field by field).
//
// `RequestSchema` (an effect-generic's request list) round-trips alongside, since a `requests`-kind
// generic argument carries one.

import {
  createAgentName,
  type JSONSchema,
  type Json,
  type RequestSchema,
} from "@katari-lang/types";

/** The concrete `type` keywords a `JSONSchema` may carry (used to validate an untyped `type` field). */
const SCHEMA_TYPES = new Set(["null", "boolean", "integer", "number", "string", "array", "object"]);

function isJsonObject(json: Json | undefined): json is { [key: string]: Json } {
  return typeof json === "object" && json !== null && !Array.isArray(json);
}

// ─── JSONSchema → Json ──────────────────────────────────────────────────────────────────────────

/** A `JSONSchema` as its standard JSON Schema document. Only the keywords present are emitted, so an
 *  `{}`-any schema round-trips as `{}`. */
export function schemaToJson(schema: JSONSchema): Json {
  const out: { [key: string]: Json } = {};
  if (schema.type !== undefined) out.type = schema.type;
  if (schema.const !== undefined) out.const = schema.const;
  if (schema.items !== undefined) out.items = schemaToJson(schema.items);
  if (schema.prefixItems !== undefined) out.prefixItems = schema.prefixItems.map(schemaToJson);
  if (schema.properties !== undefined) {
    const properties: { [key: string]: Json } = {};
    for (const [key, property] of Object.entries(schema.properties)) {
      properties[key] = schemaToJson(property);
    }
    out.properties = properties;
  }
  if (schema.required !== undefined) out.required = [...schema.required];
  if (schema.additionalProperties !== undefined) {
    out.additionalProperties =
      typeof schema.additionalProperties === "boolean"
        ? schema.additionalProperties
        : schemaToJson(schema.additionalProperties);
  }
  if (schema.anyOf !== undefined) out.anyOf = schema.anyOf.map(schemaToJson);
  if (schema.not !== undefined) out.not = schemaToJson(schema.not);
  if (schema.$generic !== undefined) out.$generic = schema.$generic;
  return out;
}

// ─── Json → JSONSchema ──────────────────────────────────────────────────────────────────────────

/** Reconstruct a `JSONSchema` from its JSON document. A non-object (or an object with unrecognised
 *  keys) yields the keywords it does carry; a `{}` is the any-schema. */
export function jsonToSchema(json: Json): JSONSchema {
  if (!isJsonObject(json)) return {};
  const schema: JSONSchema = {};
  const type = json.type;
  if (typeof type === "string" && SCHEMA_TYPES.has(type)) {
    // The `has` check pins `type` to the schema's literal union without an `as` cast.
    schema.type = jsonSchemaType(type);
  }
  if ("const" in json) schema.const = json.const;
  const items = json.items;
  if (items !== undefined) schema.items = jsonToSchema(items);
  const prefixItems = json.prefixItems;
  if (Array.isArray(prefixItems)) schema.prefixItems = prefixItems.map(jsonToSchema);
  const properties = json.properties;
  if (isJsonObject(properties)) {
    const out: Record<string, JSONSchema> = {};
    for (const [key, property] of Object.entries(properties)) {
      out[key] = jsonToSchema(property);
    }
    schema.properties = out;
  }
  const required = json.required;
  if (Array.isArray(required)) {
    schema.required = required.filter((entry): entry is string => typeof entry === "string");
  }
  const additionalProperties = json.additionalProperties;
  if (typeof additionalProperties === "boolean") {
    schema.additionalProperties = additionalProperties;
  } else if (additionalProperties !== undefined) {
    schema.additionalProperties = jsonToSchema(additionalProperties);
  }
  const anyOf = json.anyOf;
  if (Array.isArray(anyOf)) schema.anyOf = anyOf.map(jsonToSchema);
  const not = json.not;
  if (not !== undefined) schema.not = jsonToSchema(not);
  // `GenericId` is a plain number, so the wire number is the id.
  if (typeof json.$generic === "number") schema.$generic = json.$generic;
  return schema;
}

/** Narrow a validated `type` string to the schema's literal union (the caller has checked membership). */
function jsonSchemaType(type: string): NonNullable<JSONSchema["type"]> {
  switch (type) {
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
    case "object":
      return "object";
    default:
      return "null";
  }
}

// ─── RequestSchema[] ↔ Json (an effect-generic argument's request list) ──────────────────────────

/** A request list as JSON: one `{name, input, output}` per concrete request, `{ $generic }` for an
 *  effect-generic reference. */
export function requestsToJson(requests: RequestSchema[]): Json {
  const out: Json[] = [];
  for (const entry of requests) {
    if (entry.kind === "concrete") {
      out.push({
        name: String(entry.descriptor.name),
        input: schemaToJson(entry.descriptor.input),
        output: schemaToJson(entry.descriptor.output),
      });
    } else {
      out.push({ $generic: entry.generic });
    }
  }
  return out;
}

/** Reconstruct a request list from its JSON form (the inverse of `requestsToJson`). */
export function jsonToRequests(json: Json): RequestSchema[] {
  if (!Array.isArray(json)) return [];
  const requests: RequestSchema[] = [];
  for (const entry of json) {
    if (!isJsonObject(entry)) continue;
    if (typeof entry.$generic === "number") {
      requests.push({ kind: "generic", generic: entry.$generic });
      continue;
    }
    if (typeof entry.name === "string") {
      requests.push({
        kind: "concrete",
        descriptor: {
          name: createAgentName(entry.name),
          input: jsonToSchema(entry.input ?? {}),
          output: jsonToSchema(entry.output ?? {}),
        },
      });
    }
  }
  return requests;
}
