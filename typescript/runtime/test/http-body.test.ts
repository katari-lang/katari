// The `http.json` body materialiser, driven through the exact production pipeline: a program's value
// tree (the `http.json` data value) is serialised by the http reactor with `valueToJson(…, "reveal")`
// — which ESCAPES every record key beginning with `$` (a literal `$ref` rides as `$$ref`) — and the
// transport materialises that wire form at the send boundary (`materializeBody`). The tests pin the
// two halves of the tree's wire contract:
//   (a) a record's literal `$`-keys (a JSON Schema's `$ref` / `$defs` / `$schema` — what an external
//       MCP tool schema legitimately carries) reach the SERVER under their original single-`$` names,
//       so the materialiser must UN-escape what the value codec escaped;
//   (b) a `file` leaf — and only a `file` leaf — becomes the base64 of its bytes, resolved from the
//       blob store only here;
//   (c) both in one tree: the escaped-literal-key record and the real `$ref` file handle are the same
//       object shape on the wire, and the materialiser must keep telling them apart.

import { createAgentName, type Json } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { type HttpBlobResolver, materializeBody } from "../src/runtime/external/http-body.js";
import type { BlobId } from "../src/runtime/ids.js";
import { valueToJson } from "../src/runtime/value/codec.js";
import type { Value } from "../src/runtime/value/types.js";

const str = (value: string): Value => ({ kind: "string", value });
const record = (fields: Record<string, Value>): Value => ({ kind: "record", fields });

/** The `http.json` body sum variant wrapping a value tree — `http.fetch`'s `body` argument. */
function jsonBody(tree: Value): Value {
  return {
    kind: "record",
    ctor: createAgentName("prelude.http.json"),
    fields: { value: tree },
  };
}

/** Serialise the body the way the http reactor does before handing it to the transport. */
function wireFormOf(body: Value): Json {
  return valueToJson(body, "reveal");
}

/** Parse the materialised body text back into a document for structural assertions. */
async function materializedDocument(
  body: Value,
  resolve: HttpBlobResolver | null,
): Promise<Json> {
  const materialized = await materializeBody(wireFormOf(body), resolve);
  expect(typeof materialized.body).toBe("string");
  expect(materialized.contentType).toEqual({ value: "application/json", authoritative: false });
  return JSON.parse(materialized.body as string) as Json;
}

const BLOB_ID = "blob-image-1" as BlobId;
const IMAGE_BYTES = new TextEncoder().encode("fake-png-bytes");

/** A resolver serving the one test blob (asserting no other id is ever asked for). */
const resolveImage: HttpBlobResolver = async (blobId) => {
  expect(blobId).toBe(BLOB_ID);
  return { bytes: IMAGE_BYTES, contentType: "image/png" };
};

describe("http.json body materialisation", () => {
  test("a record's literal $-keys reach the wire under their original names", async () => {
    // A tool schema as an AI provider request embeds it: literal `$schema` / `$defs` / `$ref` keys.
    // The value codec escapes them to `$$…` on the reactor wire; the server must see the originals.
    const tree = record({
      name: str("lookup"),
      input_schema: record({
        $schema: str("https://json-schema.org/draft/2020-12/schema"),
        $defs: record({ item: record({ type: str("integer") }) }),
        $ref: str("#/$defs/item"),
      }),
    });
    // The wire form escapes: pin the intermediate too, so a future escaping change re-derives this
    // test. (The `http.json` data value nests its one `value` field under the wire's `value` wrapper.)
    const wire = wireFormOf(jsonBody(tree)) as {
      value: { value: { input_schema: { [key: string]: Json } } };
    };
    expect(Object.keys(wire.value.value.input_schema).sort()).toEqual(["$$defs", "$$ref", "$$schema"]);

    const document = await materializedDocument(jsonBody(tree), null);
    expect(document).toEqual({
      name: "lookup",
      input_schema: {
        $schema: "https://json-schema.org/draft/2020-12/schema",
        $defs: { item: { type: "integer" } },
        $ref: "#/$defs/item",
      },
    });
  });

  test("a file leaf becomes the base64 of its blob's bytes", async () => {
    const tree = record({
      source: record({
        media_type: str("image/png"),
        data: { kind: "ref", semanticKind: "file", blobId: BLOB_ID },
      }),
    });
    const document = await materializedDocument(jsonBody(tree), resolveImage);
    expect(document).toEqual({
      source: {
        media_type: "image/png",
        data: Buffer.from(IMAGE_BYTES).toString("base64"),
      },
    });
  });

  test("literal $-keys and a real file handle coexist in one tree", async () => {
    // The provider request that motivated the un-escape: a tools list whose schema carries literal
    // `$ref` / `$defs` keys AND an image block whose `data` slot is a real file value. On the wire
    // both are objects with `$`-keys ($$-escaped literal vs the handle's single-$ `$ref`); the
    // materialiser must base64 exactly the handle and un-escape exactly the record.
    const tree = record({
      tools: {
        kind: "array",
        elements: [
          record({
            name: str("lookup"),
            input_schema: record({
              $ref: str("#/$defs/item"),
              $defs: record({ item: record({ type: str("string") }) }),
            }),
          }),
        ],
      },
      content: record({
        data: { kind: "ref", semanticKind: "file", blobId: BLOB_ID },
      }),
    });
    const document = await materializedDocument(jsonBody(tree), resolveImage);
    expect(document).toEqual({
      tools: [
        {
          name: "lookup",
          input_schema: {
            $ref: "#/$defs/item",
            $defs: { item: { type: "string" } },
          },
        },
      ],
      content: {
        data: Buffer.from(IMAGE_BYTES).toString("base64"),
      },
    });
  });
});
