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

/**
 * Fill a requests GenericSchema — a JSON array whose elements are concrete
 * request descriptors `{name, input, output}` interleaved with effect-generic
 * placeholders `{"$generic": id}`. Each placeholder is replaced by the
 * substituted effect's own request array (spliced in, flattening one level);
 * an unsubstituted placeholder is dropped. Duplicate requests (by `name`) are
 * collapsed, keeping first occurrence. Returns a placeholder-free array.
 */
export function fillRequestsSchema(substitution: GenericSubstitution, requests: Json): Json {
  const elements = Array.isArray(requests) ? requests : [];
  const collected: Json[] = [];
  for (const element of elements) {
    if (element !== null && typeof element === "object" && !Array.isArray(element)) {
      const placeholder = element[GENERIC_PLACEHOLDER_KEY];
      if (placeholder !== undefined) {
        const replacement = substitution[String(placeholder)];
        if (Array.isArray(replacement)) collected.push(...replacement);
        continue;
      }
    }
    collected.push(element);
  }
  const seen = new Set<string>();
  return collected.filter((request) => {
    const name =
      request !== null && typeof request === "object" && !Array.isArray(request)
        ? request["name"]
        : undefined;
    const key = typeof name === "string" ? name : JSON.stringify(request);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
