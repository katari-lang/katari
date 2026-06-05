// Generic-schema substitution — the runtime mirror of Haskell's
// `Katari.Schema.fillGenericSchema`.
//
// A GenericSchema is an ordinary JSON Schema that may contain generic-parameter
// placeholders of the form `{"$generic": <id>}`. Filling replaces each
// placeholder whose id is present in the substitution with that id's concrete
// schema (recursing through array `items`, tuple `prefixItems`, object
// `properties`, and `anyOf`), recovering a proper (placeholder-free) schema.
// A placeholder absent from the substitution is left as-is (a partial fill).

import type { Json } from "../json.js";

/** Map from a GenericsId (string key) to its concrete JSON Schema. */
export type GenericSubstitution = Record<string, Json>;

const GENERIC_PLACEHOLDER_KEY = "$generic";

/**
 * Replace every `{"$generic": id}` placeholder in `schema` with
 * `substitution[id]`. Pure: returns a new value, never mutates `schema`.
 */
export function fillGenericSchema(substitution: GenericSubstitution, schema: Json): Json {
  if (Array.isArray(schema)) {
    return schema.map((element) => fillGenericSchema(substitution, element ?? null));
  }
  if (schema === null || typeof schema !== "object") {
    return schema;
  }
  const placeholder = schema[GENERIC_PLACEHOLDER_KEY];
  if (placeholder !== undefined) {
    const key = String(placeholder);
    const replacement = substitution[key];
    if (replacement !== undefined) {
      return replacement;
    }
    return schema;
  }
  const out: { [key: string]: Json } = {};
  for (const [k, v] of Object.entries(schema)) {
    if (v !== undefined) out[k] = fillGenericSchema(substitution, v);
  }
  return out;
}
