// Small helpers for interpreting JSON Schema fragments produced by
// katari-compiler. The full JSON Schema spec is large; we lean on the
// subset Katari actually emits today (= Schema.hs's SchemaCore variants:
// primitives, object, array, prefixItems-tuple, anyOf, const, enum, not).

export type JsonSchema = {
  type?: string | string[];
  description?: string;
  enum?: unknown[];
  const?: unknown;
  default?: unknown;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  items?: JsonSchema;
  prefixItems?: JsonSchema[];
  oneOf?: JsonSchema[];
  anyOf?: JsonSchema[];
  allOf?: JsonSchema[];
  not?: JsonSchema;
  format?: string;
  minimum?: number;
  maximum?: number;
  title?: string;
  [key: string]: unknown;
};

export const CTOR_DISCRIMINATOR = "$constructor";

/** Return the single primary type for a schema, ignoring an explicit
 * `null` companion (`["string","null"]` → "string"). Returns undefined
 * for genuine multi-type unions or when no `type` keyword is present. */
export function singleType(schema: JsonSchema): string | undefined {
  if (typeof schema.type === "string") return schema.type;
  if (Array.isArray(schema.type)) {
    const nonNull = schema.type.filter((t) => t !== "null");
    if (nonNull.length === 1) return nonNull[0];
  }
  return undefined;
}

export function unionBranches(schema: JsonSchema): JsonSchema[] | null {
  if (Array.isArray(schema.anyOf) && schema.anyOf.length > 0) return schema.anyOf;
  if (Array.isArray(schema.oneOf) && schema.oneOf.length > 0) return schema.oneOf;
  return null;
}

/** True if the schema is Katari's `file` value-reference shape: an object
 * with `as: {const: "file"}` plus a `$ref` property (Schema.hs `fileRefCore`).
 * Such a field is filled by picking / uploading a file, not by typing JSON. */
export function isFileRefSchema(schema: JsonSchema): boolean {
  if (singleType(schema) !== "object") return false;
  const props = schema.properties;
  if (props === undefined) return false;
  const as = props.as;
  if (as === undefined || as.const !== "file") return false;
  return props.$ref !== undefined;
}

/** True if the schema is Katari's callable (agent / closure) reference shape:
 * an object with a `$agent` string property (Schema.hs `callableRefCore`). Such
 * a field is filled by picking an agent, not by typing the id. */
export function isCallableRefSchema(schema: JsonSchema): boolean {
  if (singleType(schema) !== "object") return false;
  const props = schema.properties;
  if (props === undefined) return false;
  return props.$agent !== undefined;
}

/** True if the schema looks like Katari's tagged-data shape: an object
 * with a `$constructor: {const: "<qname>"}` property. */
export function taggedCtorOf(schema: JsonSchema): string | null {
  if (singleType(schema) !== "object") return null;
  const props = schema.properties;
  if (props === undefined) return null;
  const ctor = props[CTOR_DISCRIMINATOR];
  if (ctor === undefined) return null;
  if (typeof ctor.const !== "string") return null;
  return ctor.const;
}

/** True if every branch of the union is a tagged-data object (= the
 * union came from `data A | data B | ...`). When tagged, the picker
 * can label each branch by its ctor instead of by raw type. */
export function isTaggedUnion(branches: JsonSchema[]): boolean {
  return branches.every((b) => taggedCtorOf(b) !== null);
}

/** Human label for a non-tagged union branch ("string", "number",
 * branch title, or "option N" as a last resort). */
export function branchLabel(schema: JsonSchema, index: number): string {
  const tagged = taggedCtorOf(schema);
  if (tagged !== null) return tagged;
  if (typeof schema.title === "string") return schema.title;
  if (typeof schema.const === "string") return JSON.stringify(schema.const);
  const t = singleType(schema);
  if (t !== undefined) return t;
  if (Array.isArray(schema.type)) return schema.type.join(" | ");
  return `option ${index + 1}`;
}

/** True if the schema is the `never` shape Katari emits for `-> never`
 * (`{"not": {}}`). Operators can't satisfy this with any value, so the
 * UI should suggest cancelling rather than asking for input. */
export function isNeverSchema(schema: JsonSchema): boolean {
  if (typeof schema.not !== "object" || schema.not === null) return false;
  // `not: {}` is the canonical never; anything more elaborate (e.g.
  // `not: {type: "string"}`) is a different beast and we leave it to
  // the union / unknown fallback.
  return Object.keys(schema.not).length === 0;
}

/**
 * Construct an initial form value matching the schema's shape. The form
 * never starts blank for objects / arrays / tuples — operators want to
 * see the structure ready to fill in. Const properties are auto-set so
 * the UI can hide their inputs without losing the value.
 */
export function schemaInitialValue(schema: JsonSchema): unknown {
  if (schema.default !== undefined) return structuredClone(schema.default);
  if (schema.const !== undefined) return schema.const;
  if (Array.isArray(schema.enum) && schema.enum.length > 0) return schema.enum[0];

  const branches = unionBranches(schema);
  if (branches !== null) return schemaInitialValue(branches[0]!);

  // A `file` field starts empty (= no file picked); the operator selects or
  // uploads one. Don't synthesize a half-built `$ref` object.
  if (isFileRefSchema(schema)) return null;

  const type = singleType(schema);
  switch (type) {
    case "string":
      return "";
    case "number":
    case "integer":
      return 0;
    case "boolean":
      return false;
    case "null":
      return null;
    case "object": {
      const out: Record<string, unknown> = {};
      const props = schema.properties ?? {};
      for (const [k, sub] of Object.entries(props)) {
        out[k] = schemaInitialValue(sub);
      }
      return out;
    }
    case "array":
      if (Array.isArray(schema.prefixItems)) {
        return schema.prefixItems.map((s) => schemaInitialValue(s));
      }
      return [];
    default:
      return null;
  }
}
