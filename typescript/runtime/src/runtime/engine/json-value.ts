// The JSON boundary's runtime bridge. `prelude.json` models a JSON document as a PLAIN Katari value (a
// record / array / scalar tree — the "document shape"), not a dedicated tagged tree. This module holds the
// two literal walks that move a document between bare `Json` and the engine's `Value`, plus the wire
// encoder they compose with the value codec (`value/codec.ts`):
//
//   - `literalLift`:  bare `Json`  ->  document `Value`   (`parse`; lifting a schema document)
//   - `literalWrite`: document `Value`  ->  bare `Json`   (the flatten inside `stringify`)
//   - `encodeValue`:  any `Value`  ->  its WIRE form as a document `Value`   (the wire step inside `stringify`)
//
// LITERAL vs WIRE is the whole split. `literalLift` / `literalWrite` keep every object key exactly as
// written — `$constructor` / `$ref` are ordinary keys, never interpreted — so `parse` and a `stringify` over
// a document are a faithful round-trip. `encodeValue` applies the value wire conventions (a `data` value
// nests under `value`, a file / agent / closure becomes its reference object, a record escapes `$`-keys);
// `json.stringify` composes it with `literalWrite` (then un-escapes the keys) so it is TOTAL over every
// value — a document round-trips, a non-document renders its canonical handle form. integer vs number is
// preserved (the document value distinguishes them; bare JSON splits on `Number.isInteger` at the text
// boundary).
//
// A blob-backed string is materialised to text by `encodeValue` / `literalWrite` (a JSON document's string
// is text). `literalWrite` PANICS on a value that has no document form — a `file`, a callable, or a `data`
// value — an internal invariant, NOT a surface error: `json.stringify` runs `encodeValue` first, which turns
// any of those into a document, so the composed `stringify` is TOTAL and never reaches these throws. Privacy:
// these walks keep private subtree content (nothing here crosses a user boundary), and the prim layer's
// monotonic taint rule marks the whole result private whenever any input part is.

import type { Json } from "@katari-lang/types";
import type { ProjectId } from "../ids.js";
import type { BlobStore } from "../value/blob-store.js";
import {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  CONTEXT_KEY,
  DESCRIPTION_KEY,
  escapeRecordKey,
  FILE_KEY,
  GENERICS_KEY,
  genericsToJson,
  INPUT_SCHEMA_KEY,
  MODULE_KEY,
  OUTPUT_SCHEMA_KEY,
  REACTOR_KEY,
  SCOPE_KEY,
  SEMANTIC_KIND_KEY,
  SNAPSHOT_KEY,
  TOOL_KEY,
  unescapeRecordKey,
  VALUE_KEY,
} from "../value/codec.js";
import { schemaToJson } from "../value/schema-json.js";
import type { Value } from "../value/types.js";

/** Reads a string value's content: inline directly, a semantic-string blob through the store. */
export type StringReader = (value: Value) => Promise<string>;

/** The one shared `StringReader` implementation over a blob store: an inline string reads directly,
 *  a semantic-string blob decodes from its stored bytes. Both the prim layer and the reactors that
 *  lower document values (the mcp reactor's direct call) build their readers here, so the two paths can
 *  never diverge on what "read a string" means. */
export function blobStoreStringReader(projectId: ProjectId, blobs: BlobStore): StringReader {
  return async (value: Value): Promise<string> => {
    if (value.kind === "string") return value.value;
    if (value.kind === "ref" && value.semanticKind === "string") {
      const bytes = await blobs.get(projectId, value.blobId);
      return new TextDecoder().decode(bytes);
    }
    throw new Error(`expected a string, got ${value.kind}`);
  };
}

function requireFinite(value: number): number {
  if (!Number.isFinite(value)) {
    throw new Error("a non-finite number (NaN / Infinity) has no JSON representation");
  }
  return value;
}

const textValue = (value: string): Value => ({ kind: "string", value });

/** Un-escape the `$$`-doubled object keys of a wire document back to their single-`$` originals — what
 *  `stringify` applies to `encodeValue`'s output so the `$$` escape NEVER surfaces (a value-plane `$x` key
 *  displays as `$x`). A single-`$` key — a real wire discriminator (`$constructor` / `$ref` / `$agent`)
 *  or an external literal — is left as-is (`unescapeRecordKey` strips only a doubled `$`), so the wire
 *  tags still read. The escape thus lives ONLY inside the codec's persisted bytes, never at any surface.
 *  (A leaf / scalar passes through; only object keys are touched.) */
export function unescapeWireKeys(json: Json): Json {
  if (json === null || typeof json !== "object") return json;
  if (Array.isArray(json)) return json.map(unescapeWireKeys);
  const out: { [key: string]: Json } = Object.create(null);
  for (const [key, value] of Object.entries(json)) {
    out[unescapeRecordKey(key)] = unescapeWireKeys(value);
  }
  return out;
}

// ─── bare Json -> document Value (`parse`, literal lift) ────────────────────────────────────────────

/** Lift bare JSON into its document `Value` — records / arrays / scalars, every key kept exactly as
 *  written (no `$` interpretation). A fraction-less number becomes an `integer` (JSON has one number
 *  type; the boundary splits on integer-ness). */
export function literalLift(json: Json): Value {
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
  if (Array.isArray(json)) return { kind: "array", elements: json.map(literalLift) };
  // A prototype-less map, so a `__proto__` / `$`-key is an ordinary field.
  const fields: Record<string, Value> = Object.create(null);
  for (const [key, child] of Object.entries(json)) {
    fields[key] = literalLift(child);
  }
  return { kind: "record", fields };
}

// ─── document Value -> bare Json (`stringify`, literal write) ────────────────────────────────────────

/** Flatten a document `Value` back to bare JSON, keys unchanged. A value that is NOT a document shape —
 *  a `file`, a callable, or a `data` value (a ctor-tagged record) — has no document text, so it throws (an
 *  internal invariant: `json.stringify` runs `encodeValue` first, so it only ever hands this a document). A
 *  blob-backed string materialises to its text (a JSON document's string is text). */
export async function literalWrite(value: Value, readString: StringReader): Promise<Json> {
  switch (value.kind) {
    case "null":
      return null;
    case "boolean":
      return value.value;
    case "integer":
    case "number":
      return requireFinite(value.value);
    case "string":
      return value.value;
    case "ref":
      if (value.semanticKind === "string") return await readString(value);
      throw new Error(
        "a file value has no JSON document form (embed it with json.encode, or send it in an http.json body)",
      );
    case "array": {
      const out: Json[] = [];
      for (const element of value.elements) {
        out.push(await literalWrite(element, readString));
      }
      return out;
    }
    case "record": {
      if (value.ctor !== undefined) {
        throw new Error(
          `a data value ("${String(value.ctor)}") has no JSON document form (embed it with json.encode)`,
        );
      }
      const out: { [key: string]: Json } = Object.create(null);
      for (const [key, child] of Object.entries(value.fields)) {
        out[key] = await literalWrite(child, readString);
      }
      return out;
    }
    case "agent":
    case "closure":
    case "tool":
      throw new Error("a callable value has no JSON document form (embed it with json.encode)");
  }
}

// ─── Value -> document Value (`json.encode`) ────────────────────────────────────────────────────────

/**
 * Turn any runtime value into its WIRE form, as a document `Value` (`value/codec.ts` conventions): a
 * `data` value nests its fields under `value`, a record escapes `$`-keys, a file / agent / closure / tool
 * becomes its reference object, a blob-backed string is materialised to text. A closure's captured scope
 * ids ride along so it reconstructs. The value codec's `jsonToValue` (after `literalWrite` flattens) inverts
 * this.
 */
export async function encodeValue(value: Value, readString: StringReader): Promise<Value> {
  switch (value.kind) {
    case "null":
      return { kind: "null" };
    case "boolean":
      return { kind: "boolean", value: value.value };
    case "integer":
      return { kind: "integer", value: value.value };
    case "number":
      return { kind: "number", value: requireFinite(value.value) };
    case "string":
      return { kind: "string", value: value.value };
    case "ref": {
      if (value.semanticKind === "string") return textValue(await readString(value));
      // A file's wire form is identity only ({ $ref, semanticKind }); metadata lives on the blob row.
      const fields: Record<string, Value> = Object.create(null);
      fields[FILE_KEY] = textValue(value.blobId);
      fields[SEMANTIC_KIND_KEY] = textValue(value.semanticKind);
      return { kind: "record", fields };
    }
    case "agent": {
      const fields: Record<string, Value> = Object.create(null);
      fields[AGENT_KEY] = textValue(String(value.name));
      fields[SNAPSHOT_KEY] = textValue(String(value.snapshot));
      if (value.generics !== undefined) {
        fields[GENERICS_KEY] = literalLift(genericsToJson(value.generics));
      }
      return { kind: "record", fields };
    }
    case "closure": {
      const fields: Record<string, Value> = Object.create(null);
      fields[CLOSURE_KEY] = { kind: "integer", value: value.blockId };
      fields[SCOPE_KEY] = { kind: "integer", value: value.scopeId };
      fields[SNAPSHOT_KEY] = textValue(String(value.snapshot));
      fields[MODULE_KEY] = textValue(value.module);
      if (value.generics !== undefined) {
        fields[GENERICS_KEY] = literalLift(genericsToJson(value.generics));
      }
      return { kind: "record", fields };
    }
    case "tool": {
      const fields: Record<string, Value> = Object.create(null);
      fields[TOOL_KEY] = textValue(value.name);
      fields[REACTOR_KEY] = textValue(value.reactor);
      fields[CONTEXT_KEY] = await encodeValue(value.context, readString);
      fields[SNAPSHOT_KEY] = textValue(String(value.snapshot));
      fields[DESCRIPTION_KEY] = textValue(value.description);
      fields[INPUT_SCHEMA_KEY] = literalLift(schemaToJson(value.inputSchema));
      if (value.outputSchema !== undefined) {
        fields[OUTPUT_SCHEMA_KEY] = literalLift(schemaToJson(value.outputSchema));
      }
      return { kind: "record", fields };
    }
    case "array": {
      const elements: Value[] = [];
      for (const element of value.elements) {
        elements.push(await encodeValue(element, readString));
      }
      return { kind: "array", elements };
    }
    case "record": {
      const fields: Record<string, Value> = Object.create(null);
      for (const [key, child] of Object.entries(value.fields)) {
        fields[escapeRecordKey(key)] = await encodeValue(child, readString);
      }
      if (value.ctor === undefined) return { kind: "record", fields };
      // A `data` value nests its fields under `value`, keeping the discriminator disjoint from them.
      const wrapper: Record<string, Value> = Object.create(null);
      wrapper[CONSTRUCTOR_KEY] = textValue(String(value.ctor));
      wrapper[VALUE_KEY] = { kind: "record", fields };
      return { kind: "record", fields: wrapper };
    }
  }
}
