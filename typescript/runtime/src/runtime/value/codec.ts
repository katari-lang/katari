// Value codec + scalar helpers. Three jobs:
//   - lift an IR `Literal` into a runtime `Value` (`literalToValue`);
//   - convert across the HTTP / FFI value boundary, where the wire speaks bare `Json` and the engine
//     speaks the tagged `Value` model (`jsonToValue` / `valueToJson`);
//   - the value-level operations the engine and pattern matcher need (`valueEquals`, `valueMatchesTag`).
//
// `jsonToValue` / `valueToJson` are a total, schema-independent bijection: every `Value` has one
// unambiguous JSON form and back, so no schema is consulted here. Validation is a separate, strict pass
// (`./validation.ts`) — decode never rewrites to fit a schema. The wire conventions those two walks obey
// (the reserved `$katari_` keys, variant detection) are defined in `@katari-lang/types` (`wire.ts`) and
// re-exported below, so every reader of the convention shares one source.
//
// A bare JSON number is ambiguous between the runtime's `integer` and `number`; at the untyped wire
// boundary we split on `Number.isInteger`. Inside the engine the distinction is carried explicitly, so
// this heuristic only ever applies to values entering from outside (a run argument, an answered
// escalation), never to values already in flight. A blob-backed string surfaces as its `$katari_ref`
// handle here (the value-transport boundary hands out a handle, not the bytes).

import {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  CONTEXT_KEY,
  createAgentName,
  DESCRIPTION_KEY,
  FILE_KEY,
  GENERICS_KEY,
  type GenericArgumentSchema,
  INPUT_SCHEMA_KEY,
  type Json,
  type Literal,
  MODULE_KEY,
  OUTPUT_SCHEMA_KEY,
  REACTOR_KEY,
  REDACTED_KEY,
  SCOPE_KEY,
  SEMANTIC_KIND_KEY,
  SNAPSHOT_KEY,
  TOOL_KEY,
  type TypeTag,
  VALUE_KEY,
  wireKindOf,
} from "@katari-lang/types";
import { type BlobId, toScopeId, toSnapshotId } from "../ids.js";
import { jsonToRequests, jsonToSchema, requestsToJson, schemaToJson } from "./schema-json.js";
import {
  type AgentValue,
  type ClosureValue,
  type GenericSubstitution,
  type SemanticKind,
  toToolReactorName,
  type Value,
} from "./types.js";

// ─── the wire conventions ─────────────────────────────────────────────────────────────────────────
//
// Defined in `@katari-lang/types` (`wire.ts`) so this codec and the FFI port (`@katari-lang/port`) share one
// source and cannot drift. Re-exported here so this file stays the runtime's convention hub — the `json`
// data-type codec (`engine/json-value.ts`) and the validator read the reserved keys from here.
export {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  CONTEXT_KEY,
  DESCRIPTION_KEY,
  FILE_KEY,
  GENERICS_KEY,
  INPUT_SCHEMA_KEY,
  MODULE_KEY,
  OUTPUT_SCHEMA_KEY,
  REACTOR_KEY,
  REDACTED_KEY,
  SCOPE_KEY,
  SEMANTIC_KIND_KEY,
  SNAPSHOT_KEY,
  TOOL_KEY,
  VALUE_KEY,
  type WireKind,
  wireKindOf,
} from "@katari-lang/types";

/** Serialise a callable value's `generics` (a `foo[T]` instantiation) so a `$katari_agent` / `$katari_closure`
 *  reference round-trips it. Each argument is a type schema or an effect's request list. */
export function genericsToJson(generics: GenericSubstitution): Json {
  const out: { [name: string]: Json } = {};
  for (const [name, argument] of Object.entries(generics)) {
    out[name] =
      argument.kind === "type"
        ? { kind: "type", schema: schemaToJson(argument.schema) }
        : { kind: "requests", requests: requestsToJson(argument.requests) };
  }
  return out;
}

/** Reconstruct a `generics` substitution from its JSON form (the inverse of `genericsToJson`). */
export function genericsFromJson(json: Json): GenericSubstitution {
  if (typeof json !== "object" || json === null || Array.isArray(json)) return {};
  const generics: GenericSubstitution = {};
  for (const [name, entry] of Object.entries(json)) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) continue;
    const argument = genericArgumentFromJson(entry);
    if (argument !== undefined) generics[name] = argument;
  }
  return generics;
}

function genericArgumentFromJson(entry: {
  [key: string]: Json;
}): GenericArgumentSchema | undefined {
  if (entry.kind === "requests") {
    return { kind: "requests", requests: jsonToRequests(entry.requests ?? []) };
  }
  if (entry.kind === "type") {
    return { kind: "type", schema: jsonToSchema(entry.schema ?? {}) };
  }
  return undefined;
}

/**
 * How `valueToJson` treats a private (`value.private`) node:
 *   - `redact` (the default) — replace the private subtree with `{ "$katari_redacted": true }`. This is the
 *     fail-closed boundary: a run result, an open escalation's question, anything a user could observe —
 *     a caller that forgets to choose a policy still does not leak a secret.
 *   - `reveal` — emit the real value. An explicit opt-in for the one allowed sink, the FFI sidecar (a secret
 *     API key flows to its external call).
 * Redaction is structural: a private field inside a public record collapses in place, public siblings survive.
 */
export type PrivatePolicy = "reveal" | "redact";

/** Lift an IR literal (the payload of `loadLiteral` / a `PatternLiteral`) into a runtime value. */
export function literalToValue(literal: Literal): Value {
  switch (literal.kind) {
    case "null":
      return { kind: "null" };
    case "boolean":
      return { kind: "boolean", value: literal.value };
    case "integer":
      return { kind: "integer", value: literal.value };
    case "number":
      return { kind: "number", value: literal.value };
    case "string":
      return { kind: "string", value: literal.value };
  }
}

// ─── bare Json → Value (façade / FFI input boundary) ─────────────────────────────────────────────

/** Bare wire JSON -> tagged runtime value. Numbers split on integer-ness; objects dispatch on their
 *  reserved discriminator key (`./wire.ts`). A total inverse of `valueToJson` (reveal). */
export function jsonToValue(json: Json): Value {
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
  if (Array.isArray(json)) {
    return { kind: "array", elements: json.map(jsonToValue) };
  }
  switch (wireKindOf((key) => Object.hasOwn(json, key))) {
    case "data":
      return dataFromJson(json);
    case "file":
      return fileFromJson(json);
    case "agent":
      return agentFromJson(json);
    case "closure":
      return closureFromJson(json);
    case "tool":
      return toolFromJson(json);
    case "redacted":
      // `$katari_redacted` marks content the `redact` policy withheld — it was never encodable, so it is not
      // decodable either. Reaching it means feeding a redacted document back in; fail loudly.
      throw new Error(
        "a redacted value cannot be decoded (its content was withheld at a boundary)",
      );
    case undefined:
      return { kind: "record", fields: recordFieldsFromJson(json) };
  }
}

/** Decode a bare JSON object's entries into record fields, keys verbatim, into a prototype-less map (so a
 *  `__proto__` key is an ordinary own field, never a prototype write). */
function recordFieldsFromJson(json: { [key: string]: Json }): Record<string, Value> {
  const fields: Record<string, Value> = Object.create(null);
  for (const [key, child] of Object.entries(json)) {
    fields[key] = jsonToValue(child);
  }
  return fields;
}

/** `{ "$katari_constructor": name, "$katari_value": { …fields } }` -> a tagged `data` value. */
function dataFromJson(json: { [key: string]: Json }): Value {
  const constructorTag = json[CONSTRUCTOR_KEY];
  const valueObject = json[VALUE_KEY];
  if (typeof constructorTag !== "string") {
    throw new Error("a data value's $katari_constructor must be a string");
  }
  const fields =
    typeof valueObject === "object" && valueObject !== null && !Array.isArray(valueObject)
      ? recordFieldsFromJson(valueObject)
      : Object.create(null);
  return { kind: "record", fields, ctor: createAgentName(constructorTag) };
}

/** Reconstruct a blob `ref` from a `{ "$katari_ref": blobId, $katari_semantic_kind? }` handle. The handle is
 *  identity only — a bare `$katari_ref` (what an AI replays) suffices; the semantic kind defaults to `file` (the engine
 *  always writes it, so a missing one means a hand-written handle, and those are files). Any other
 *  field a wire happens to carry (an old full handle, a model's copy) is ignored: metadata lives on
 *  the blob's row, never on the value. */
function fileFromJson(json: { [key: string]: Json }): Value {
  const blobId = json[FILE_KEY];
  if (typeof blobId !== "string") {
    throw new Error("a file handle must carry a string $katari_ref");
  }
  const semanticKind: SemanticKind = json[SEMANTIC_KIND_KEY] === "string" ? "string" : "file";
  return { kind: "ref", semanticKind, blobId: blobId as BlobId };
}

/** `{ "$katari_agent": name, "$katari_snapshot": …, "$katari_generics"? }` -> a top-level agent reference value. */
function agentFromJson(json: { [key: string]: Json }): Value {
  const name = json[AGENT_KEY];
  const snapshot = json[SNAPSHOT_KEY];
  if (typeof name !== "string" || typeof snapshot !== "string") {
    throw new Error(
      "an agent reference must carry a string $katari_agent name and a string snapshot",
    );
  }
  const agent: AgentValue = {
    kind: "agent",
    name: createAgentName(name),
    snapshot: toSnapshotId(snapshot),
  };
  const generics = json[GENERICS_KEY];
  return generics !== undefined ? { ...agent, generics: genericsFromJson(generics) } : agent;
}

/** `{ "$katari_closure": blockId, "$katari_scope_id": …, "$katari_snapshot": …, "$katari_module": …, "$katari_generics"? }` -> a closure value. */
function closureFromJson(json: { [key: string]: Json }): Value {
  const blockId = json[CLOSURE_KEY];
  const scopeId = json[SCOPE_KEY];
  const snapshot = json[SNAPSHOT_KEY];
  const module = json[MODULE_KEY];
  if (
    typeof blockId !== "number" ||
    typeof scopeId !== "number" ||
    typeof snapshot !== "string" ||
    typeof module !== "string"
  ) {
    throw new Error(
      "a closure reference must carry a numeric $katari_closure/$katari_scope_id and string snapshot/module",
    );
  }
  const closure: ClosureValue = {
    kind: "closure",
    blockId,
    scopeId: toScopeId(scopeId),
    snapshot: toSnapshotId(snapshot),
    module,
  };
  const generics = json[GENERICS_KEY];
  return generics !== undefined ? { ...closure, generics: genericsFromJson(generics) } : closure;
}

/** `{ "$katari_tool": name, "$katari_reactor", "$katari_context", "$katari_snapshot", "$katari_description", "$katari_input_schema", "$katari_output_schema"? }`
 *  -> a tool value (a reactor-backed agent). */
function toolFromJson(json: { [key: string]: Json }): Value {
  const name = json[TOOL_KEY];
  const reactor = json[REACTOR_KEY];
  const description = json[DESCRIPTION_KEY];
  const snapshot = json[SNAPSHOT_KEY];
  const context = json[CONTEXT_KEY];
  if (
    typeof name !== "string" ||
    typeof reactor !== "string" ||
    typeof description !== "string" ||
    typeof snapshot !== "string" ||
    context === undefined
  ) {
    throw new Error(
      "a tool must carry a string $katari_tool name, a string reactor, a string description, a string snapshot, and a context",
    );
  }
  const tool: Value = {
    kind: "tool",
    // The wire is untrusted, so the backing-reactor name is narrowed here — the decode boundary —
    // which lets the dispatch route on the field without a runtime check.
    reactor: toToolReactorName(reactor),
    name,
    description,
    context: jsonToValue(context),
    snapshot: toSnapshotId(snapshot),
    inputSchema: jsonToSchema(json[INPUT_SCHEMA_KEY] ?? {}),
  };
  const outputSchema = json[OUTPUT_SCHEMA_KEY];
  return outputSchema === undefined ? tool : { ...tool, outputSchema: jsonToSchema(outputSchema) };
}

// ─── Value → bare Json (façade / FFI output boundary) ────────────────────────────────────────────

/**
 * Tagged runtime value -> bare wire JSON. The `policy` decides what happens at a private node: `redact`
 * (the default, fail-closed) collapses the private subtree to `{ "$katari_redacted": true }` for any user-facing
 * boundary; `reveal` emits the real value — an explicit opt-in for the FFI sidecar, the one allowed sink.
 * A blob ref surfaces as its `$katari_ref` descriptor (not its bytes — download is a separate path). The total
 * inverse of `jsonToValue` (under `reveal`).
 */
export function valueToJson(value: Value, policy: PrivatePolicy = "redact"): Json {
  if (policy === "redact" && value.private === true) {
    return { [REDACTED_KEY]: true };
  }
  switch (value.kind) {
    case "null":
      return null;
    case "boolean":
      return value.value;
    case "integer":
    case "number":
      if (!Number.isFinite(value.value)) {
        throw new Error("a non-finite number (NaN / Infinity) has no JSON representation");
      }
      return value.value;
    case "string":
      return value.value;
    case "array":
      return value.elements.map((element) => valueToJson(element, policy));
    case "record": {
      const fields = recordFieldsToJson(value.fields, policy);
      if (value.ctor === undefined) return fields;
      // A `data` value nests its fields under `value`, keeping the discriminator disjoint from them.
      const out: { [key: string]: Json } = Object.create(null);
      out[CONSTRUCTOR_KEY] = value.ctor;
      out[VALUE_KEY] = fields;
      return out;
    }
    case "ref": {
      // A file / blob handle: identity only. Metadata (size / hash / contentType) lives on the blob's
      // row — a wire reader that needs it asks the files API; a program asks the `prelude.files` prims.
      const out: { [key: string]: Json } = Object.create(null);
      out[FILE_KEY] = value.blobId;
      out[SEMANTIC_KIND_KEY] = value.semanticKind;
      return out;
    }
    case "agent": {
      const out: { [key: string]: Json } = Object.create(null);
      out[AGENT_KEY] = value.name;
      out[SNAPSHOT_KEY] = value.snapshot;
      if (value.generics !== undefined) out[GENERICS_KEY] = genericsToJson(value.generics);
      return out;
    }
    case "closure": {
      // A closure carries engine-local ids (its captured scope must still exist to be callable); they
      // round-trip so a closure returned to / from the JSON boundary reconstructs.
      const out: { [key: string]: Json } = Object.create(null);
      out[CLOSURE_KEY] = value.blockId;
      out[SCOPE_KEY] = value.scopeId;
      out[SNAPSHOT_KEY] = value.snapshot;
      out[MODULE_KEY] = value.module;
      if (value.generics !== undefined) out[GENERICS_KEY] = genericsToJson(value.generics);
      return out;
    }
    case "tool": {
      const out: { [key: string]: Json } = Object.create(null);
      out[TOOL_KEY] = value.name;
      out[REACTOR_KEY] = value.reactor;
      out[CONTEXT_KEY] = valueToJson(value.context, policy);
      out[SNAPSHOT_KEY] = value.snapshot;
      out[DESCRIPTION_KEY] = value.description;
      out[INPUT_SCHEMA_KEY] = schemaToJson(value.inputSchema);
      if (value.outputSchema !== undefined)
        out[OUTPUT_SCHEMA_KEY] = schemaToJson(value.outputSchema);
      return out;
    }
  }
}

/** Encode record fields to a bare JSON object, keys verbatim, into a prototype-less map (so a
 *  `__proto__` field is an ordinary own key, not a prototype write). */
function recordFieldsToJson(
  fields: Record<string, Value>,
  policy: PrivatePolicy,
): { [key: string]: Json } {
  const out: { [key: string]: Json } = Object.create(null);
  for (const [key, child] of Object.entries(fields)) {
    out[key] = valueToJson(child, policy);
  }
  return out;
}

// ─── value-level operations ──────────────────────────────────────────────────────────────────────

/**
 * Structural equality for `==` and `PatternLiteral` matching. Scalars compare by value; records
 * compare key-wise, arrays positionally. A blob ref compares by IDENTITY (same blob id) — a file is a
 * resource, not a literal, so two uploads of the same bytes are distinct files. The one construct
 * whose equality must stay structural is a promoted large *string*; that promotion does not exist
 * yet, and its precondition is content-addressed blob ids (blobId = content hash), which makes this
 * same identity compare structural for strings too (see docs/2026-07-09-slim-blob-ref.md).
 */
export function valueEquals(left: Value, right: Value): boolean {
  switch (left.kind) {
    case "null":
      return right.kind === "null";
    case "boolean":
      return right.kind === "boolean" && left.value === right.value;
    case "integer":
      return right.kind === "integer" && left.value === right.value;
    case "number":
      return right.kind === "number" && left.value === right.value;
    case "string":
      return right.kind === "string" && left.value === right.value;
    case "ref":
      return (
        right.kind === "ref" &&
        left.semanticKind === right.semanticKind &&
        left.blobId === right.blobId
      );
    case "array": {
      if (right.kind !== "array" || left.elements.length !== right.elements.length) return false;
      for (let index = 0; index < left.elements.length; index += 1) {
        const leftElement = left.elements[index];
        const rightElement = right.elements[index];
        if (leftElement === undefined || rightElement === undefined) return false;
        if (!valueEquals(leftElement, rightElement)) return false;
      }
      return true;
    }
    case "record": {
      if (right.kind !== "record" || left.ctor !== right.ctor) return false;
      const leftEntries = Object.entries(left.fields);
      if (leftEntries.length !== Object.keys(right.fields).length) return false;
      for (const [key, leftValue] of leftEntries) {
        const rightValue = right.fields[key];
        if (rightValue === undefined || !valueEquals(leftValue, rightValue)) return false;
      }
      return true;
    }
    // Callable identity is not value-comparable; two callables are equal only as the same reference.
    case "closure":
      return right.kind === "closure" && left === right;
    case "agent":
      return right.kind === "agent" && left === right;
    case "tool":
      return right.kind === "tool" && left === right;
  }
}

/**
 * Whether a value satisfies a `T(pattern)` type-filter tag (mirrors IR `TypeTag`). Subtyping is folded
 * in: `number` accepts an `integer`; `string` accepts both an inline string and a semantic-string blob;
 * `agent` accepts a closure or an agent reference.
 */
export function valueMatchesTag(value: Value, tag: TypeTag): boolean {
  switch (tag) {
    case "null":
      return value.kind === "null";
    case "boolean":
      return value.kind === "boolean";
    case "integer":
      return value.kind === "integer";
    case "number":
      return value.kind === "number" || value.kind === "integer";
    case "string":
      return value.kind === "string" || (value.kind === "ref" && value.semanticKind === "string");
    case "file":
      return value.kind === "ref" && value.semanticKind === "file";
    case "array":
      return value.kind === "array";
    case "record":
      return value.kind === "record";
    case "agent":
      return value.kind === "closure" || value.kind === "agent" || value.kind === "tool";
  }
}
