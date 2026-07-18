// Schema conformance for runtime values — the checking half of the JSON boundary, and a *separate* pass
// from the codec. The codec (`./codec.ts`, `../engine/json-value.ts`) is a blind, total bijection: it
// turns wire JSON into a `Value` (and back) with no schema in sight. This module then decides whether a
// decoded `Value` fits a `JSONSchema`, so each dynamic input boundary can reject a malformed argument in its
// OWN terms: a `call_agent` args record as a catchable `reflection.call_error` (engine-side), an mcp / webhook
// delivery and a `katari run` argument as a per-request 400 (actor-side), and the delegate acceptance surface
// — the last-line defence every path has already pre-validated — as a PANIC (a genuine defect). It only
// *checks* — it never rewrites the value to fit (the AI supplies a value already in wire shape, e.g. a `data`
// value's `$constructor` tag, so there is nothing to repair).
//
// The compiler emits a `data` type as a nested schema — `{ "$constructor": {const}, "value": {fields} }`
// (Haskell `Katari.Schema`) — matching the wire form, while the engine keeps a `data` value's constructor
// out-of-band (`value.ctor`) and its fields flat. This module bridges the two: it checks `value.ctor`
// against the `$constructor` const and the flat fields against the `value` sub-schema.
//
// Failure messages carry the path, the expectation, and the offending value's *kind* — never its content
// (a value may be private). Kinds are shape, not data.

import type { GenericId, JSONSchema, Json, SchemaInfo } from "@katari-lang/types";
import type { BlobId } from "../ids.js";
import {
  AGENT_KEY,
  CONSTRUCTOR_KEY,
  FILE_KEY,
  SEMANTIC_KIND_KEY,
  VALUE_KEY,
  valueEquals,
} from "./codec.js";
import type { GenericSubstitution, Value } from "./types.js";

/** One mismatch: where in the argument (a `$`-rooted path) and what was expected. */
export type ConformFailure = { path: string; message: string };

export type ConformResult = { ok: true } | { ok: false; failures: ConformFailure[] };

/** Check `value` against `schema`. `schema` should already have its generic placeholders filled
 *  (`fillGenericSchema`); a residual `$generic` is treated as unconstrained. The value is never rewritten. */
export function conformValue(value: Value, schema: JSONSchema): ConformResult {
  const failures: ConformFailure[] = [];
  conform(value, schema, "$", failures);
  return failures.length === 0 ? { ok: true } : { ok: false, failures };
}

/** Render conform failures as one panic-ready message (one line per mismatch). */
export function renderConformFailures(failures: ConformFailure[]): string {
  return failures.map((failure) => `${failure.path}: ${failure.message}`).join("; ");
}

// ─── schema-directed revive ────────────────────────────────────────────────────────────────────
//
// The one transform the delegation boundary applies to a DYNAMIC (`call_agent`) argument before validating
// it. A document has no dedicated wire step (there is no `json.decode`), so a value drops into a call
// verbatim — EXCEPT one shape an AI cannot produce as a real value: a `file`. When a model replays a
// `{ "$ref": id }` handle it saw earlier, it arrives as a literal RECORD, and the callee that declared a
// `file` parameter needs the real handle. `reviveArgument` reconstructs it — SCHEMA-DIRECTED: a `$ref`
// record becomes a `file` value only where the schema expects a `file`, never a blind lift (a literal
// `$ref` record kept as data stays data). It recurses through objects / arrays / data / unions so a file
// nested anywhere revives at its schema position, and leaves every other value untouched.

/** Revive the wire references an AI replayed as literal records, guided by `schema`: a `{ $ref }` record
 *  at a `file` position becomes a real `file` value. Every other value passes through unchanged. */
export function reviveArgument(value: Value, schema: JSONSchema): Value {
  if (schema.$generic !== undefined) return value;

  if (schema.anyOf !== undefined) {
    // Revive against the first branch that ACCEPTS the revived value — so `file | null` revives a `$ref`
    // record into a file (the file branch conforms) while leaving a null or a plain record alone.
    for (const branch of schema.anyOf) {
      const revived = reviveArgument(value, branch);
      if (conformValue(revived, branch).ok) return revived;
    }
    return value;
  }

  // A file position: a literal `{ $ref, semanticKind? }` record (what an AI replays) becomes a real file.
  if (referenceKeyOf(schema) === FILE_KEY) {
    return fileFromRefRecord(value) ?? value;
  }

  // A `data` schema: revive the flat fields against the `value` sub-schema, keeping the constructor.
  const dataConstructor = dataConstructorOf(schema);
  if (dataConstructor !== undefined) {
    if (value.kind !== "record" || value.ctor === undefined) return value;
    const valueSchema = schema.properties?.[VALUE_KEY];
    if (valueSchema === undefined) return value;
    const revived = reviveArgument({ kind: "record", fields: value.fields }, valueSchema);
    if (revived.kind !== "record") return value;
    return { kind: "record", ctor: value.ctor, fields: revived.fields };
  }

  if (
    value.kind === "array" &&
    (schema.type === "array" || schema.items !== undefined || schema.prefixItems !== undefined)
  ) {
    return {
      kind: "array",
      elements: value.elements.map((element, index) => {
        const elementSchema = schema.prefixItems?.[index] ?? schema.items;
        return elementSchema === undefined ? element : reviveArgument(element, elementSchema);
      }),
    };
  }

  if (
    value.kind === "record" &&
    value.ctor === undefined &&
    (schema.type === "object" ||
      schema.properties !== undefined ||
      schema.additionalProperties !== undefined)
  ) {
    const tail =
      typeof schema.additionalProperties === "object" ? schema.additionalProperties : undefined;
    const fields: Record<string, Value> = Object.create(null);
    for (const [key, child] of Object.entries(value.fields)) {
      const propertySchema = schema.properties?.[key] ?? tail;
      fields[key] = propertySchema === undefined ? child : reviveArgument(child, propertySchema);
    }
    return { kind: "record", fields };
  }

  return value;
}

/** A plain `{ "$ref": id, semanticKind? }` record -> the file value it stands for, or `null` if it is not
 *  that shape (so a non-file value at a file position stays as-is for validation to reject). A `data`
 *  value is never a file handle (its `$ref` key would be escaped), so only a plain record qualifies. */
function fileFromRefRecord(value: Value): Value | null {
  if (value.kind !== "record" || value.ctor !== undefined) return null;
  const reference = value.fields[FILE_KEY];
  if (reference === undefined || reference.kind !== "string") return null;
  const semanticKindValue = value.fields[SEMANTIC_KIND_KEY];
  const semanticKind =
    semanticKindValue?.kind === "string" && semanticKindValue.value === "string"
      ? "string"
      : "file";
  return { kind: "ref", semanticKind, blobId: reference.value as BlobId };
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
    const bound = substitution.get(schema.$generic);
    if (bound === undefined) return schema;
    // An annotated generic parameter carries its description on the sentinel; the annotation site's
    // text survives the fill (and wins over any description the argument schema brought along).
    return schema.description === undefined ? bound : { ...bound, description: schema.description };
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
export function isUnconstrained(schema: JSONSchema): boolean {
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

/** The `$constructor` const of a `data` schema (its discriminator), or `undefined` for a plain object. */
function dataConstructorOf(schema: JSONSchema): string | undefined {
  const constructorSchema = schema.properties?.[CONSTRUCTOR_KEY];
  return typeof constructorSchema?.const === "string" ? constructorSchema.const : undefined;
}

/** The recursive check: appends any mismatches to `failures`. */
function conform(value: Value, schema: JSONSchema, path: string, failures: ConformFailure[]): void {
  // A residual generic placeholder constrains nothing (the callable was not instantiated at this
  // parameter; the static checker already bounded it).
  if (schema.$generic !== undefined) return;

  if (schema.not !== undefined) {
    // The compiler emits `not` only as `{"not": {}}` (never); check the general form anyway.
    const scratch: ConformFailure[] = [];
    conform(value, schema.not, path, scratch);
    if (scratch.length === 0) {
      failures.push({ path, message: "no value can satisfy this schema (never)" });
    }
    return;
  }

  if (schema.anyOf !== undefined) {
    for (const branch of schema.anyOf) {
      const scratch: ConformFailure[] = [];
      conform(value, branch, path, scratch);
      if (scratch.length === 0) return;
    }
    failures.push({
      path,
      message: `${describeValue(value)} does not match any variant of the expected union`,
    });
    return;
  }

  if (schema.const !== undefined) {
    // A blob-backed string's content is not readable synchronously (this walk is sync). A non-string
    // const can never equal a string, so reject. A *string* const, though, we accept unconditionally —
    // a KNOWN HOLE: a >4KB string satisfies any string `const` regardless of content. Left deliberately:
    // a >4KB literal-type const is degenerate, and the `$constructor` discriminator no longer routes
    // through here (it is checked via `value.ctor`, see `conformData`). Closing it would mean hashing the
    // const with the blob's algorithm and comparing to `ref.hash`.
    if (value.kind === "ref" && value.semanticKind === "string") {
      if (typeof schema.const !== "string") {
        failures.push({
          path,
          message: `${describeValue(value)} does not equal the expected constant`,
        });
      }
      return;
    }
    if (!valueEquals(value, jsonConstToValue(schema.const))) {
      failures.push({
        path,
        message: `${describeValue(value)} does not equal the expected constant`,
      });
    }
    return;
  }

  // A callable or a blob handle satisfies its `$`-keyed reference schema (and an unconstrained one);
  // any other constraint cannot hold for it.
  if (value.kind === "agent" || value.kind === "closure" || value.kind === "tool") {
    if (!(isUnconstrained(schema) || referenceKeyOf(schema) === AGENT_KEY)) {
      failures.push({ path, message: `expected ${describeSchema(schema)}, got a callable value` });
    }
    return;
  }
  if (value.kind === "ref" && value.semanticKind === "file") {
    if (!(isUnconstrained(schema) || referenceKeyOf(schema) === FILE_KEY)) {
      failures.push({ path, message: `expected ${describeSchema(schema)}, got a file handle` });
    }
    return;
  }

  // A `data` schema (nested `{ $constructor: {const}, value: {fields} }`) is checked against the value's
  // out-of-band constructor and flat fields, not by walking a literal `$constructor` property.
  const dataConstructor = dataConstructorOf(schema);
  if (dataConstructor !== undefined) {
    conformData(value, dataConstructor, schema, path, failures);
    return;
  }

  switch (schema.type) {
    case undefined:
      break;
    case "null":
      if (value.kind !== "null") typeMismatch(value, schema, path, failures);
      return;
    case "boolean":
      if (value.kind !== "boolean") typeMismatch(value, schema, path, failures);
      return;
    case "integer":
      if (value.kind !== "integer") typeMismatch(value, schema, path, failures);
      return;
    case "number":
      // `integer` is a subtype of `number`.
      if (value.kind !== "number" && value.kind !== "integer")
        typeMismatch(value, schema, path, failures);
      return;
    case "string":
      // A semantic-string blob is a string by value; its content constraints are unverifiable here.
      if (value.kind === "ref" && value.semanticKind === "string") return;
      if (value.kind !== "string") typeMismatch(value, schema, path, failures);
      return;
    case "array":
      if (value.kind !== "array") {
        typeMismatch(value, schema, path, failures);
        return;
      }
      conformArray(value, schema, path, failures);
      return;
    case "object":
      if (value.kind !== "record") {
        typeMismatch(value, schema, path, failures);
        return;
      }
      conformRecord(value, schema, path, failures);
      return;
  }

  // No `type` (an `{}`-any, possibly with stray keywords): apply whichever structural keywords are
  // present against a matching value; anything else passes.
  if (value.kind === "array" && (schema.items !== undefined || schema.prefixItems !== undefined)) {
    conformArray(value, schema, path, failures);
  } else if (
    value.kind === "record" &&
    (schema.properties !== undefined ||
      schema.required !== undefined ||
      schema.additionalProperties !== undefined)
  ) {
    conformRecord(value, schema, path, failures);
  }
}

/** Check a value against a `data` schema: its constructor must equal the discriminator const, and its
 *  fields must conform to the `value` sub-schema (an object schema). */
function conformData(
  value: Value,
  dataConstructor: string,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
): void {
  if (value.kind !== "record" || value.ctor === undefined) {
    failures.push({
      path,
      message: `expected a "${dataConstructor}" value, got ${describeValue(value)}`,
    });
    return;
  }
  if (String(value.ctor) !== dataConstructor) {
    failures.push({
      path,
      message: `expected a "${dataConstructor}" value, got a "${value.ctor}" value`,
    });
    return;
  }
  const valueSchema = schema.properties?.[VALUE_KEY];
  if (valueSchema !== undefined) {
    // The value's flat fields are the `value` wrapper's object; check them as a bare record.
    conform({ kind: "record", fields: value.fields }, valueSchema, path, failures);
  }
}

function typeMismatch(
  value: Value,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
): void {
  failures.push({
    path,
    message: `expected ${describeSchema(schema)}, got ${describeValue(value)}`,
  });
}

function conformArray(
  value: Extract<Value, { kind: "array" }>,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
): void {
  // A fixed tuple (`prefixItems`, no `items` tail) accepts exactly its length: too few or too many is a
  // mismatch. A homogeneous `items` array has no length bound.
  if (schema.prefixItems !== undefined && schema.items === undefined) {
    if (value.elements.length !== schema.prefixItems.length) {
      failures.push({
        path,
        message: `expected a tuple of ${schema.prefixItems.length} elements, got ${value.elements.length}`,
      });
      return;
    }
  } else if (
    schema.prefixItems !== undefined &&
    value.elements.length < schema.prefixItems.length
  ) {
    failures.push({
      path,
      message: `expected at least ${schema.prefixItems.length} elements, got ${value.elements.length}`,
    });
    return;
  }
  for (let index = 0; index < value.elements.length; index += 1) {
    const element = value.elements[index];
    if (element === undefined) continue;
    // A positional (tuple) schema wins; a homogeneous `items` applies to every element; an element past
    // the tuple positions of a `prefixItems`-with-`items` schema falls to `items`.
    const elementSchema = schema.prefixItems?.[index] ?? schema.items;
    if (elementSchema !== undefined) {
      conform(element, elementSchema, `${path}[${index}]`, failures);
    }
  }
}

function conformRecord(
  value: Extract<Value, { kind: "record" }>,
  schema: JSONSchema,
  path: string,
  failures: ConformFailure[],
): void {
  for (const [key, field] of Object.entries(value.fields)) {
    const propertySchema = schema.properties?.[key];
    if (propertySchema !== undefined) {
      conform(field, propertySchema, `${path}.${key}`, failures);
      continue;
    }
    // A key beyond the declared properties: closed (`false`) rejects it, a tail schema (`record[V]`)
    // constrains it, open (`true` / absent) passes it through.
    if (schema.additionalProperties === false) {
      failures.push({ path: `${path}.${key}`, message: "unexpected field" });
    } else if (typeof schema.additionalProperties === "object") {
      conform(field, schema.additionalProperties, `${path}.${key}`, failures);
    }
  }

  for (const required of schema.required ?? []) {
    // The `$constructor` / `$ref` / `$agent` reserved requireds are handled by the `data` and reference
    // paths above; a plain object schema's requireds are ordinary fields.
    if (required === CONSTRUCTOR_KEY || required === AGENT_KEY || required === FILE_KEY) continue;
    if (value.fields[required] === undefined) {
      failures.push({ path, message: `missing required field "${required}"` });
    }
  }
}

/** Lift a schema `const` (bare JSON) to a value for structural comparison, without the wire conventions
 *  (a const is a literal JSON scalar / array / object, not a tagged value). */
function jsonConstToValue(json: Json): Value {
  if (json === null) return { kind: "null" };
  switch (typeof json) {
    case "boolean":
      return { kind: "boolean", value: json };
    case "number":
      return Number.isInteger(json)
        ? { kind: "integer", value: json }
        : { kind: "number", value: json };
    case "string":
      return { kind: "string", value: json };
  }
  if (Array.isArray(json)) return { kind: "array", elements: json.map(jsonConstToValue) };
  const fields: Record<string, Value> = {};
  for (const [key, child] of Object.entries(json)) fields[key] = jsonConstToValue(child);
  return { kind: "record", fields };
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
    case "tool":
      return "a callable value";
    default:
      return `a value of type ${value.kind}`;
  }
}

function describeSchema(schema: JSONSchema): string {
  const dataConstructor = dataConstructorOf(schema);
  if (dataConstructor !== undefined) return `a "${dataConstructor}" value`;
  if (schema.type !== undefined) return `a value of type ${schema.type}`;
  if (referenceKeyOf(schema) === AGENT_KEY) return "a callable value";
  if (referenceKeyOf(schema) === FILE_KEY) return "a file handle";
  return "a conforming value";
}
