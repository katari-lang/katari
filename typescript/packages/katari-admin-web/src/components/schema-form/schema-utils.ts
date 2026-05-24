// Small helpers for interpreting JSON Schema fragments produced by
// katari-compiler. The full JSON Schema spec is large; we lean on the
// subset Katari actually emits today.

export type JsonSchema = {
  type?: string | string[];
  description?: string;
  enum?: unknown[];
  const?: unknown;
  default?: unknown;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  items?: JsonSchema;
  oneOf?: JsonSchema[];
  anyOf?: JsonSchema[];
  allOf?: JsonSchema[];
  format?: string;
  minimum?: number;
  maximum?: number;
  title?: string;
  [key: string]: unknown;
};

export function singleType(schema: JsonSchema): string | undefined {
  if (typeof schema.type === "string") return schema.type;
  if (Array.isArray(schema.type)) {
    const nonNull = schema.type.filter((t) => t !== "null");
    if (nonNull.length === 1) return nonNull[0];
  }
  return undefined;
}

export function isUnion(schema: JsonSchema): boolean {
  return (
    Array.isArray(schema.oneOf) ||
    Array.isArray(schema.anyOf) ||
    (Array.isArray(schema.type) && schema.type.filter((t) => t !== "null").length > 1)
  );
}

/**
 * Construct an initial form value matching the schema's shape. The form
 * never starts blank for objects / arrays — operators want to see the
 * structure ready to fill in.
 */
export function schemaInitialValue(schema: JsonSchema): unknown {
  if (schema.default !== undefined) return structuredClone(schema.default);
  if (schema.const !== undefined) return schema.const;
  if (Array.isArray(schema.enum) && schema.enum.length > 0) return schema.enum[0];
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
      return [];
    default:
      return null;
  }
}
