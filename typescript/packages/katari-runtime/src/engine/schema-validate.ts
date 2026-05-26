// Minimal JSON-Schema validator for the draft-07-ish subset that
// `katari-compiler.Katari.Schema` emits.
//
// Implemented locally rather than pulling in `ajv` because:
//   - The schema dialect is tightly scoped (= type / properties /
//     required / additionalProperties / items / const / enum / anyOf
//     / oneOf — no $ref, no patternProperties, no draft-2020 keywords).
//   - The validator is on the prim hot path (call_agent); a 200-line
//     hand-rolled walker is easier to audit for soundness and adds
//     zero supply-chain surface.
//
// If the compiler-side schema vocabulary grows beyond this subset,
// extend the switch below — anything unrecognised currently passes
// (= permissive) so we don't false-reject downstream usage.

import type { Json } from "../json.js";

/**
 * Validate `raw` against `schema`. Returns the empty array on success;
 * otherwise an array of human-readable error messages anchored to a
 * JSON-pointer-ish path. Errors are collected (not short-circuited)
 * so a single call surfaces every problem at once.
 */
export function validateAgainstSchema(raw: unknown, schema: Json): string[] {
  const errors: string[] = [];
  walk(raw, schema, "", errors);
  return errors;
}

// ─── internals ────────────────────────────────────────────────────────────

function walk(
  value: unknown,
  schema: Json,
  path: string,
  errors: string[],
): void {
  if (!isPlainObject(schema)) {
    // Boolean schemas: `true` accepts anything, `false` rejects.
    if (schema === false) {
      errors.push(`${formatPath(path)}: schema rejects all values`);
    }
    return;
  }

  // anyOf / oneOf collapse to "at least one branch validates".
  const anyOf = schema["anyOf"];
  if (Array.isArray(anyOf)) {
    if (!anyOf.some((branch) => validateAgainstSchema(value, branch as Json).length === 0)) {
      errors.push(`${formatPath(path)}: no anyOf branch matched`);
    }
    return;
  }
  const oneOf = schema["oneOf"];
  if (Array.isArray(oneOf)) {
    const matches = oneOf.filter(
      (branch) => validateAgainstSchema(value, branch as Json).length === 0,
    );
    if (matches.length === 0) {
      errors.push(`${formatPath(path)}: no oneOf branch matched`);
    } else if (matches.length > 1) {
      errors.push(
        `${formatPath(path)}: ${matches.length} oneOf branches matched (expected exactly 1)`,
      );
    }
    return;
  }

  // `const` constrains to one literal value (structural equality).
  if ("const" in schema) {
    if (!deepEqualJson(value, schema["const"] as Json)) {
      errors.push(
        `${formatPath(path)}: expected const ${JSON.stringify(schema["const"])}, got ${JSON.stringify(value)}`,
      );
    }
    return;
  }
  // `enum` is "value is one of N literals".
  const enumList = schema["enum"];
  if (Array.isArray(enumList)) {
    if (!enumList.some((cand) => deepEqualJson(value, cand as Json))) {
      errors.push(
        `${formatPath(path)}: value ${JSON.stringify(value)} not in enum`,
      );
    }
    return;
  }

  // `type` keyword. We accept singular strings (the compiler only emits
  // those today); a string-array form is also legal per JSON Schema but
  // not currently produced.
  const typeKeyword = schema["type"];
  if (typeof typeKeyword === "string") {
    if (!checkType(value, typeKeyword)) {
      errors.push(
        `${formatPath(path)}: expected type ${typeKeyword}, got ${describeRuntimeType(value)}`,
      );
      return;
    }
  }

  // Structural recursion.
  if (typeKeyword === "object" || (typeof typeKeyword !== "string" && isPlainObject(value))) {
    walkObject(value as Record<string, unknown>, schema, path, errors);
    return;
  }
  if (typeKeyword === "array" || (typeof typeKeyword !== "string" && Array.isArray(value))) {
    walkArray(value as unknown[], schema, path, errors);
    return;
  }
}

function walkObject(
  value: Record<string, unknown>,
  schema: Record<string, unknown>,
  path: string,
  errors: string[],
): void {
  const properties = schema["properties"];
  const required = schema["required"];
  const additional = schema["additionalProperties"];

  if (Array.isArray(required)) {
    for (const key of required) {
      if (typeof key === "string" && !(key in value)) {
        errors.push(`${formatPath(path)}: missing required key '${key}'`);
      }
    }
  }

  if (isPlainObject(properties)) {
    for (const [key, subSchema] of Object.entries(properties)) {
      if (key in value) {
        walk(value[key], subSchema as Json, joinPath(path, key), errors);
      }
    }
  }

  if (additional === false) {
    const knownKeys = isPlainObject(properties) ? new Set(Object.keys(properties)) : new Set<string>();
    for (const key of Object.keys(value)) {
      if (!knownKeys.has(key)) {
        errors.push(
          `${formatPath(path)}: unknown key '${key}' (additionalProperties: false)`,
        );
      }
    }
  }
}

function walkArray(
  value: unknown[],
  schema: Record<string, unknown>,
  path: string,
  errors: string[],
): void {
  const items = schema["items"];
  if (items === undefined) return;
  for (let i = 0; i < value.length; i++) {
    walk(value[i], items as Json, joinPath(path, String(i)), errors);
  }
}

function checkType(value: unknown, type: string): boolean {
  switch (type) {
    case "null":
      return value === null;
    case "boolean":
      return typeof value === "boolean";
    case "integer":
      return typeof value === "number" && Number.isInteger(value);
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    case "string":
      return typeof value === "string";
    case "array":
      return Array.isArray(value);
    case "object":
      return isPlainObject(value);
    default:
      // Unknown keyword (e.g. a future addition): pass-through.
      return true;
  }
}

function describeRuntimeType(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (isPlainObject(value)) return "object";
  return typeof value;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}

function deepEqualJson(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqualJson(a[i], b[i])) return false;
    }
    return true;
  }
  if (isPlainObject(a) && isPlainObject(b)) {
    const ak = Object.keys(a);
    const bk = Object.keys(b);
    if (ak.length !== bk.length) return false;
    for (const k of ak) {
      if (!(k in b)) return false;
      if (!deepEqualJson(a[k], b[k])) return false;
    }
    return true;
  }
  return false;
}

function joinPath(parent: string, key: string): string {
  return parent === "" ? key : `${parent}.${key}`;
}

function formatPath(path: string): string {
  return path === "" ? "<root>" : path;
}
