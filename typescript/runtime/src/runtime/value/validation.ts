// Schema conformance for runtime values — the checking half of the JSON boundary. The compiler stamps
// every callable's public shape as a `JSONSchema` (`AgentBlock.schema`); this module decides whether a
// runtime `Value` fits one, so the delegate surface can reject a malformed argument (an AI-built
// `call_agent` args record, a `katari run` argument) as a panic instead of letting it corrupt a body.
//
// `conformValue` walks value and schema together and returns the (possibly coerced) value or the list
// of mismatches. Coercion is deliberately minimal: the single rewrite is attaching a missing
// `$constructor` tag when the schema pins exactly one — an AI client naturally omits the discriminator
// on a non-union `data` argument, and the tag is schema-implied there, so we accept and repair rather
// than reject. Everything else is checked, never rewritten (an `integer` already satisfies `number` by
// subtyping, so no numeric re-tagging is needed).
//
// Failure messages carry the path, the expectation, and the offending value's *kind* — never its
// content. A panic message crosses the user boundary, and the value may be private (`value.private`),
// so redaction here is structural: kinds are shape, not data.
//
// The engine's tagged values reach beyond JSON (blob refs, callables), so the walk folds the codec's
// conventions back in: a semantic-string blob satisfies `{"type": "string"}`, a `file` value satisfies
// the `$ref` reference schema, an agent / closure satisfies the `$agent` reference schema. A residual
// `$generic` placeholder (an uninstantiated type parameter) constrains nothing.

import type { GenericId, JSONSchema, Json, SchemaInfo } from "@katari-lang/types";
import { jsonToValue, valueEquals } from "./codec.js";
import type { GenericSubstitution, Value } from "./types.js";

/** One mismatch: where in the argument (a `$`-rooted path) and what was expected. */
export type ConformFailure = { path: string; message: string };

export type ConformResult = { ok: true; value: Value } | { ok: false; failures: ConformFailure[] };

/** The reserved `$`-prefixed schema property names (mirrors `Katari.Schema` / the value codec). */
const CONSTRUCTOR_KEY = "$constructor";
const AGENT_KEY = "$agent";
const FILE_KEY = "$ref";

/**
 * Check `value` against `schema`, returning the conformed value (identical except for repaired
 * `$constructor` tags) or every mismatch found. `schema` should already have its generic placeholders
 * filled (`fillGenericSchema`); a residual `$generic` is treated as unconstrained.
 */
export function conformValue(value: Value, schema: JSONSchema): ConformResult {
  const failures: ConformFailure[] = [];
  const conformed = conform(value, schema, "$", failures, true);
  return conformed !== undefined && failures.length === 0
    ? { ok: true, value: conformed }
    : { ok: false, failures };
}

/**
 * Parse bare wire JSON against a schema: lift it into the tagged value model, then conform. This is
 * the checked counterpart of `jsonToValue` for any input whose target schema is known (a run argument,
 * an escalation answer).
 */
export function parseJson(json: Json, schema: JSONSchema): ConformResult {
  let value: Value;
  try {
    value = jsonToValue(json);
  } catch (error) {
    return {
      ok: false,
      failures: [{ path: "$", message: error instanceof Error ? error.message : String(error) }],
    };
  }
  return conformValue(value, schema);
}

/** Render conform failures as one panic-ready message (one line per mismatch). */
export function renderConformFailures(failures: ConformFailure[]): string {
  return failures.map((failure) => `${failure.path}: ${failure.message}`).join("; ");
}

// ─── generic instantiation ────────────────────────────────────────────────────────────────────

/**
 * Replace every `$generic` placeholder with the substitution's concrete schema (the TypeScript mirror
 * of Haskell `Katari.Schema.fillGenericSchema` — the shared instantiation the IR contract promises).
 * A placeholder absent from the map is left unchanged (a partial fill).
 */
export function fillGenericSchema(
  substitution: ReadonlyMap<GenericId, JSONSchema>,
  schema: JSONSchema,
): JSONSchema {
  if (substitution.size === 0) return schema;
  if (schema.$generic !== undefined) {
    return substitution.get(schema.$generic) ?? schema;
  }
  const filled: JSONSchema = { ...schema };
  if (schema.items !== undefined) filled.items = fillGenericSchema(substitution, schema.items);
  if (schema.prefixItems !== undefined) {
    filled.prefixItems = schema.prefixItems.map((item) => fillGenericSchema(substitution, item));
  }
  if (schema.properties !== undefined) {
    const properties: Record<string, JSONSchema> = {};
    for (const [key, property] of Object.entries(schema.properties)) {
      properties[key] = fillGenericSchema(substitution, property);
    }
    filled.properties = properties;
  }
  if (typeof schema.additionalProperties === "object") {
    filled.additionalProperties = fillGenericSchema(substitution, schema.additionalProperties);
  }
  if (schema.anyOf !== undefined) {
    filled.anyOf = schema.anyOf.map((branch) => fillGenericSchema(substitution, branch));
  }
  if (schema.not !== undefined) filled.not = fillGenericSchema(substitution, schema.not);
  return filled;
}

/**
 * The `GenericId`-keyed type substitution a callable's carried generics imply: each bound parameter
 * name (`SchemaInfo.genericBindings`) whose argument is a *type* schema maps its id to that schema.
 * (An effect-kind argument substitutes into `requests`, not into `input` / `output`.)
 */
export function typeSubstitutionOf(
  bindings: SchemaInfo["genericBindings"],
  generics: GenericSubstitution | undefined,
): Map<GenericId, JSONSchema> {
  const substitution = new Map<GenericId, JSONSchema>();
  if (generics === undefined) return substitution;
  for (const [name, genericId] of Object.entries(bindings)) {
    const argument = generics[name];
    if (argument !== undefined && argument.kind === "type") {
      substitution.set(genericId, argument.schema);
    }
  }
  return substitution;
}

// ─── the conformance walk ─────────────────────────────────────────────────────────────────────

/** Whether a schema constrains anything at all (`{}` — and a bare `$generic` — accept every value). */
function isUnconstrained(schema: JSONSchema): boolean {
  return (
    schema.type === undefined &&
    schema.const === undefined &&
    schema.items === undefined &&
    schema.prefixItems === undefined &&
    schema.properties === undefined &&
    schema.required === undefined &&
    schema.additionalProperties === undefined &&
    schema.anyOf === undefined &&
    schema.not === undefined
  );
}

/** Whether an object schema is one of the `$`-keyed reference shapes (a callable / file handle). */
function referenceKeyOf(schema: JSONSchema): string | undefined {
  if (schema.required?.includes(AGENT_KEY)) return AGENT_KEY;
  if (schema.required?.includes(FILE_KEY)) return FILE_KEY;
  return undefined;
}

/**
 * The recursive check: returns the conformed value, or `undefined` after appending the mismatches to
 * `failures`. The returned value is `value` itself unless a `$constructor` repair happened somewhere
 * beneath (rebuild is minimal, so untouched subtrees keep their identity — blob refs and callables are
 * never cloned, which the resource-ownership machinery relies on).
 *
 * `repair` gates the `$constructor` fix-up: inside an `anyOf` branch trial the expected constructor is
 * NOT uniquely determined (an untagged `{}` would "match" whichever tag-only branch comes first), so
 * trials run strict and only an unambiguous position may repair.
 */
function conform(
  value: Value,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
  repair: boolean,
): Value | undefined {
  // A residual generic placeholder constrains nothing (the callable was not instantiated at this
  // parameter; the static checker already bounded it).
  if (schema.$generic !== undefined) return value;

  if (schema.not !== undefined) {
    // The compiler emits `not` only as `{"not": {}}` (never); check the general form anyway.
    const scratch: ConformFailure[] = [];
    if (conform(value, schema.not, path, scratch, false) !== undefined && scratch.length === 0) {
      failures.push({ path, message: "no value can satisfy this schema (never)" });
      return undefined;
    }
    return value;
  }

  if (schema.anyOf !== undefined) {
    for (const branch of schema.anyOf) {
      const scratch: ConformFailure[] = [];
      const conformed = conform(value, branch, path, scratch, false);
      if (conformed !== undefined && scratch.length === 0) return conformed;
    }
    failures.push({
      path,
      message: `${describeValue(value)} does not match any variant of the expected union`,
    });
    return undefined;
  }

  if (schema.const !== undefined) {
    // A blob-backed string's content is not readable synchronously; accept it rather than fetch.
    if (value.kind === "ref" && value.semanticKind === "string") return value;
    if (!valueEquals(value, jsonToValue(schema.const))) {
      failures.push({
        path,
        message: `${describeValue(value)} does not equal the expected constant`,
      });
      return undefined;
    }
    return value;
  }

  // A callable or a blob handle satisfies its `$`-keyed reference schema (and an unconstrained one);
  // any other constraint cannot hold for it.
  if (value.kind === "agent" || value.kind === "closure") {
    if (isUnconstrained(schema) || referenceKeyOf(schema) === AGENT_KEY) return value;
    failures.push({ path, message: `expected ${describeSchema(schema)}, got a callable value` });
    return undefined;
  }
  if (value.kind === "ref" && value.semanticKind === "file") {
    if (isUnconstrained(schema) || referenceKeyOf(schema) === FILE_KEY) return value;
    failures.push({ path, message: `expected ${describeSchema(schema)}, got a file handle` });
    return undefined;
  }

  switch (schema.type) {
    case undefined:
      break;
    case "null":
      if (value.kind !== "null") return typeMismatch(value, schema, path, failures);
      return value;
    case "boolean":
      if (value.kind !== "boolean") return typeMismatch(value, schema, path, failures);
      return value;
    case "integer":
      if (value.kind !== "integer") return typeMismatch(value, schema, path, failures);
      return value;
    case "number":
      // `integer` is a subtype of `number`; keep its tag.
      if (value.kind !== "number" && value.kind !== "integer") {
        return typeMismatch(value, schema, path, failures);
      }
      return value;
    case "string":
      // A semantic-string blob is a string by value; its content constraints are unverifiable here.
      if (value.kind === "ref" && value.semanticKind === "string") return value;
      if (value.kind !== "string") return typeMismatch(value, schema, path, failures);
      return value;
    case "array":
      if (value.kind !== "array") return typeMismatch(value, schema, path, failures);
      return conformArray(value, schema, path, failures, repair);
    case "object":
      if (value.kind !== "record") return typeMismatch(value, schema, path, failures);
      return conformRecord(value, schema, path, failures, repair);
  }

  // No `type` (an `{}`-any, possibly with stray keywords): apply whichever structural keywords are
  // present against a matching value; anything else passes.
  if (value.kind === "array" && (schema.items !== undefined || schema.prefixItems !== undefined)) {
    return conformArray(value, schema, path, failures, repair);
  }
  if (
    value.kind === "record" &&
    (schema.properties !== undefined ||
      schema.required !== undefined ||
      schema.additionalProperties !== undefined)
  ) {
    return conformRecord(value, schema, path, failures, repair);
  }
  return value;
}

function typeMismatch(
  value: Value,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
): undefined {
  failures.push({
    path,
    message: `expected ${describeSchema(schema)}, got ${describeValue(value)}`,
  });
  return undefined;
}

function conformArray(
  value: Extract<Value, { kind: "array" }>,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
  repair: boolean,
): Value | undefined {
  let changed = false;
  let failed = false;
  const elements: Value[] = [];
  for (let index = 0; index < value.elements.length; index += 1) {
    const element = value.elements[index];
    if (element === undefined) continue;
    // Positional (tuple) schemas win; a homogeneous `items` applies to every element. An element past
    // the `prefixItems` positions is unconstrained (Draft 2020-12 semantics — the compiler emits no
    // `items: false` tail).
    const elementSchema =
      schema.prefixItems?.[index] ?? (schema.prefixItems ? undefined : schema.items);
    if (elementSchema === undefined) {
      elements.push(element);
      continue;
    }
    const conformed = conform(element, elementSchema, `${path}[${index}]`, failures, repair);
    if (conformed === undefined) {
      failed = true;
      continue;
    }
    if (conformed !== element) changed = true;
    elements.push(conformed);
  }
  if (schema.prefixItems !== undefined && value.elements.length < schema.prefixItems.length) {
    failures.push({
      path,
      message: `expected a tuple of ${schema.prefixItems.length} elements, got ${value.elements.length}`,
    });
    failed = true;
  }
  if (failed) return undefined;
  return changed ? { ...value, elements } : value;
}

function conformRecord(
  value: Extract<Value, { kind: "record" }>,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
  repair: boolean,
): Value | undefined {
  let failed = false;

  // The `$constructor` discriminator lives out-of-band on the value (`ctor`), in-band in the schema
  // (a required const property). A matching tag passes; a *missing* tag against a pinned constructor
  // is repaired (an AI-built record legitimately omits it); a different tag is a mismatch.
  let ctor = value.ctor;
  const constructorSchema = schema.properties?.[CONSTRUCTOR_KEY];
  if (constructorSchema !== undefined && typeof constructorSchema.const === "string") {
    const expected = constructorSchema.const;
    if (ctor === undefined && repair) {
      ctor = expected as typeof value.ctor;
    } else if (ctor !== expected) {
      failures.push({
        path,
        message: `expected a "${expected}" value, got a "${ctor}" value`,
      });
      failed = true;
    }
  }

  let changed = ctor !== value.ctor;
  const fields: Record<string, Value> = {};
  for (const [key, field] of Object.entries(value.fields)) {
    const propertySchema = schema.properties?.[key];
    if (propertySchema !== undefined) {
      const conformed = conform(field, propertySchema, `${path}.${key}`, failures, repair);
      if (conformed === undefined) {
        failed = true;
        continue;
      }
      if (conformed !== field) changed = true;
      fields[key] = conformed;
      continue;
    }
    // A key beyond the declared properties: closed (`false`) rejects it, a tail schema (`record[V]`)
    // constrains it, open (`true` / absent) passes it through.
    if (schema.additionalProperties === false) {
      failures.push({ path: `${path}.${key}`, message: "unexpected field" });
      failed = true;
      continue;
    }
    if (typeof schema.additionalProperties === "object") {
      const conformed = conform(
        field,
        schema.additionalProperties,
        `${path}.${key}`,
        failures,
        repair,
      );
      if (conformed === undefined) {
        failed = true;
        continue;
      }
      if (conformed !== field) changed = true;
      fields[key] = conformed;
      continue;
    }
    fields[key] = field;
  }

  for (const required of schema.required ?? []) {
    if (required === CONSTRUCTOR_KEY) {
      if (ctor === undefined) {
        failures.push({ path, message: "expected a constructor-tagged (data) value" });
        failed = true;
      }
      continue;
    }
    // A required `$agent` / `$ref` cannot be satisfied by a record (callables and files were accepted
    // before the record walk), so reaching here with one is a mismatch.
    if (required === AGENT_KEY || required === FILE_KEY) {
      failures.push({
        path,
        message: `expected ${required === AGENT_KEY ? "a callable value" : "a file handle"}, got a record`,
      });
      failed = true;
      continue;
    }
    if (value.fields[required] === undefined) {
      failures.push({ path, message: `missing required field "${required}"` });
      failed = true;
    }
  }

  if (failed) return undefined;
  if (!changed) return value;
  return ctor !== undefined ? { ...value, fields, ctor } : { ...value, fields };
}

// ─── description helpers (shape only — never value content, which may be private) ─────────────

function describeValue(value: Value): string {
  switch (value.kind) {
    case "record":
      return value.ctor !== undefined ? `a "${value.ctor}" value` : "a record";
    case "ref":
      return value.semanticKind === "string" ? "a string" : "a file handle";
    case "closure":
    case "agent":
      return "a callable value";
    default:
      return `a value of type ${value.kind}`;
  }
}

function describeSchema(schema: JSONSchema): string {
  if (schema.type !== undefined) return `a value of type ${schema.type}`;
  if (referenceKeyOf(schema) === AGENT_KEY) return "a callable value";
  if (referenceKeyOf(schema) === FILE_KEY) return "a file handle";
  return "a conforming value";
}
