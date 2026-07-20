// The `JSONSchema` ↔ `Json` bijection: the `description` overlay must survive both directions —
// it is how a parameter's `@"..."` annotation reaches `get_metadata` and the MCP listings.

import type { JSONSchema } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { jsonToSchema, schemaToJson } from "../src/runtime/value/schema-json.js";

describe("schemaToJson / jsonToSchema", () => {
  test("a property description round-trips", () => {
    const schema: JSONSchema = {
      type: "object",
      properties: { city: { type: "string", description: "The city name." } },
      required: ["city"],
      additionalProperties: false,
    };
    expect(jsonToSchema(schemaToJson(schema))).toEqual(schema);
  });

  test("a described any-schema round-trips as the bare description document", () => {
    const schema: JSONSchema = { description: "Anything goes." };
    expect(schemaToJson(schema)).toEqual({ description: "Anything goes." });
    expect(jsonToSchema({ description: "Anything goes." })).toEqual(schema);
  });
});
