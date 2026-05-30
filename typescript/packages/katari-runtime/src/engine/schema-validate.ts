// JSON-Schema validation for `call_agent`'s input-args check (and any
// future boundary that wants schema-driven enforcement).
//
// Backed by AJV (draft-07 mode). The schema dialect emitted by
// `katari-compiler.Katari.Schema` — `type` / `properties` / `required`
// / `additionalProperties` / `items` / `const` / `enum` / `anyOf` — is
// a straight subset, so a plain `new Ajv()` configuration works out of
// the box without per-keyword tuning.
//
// Compiled validators are cached by **schema identity** (object
// reference): the same per-agent input-schema is reused across calls,
// and constructing the AJV validator function isn't trivially cheap.
// The cache is WeakMap-keyed so swapping in a new IR snapshot lets the
// old validators get garbage-collected together with their schemas.

import { Ajv, type AnySchema, type ValidateFunction } from "ajv";
import type { Json } from "../json.js";

const ajv = new Ajv({
  // The compiler-emitted schema vocabulary is drift-07 subset, which
  // is AJV's default. Explicit options:
  //   - allErrors: collect every problem (default short-circuits).
  //   - strict: false — we don't (yet) emit '$id' / '$schema' / etc.,
  //     and strict mode complains about that. Turn it off so our
  //     plain schemas pass without busywork.
  //   - useDefaults / coerceTypes are deliberately left at their
  //     defaults (= off) since we want strict validation, not
  //     value-mutating coercion.
  allErrors: true,
  strict: false,
});

const compiledCache = new WeakMap<object, ValidateFunction>();

/**
 * Validate `raw` against `schema`. Returns the empty array on success;
 * otherwise an array of human-readable error messages keyed by their
 * JSON Pointer path (or `<root>` for whole-document failures).
 *
 * Compiled validators are cached per-schema-object so repeat calls
 * with the same schema (= the same agent's input schema) reuse the
 * already-compiled validator function.
 */
export function validateAgainstSchema(raw: unknown, schema: Json): string[] {
  const validate = getValidator(schema);
  if (validate(raw)) return [];
  const errors = validate.errors ?? [];
  return errors.map(formatAjvError);
}

function getValidator(schema: Json): ValidateFunction {
  // Boolean schemas (`true` / `false`) are valid JSON Schema. AJV
  // accepts them too, but they can't be cached in our WeakMap since
  // they aren't objects. Compile fresh each time — they're trivial.
  if (typeof schema === "boolean") {
    return ajv.compile(schema);
  }
  if (schema === null) {
    // `null` is not a legal JSON Schema document; treat it as a
    // permissive `true` to avoid throwing on an arguably-recoverable
    // caller bug. The caller is expected to gate on `inputSchema` being
    // non-null at the producer side.
    return ajv.compile(true);
  }
  const cached = compiledCache.get(schema as object);
  if (cached !== undefined) return cached;
  const fresh = ajv.compile(schema as AnySchema);
  compiledCache.set(schema as object, fresh);
  return fresh;
}

function formatAjvError(err: NonNullable<ValidateFunction["errors"]>[number]): string {
  const path = err.instancePath === "" ? "<root>" : err.instancePath;
  return `${path}: ${err.message ?? "(unknown error)"}`;
}

// ─── rep-aware relaxation ────────────────────────────────────────────────────
//
// A compiled schema describes LOGICAL types: a string is `{type:"string"}`. But
// a runtime value passed through `valueToRaw` can be the same string carried as
// a content ref (`{$ref, as:"string", ...}`) — a large value promoted to the
// store. Validating that raw ref against `{type:"string"}` would wrongly reject
// it. `relaxSchemaForRefs` rewrites every `{type:"string"}` node to also accept
// the `$ref as:"string"` envelope, so the AI-facing schema stays clean while
// runtime validation tolerates the ref form. (Callables need no relaxation —
// agents AND closures both serialise as `$agent`. `file` is already a ref shape.
// A ref's content can't be inspected without a fetch, so the envelope branch
// checks only shape, not the string's value constraints.)

const STRING_REF_SCHEMA: Json = {
  type: "object",
  properties: {
    $ref: { type: "object" },
    as: { const: "string" },
    hash: { type: "string" },
    size: { type: "number" },
  },
  required: ["$ref", "as", "hash"],
  additionalProperties: true,
};

/** Cache the relaxed form per source schema string so AJV's own per-object
 *  validator cache (keyed by the relaxed object) stays warm across calls. */
const relaxCache = new Map<string, Json>();

/** Parse `inputSchema` (a JSON Schema string) and relax its string nodes to
 *  also accept `$ref as:"string"`. Memoised by the source string. */
export function relaxedSchemaFromString(inputSchema: string): Json {
  const cached = relaxCache.get(inputSchema);
  if (cached !== undefined) return cached;
  const relaxed = relaxSchemaForRefs(JSON.parse(inputSchema) as Json);
  relaxCache.set(inputSchema, relaxed);
  return relaxed;
}

/** Rewrite every `{type:"string"}` node to `anyOf:[<original>, $ref-as-string]`.
 *  Recurses through subschema-bearing keywords; non-schema values pass through. */
export function relaxSchemaForRefs(schema: Json): Json {
  if (schema === null || typeof schema !== "object") return schema;
  if (Array.isArray(schema)) return schema.map(relaxSchemaForRefs);
  const obj = schema as Record<string, Json>;
  if (obj.type === "string") {
    return { anyOf: [obj, STRING_REF_SCHEMA] };
  }
  const out: Record<string, Json> = {};
  for (const [key, value] of Object.entries(obj)) out[key] = relaxSchemaForRefs(value);
  return out;
}
