// The JSON document lift and the shared string reader. `prelude.json` models a JSON document as a PLAIN
// Katari value (a record / array / scalar tree — the "document shape"), not a dedicated tagged tree.
//
// `literalLift` moves bare `Json` into its document `Value` treating EVERY object as a record — no wire
// marker is interpreted. This is what a SCHEMA / metadata document needs: a `data` type's schema nests its
// fields under a `$katari_value` property and tags them with a `$katari_constructor` const, so those keys
// appear as ordinary property NAMES inside the schema, and the marker-interpreting value codec
// (`value/codec.ts`'s `jsonToValue`) would wrongly read the schema's `properties` map as a `data` value.
// `literalLift` keeps the whole tree literal, so a schema round-trips as the document it is.
//
// A JSON document that IS a value (a parsed AI reply, an external reply) instead goes through the value
// codec, which interprets the `$katari_` markers; there is no second document-specific wire step.

import type { Json } from "@katari-lang/types";
import type { ProjectId } from "../ids.js";
import type { BlobStore } from "../value/blob-store.js";
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

/** Lift bare JSON into its document `Value` — records / arrays / scalars, every object read as a record
 *  and every key kept exactly as written (no marker interpretation). A fraction-less number becomes an
 *  `integer` (JSON has one number type; the boundary splits on integer-ness). Used for schema / metadata
 *  documents, whose reserved-looking property names must stay literal. */
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
  // A prototype-less map, so a `__proto__` key is an ordinary field.
  const fields: Record<string, Value> = Object.create(null);
  for (const [key, child] of Object.entries(json)) {
    fields[key] = literalLift(child);
  }
  return { kind: "record", fields };
}
