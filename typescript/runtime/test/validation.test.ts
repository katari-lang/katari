// The schema-conformance walk (`conformValue`): the delegate boundary's argument check, now a *pure,
// strict* pass separate from the codec — it only checks, never rewrites (no `$constructor` repair). Covers
// the value-model foldbacks (integer-as-number subtyping, blob-string / file / callable reference schemas),
// nested `data` schemas, unions, tuples (including over-length rejection), closed records, and generics.

import { createAgentName, type JSONSchema } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { jsonToValue } from "../src/runtime/value/codec.js";
import type { BlobId, ScopeId, SnapshotId } from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";
import { conformValue, fillGenericSchema, typeSubstitutionOf } from "../src/runtime/value/validation.js";

const SNAPSHOT = "snapshot-validation" as SnapshotId;

function str(value: string): Value {
  return { kind: "string", value };
}

function int(value: number): Value {
  return { kind: "integer", value };
}

function record(fields: Record<string, Value>, ctor?: string): Value {
  return ctor !== undefined
    ? { kind: "record", fields, ctor: createAgentName(ctor) }
    : { kind: "record", fields };
}

const GREETER_INPUT: JSONSchema = {
  type: "object",
  properties: { name: { type: "string" } },
  required: ["name"],
  additionalProperties: true,
};

describe("conformValue", () => {
  test("accepts a matching record", () => {
    expect(conformValue(record({ name: str("alice") }), GREETER_INPUT).ok).toBe(true);
  });

  test("rejects a missing required field with a path and no value content", () => {
    const result = conformValue(record({ other: str("s3cret") }), GREETER_INPUT);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.failures[0]?.message).toContain('missing required field "name"');
      expect(JSON.stringify(result.failures)).not.toContain("s3cret");
    }
  });

  test("rejects a field of the wrong type, naming the path", () => {
    const result = conformValue(record({ name: int(3) }), GREETER_INPUT);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failures[0]?.path).toBe("$.name");
  });

  test("an integer satisfies a number schema; a fraction does not satisfy integer", () => {
    expect(conformValue(int(3), { type: "number" }).ok).toBe(true);
    expect(conformValue({ kind: "number", value: 1.5 }, { type: "integer" }).ok).toBe(false);
  });

  test("a semantic-string blob ref satisfies a string schema", () => {
    const ref: Value = {
      kind: "ref",
      semanticKind: "string",
      blobId: "blob-1" as BlobId,
      hash: "h",
      size: 10,
    };
    expect(conformValue(ref, { type: "string" }).ok).toBe(true);
  });

  test("a file ref satisfies the $ref reference schema and nothing narrower", () => {
    const file: Value = {
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-2" as BlobId,
      hash: "h",
      size: 10,
    };
    const fileSchema: JSONSchema = {
      type: "object",
      properties: { $ref: {} },
      required: ["$ref"],
      additionalProperties: true,
    };
    expect(conformValue(file, fileSchema).ok).toBe(true);
    expect(conformValue(file, { type: "string" }).ok).toBe(false);
  });

  test("an agent value satisfies the $agent reference schema and an unconstrained one", () => {
    const agent: Value = { kind: "agent", name: createAgentName("main.tool"), snapshot: SNAPSHOT };
    const agentSchema: JSONSchema = {
      type: "object",
      properties: { $agent: {} },
      required: ["$agent"],
      additionalProperties: true,
    };
    expect(conformValue(agent, agentSchema).ok).toBe(true);
    expect(conformValue(agent, {}).ok).toBe(true);
    expect(conformValue(agent, { type: "object", properties: {} }).ok).toBe(false);
  });

  test("a closure value satisfies the $agent reference schema", () => {
    const closure: Value = {
      kind: "closure",
      blockId: 4,
      scopeId: 1 as ScopeId,
      snapshot: SNAPSHOT,
      module: "main",
    };
    const agentSchema: JSONSchema = {
      type: "object",
      properties: { $agent: {} },
      required: ["$agent"],
      additionalProperties: true,
    };
    expect(conformValue(closure, agentSchema).ok).toBe(true);
  });

  // A `data` schema is nested: `{ $constructor: {const}, value: {object of fields} }` (the wire form).
  const BOX_SCHEMA: JSONSchema = {
    type: "object",
    properties: {
      $constructor: { const: "main.box" },
      value: { type: "object", properties: { n: { type: "integer" } }, required: ["n"] },
    },
    required: ["$constructor", "value"],
    additionalProperties: false,
  };

  test("accepts a data value whose constructor and fields match", () => {
    expect(conformValue(record({ n: int(1) }, "main.box"), BOX_SCHEMA).ok).toBe(true);
  });

  test("rejects a data value with the wrong constructor", () => {
    expect(conformValue(record({ n: int(1) }, "main.other"), BOX_SCHEMA).ok).toBe(false);
  });

  test("rejects an untagged record where a data value is expected (no repair)", () => {
    const result = conformValue(record({ n: int(1) }), BOX_SCHEMA);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.failures[0]?.message).toContain("main.box");
  });

  test("rejects a data value whose nested field is the wrong type", () => {
    expect(conformValue(record({ n: str("x") }, "main.box"), BOX_SCHEMA).ok).toBe(false);
  });

  test("a union of data schemas is picked by the constructor tag", () => {
    const union: JSONSchema = {
      anyOf: [
        BOX_SCHEMA,
        {
          type: "object",
          properties: { $constructor: { const: "main.empty" }, value: { type: "object" } },
          required: ["$constructor", "value"],
          additionalProperties: false,
        },
      ],
    };
    expect(conformValue(record({ n: int(1) }, "main.box"), union).ok).toBe(true);
    expect(conformValue(record({}, "main.empty"), union).ok).toBe(true);
    expect(conformValue(record({ n: int(1) }, "main.nope"), union).ok).toBe(false);
  });

  test("checks tuples positionally; rejects both a short AND an over-long tuple", () => {
    const tuple: JSONSchema = {
      type: "array",
      prefixItems: [{ type: "string" }, { type: "integer" }],
    };
    expect(conformValue({ kind: "array", elements: [str("a"), int(1)] }, tuple).ok).toBe(true);
    expect(conformValue({ kind: "array", elements: [str("a")] }, tuple).ok).toBe(false);
    // The over-length case is the regression fixed: a fixed tuple rejects surplus elements.
    expect(conformValue({ kind: "array", elements: [str("a"), int(1), int(2)] }, tuple).ok).toBe(false);
    expect(conformValue({ kind: "array", elements: [int(1), int(2)] }, tuple).ok).toBe(false);
  });

  test("checks a record[V] tail via additionalProperties", () => {
    const map: JSONSchema = { type: "object", additionalProperties: { type: "integer" } };
    expect(conformValue(record({ a: int(1), b: int(2) }), map).ok).toBe(true);
    expect(conformValue(record({ a: str("x") }), map).ok).toBe(false);
  });

  test("a never schema rejects everything and a residual $generic accepts anything", () => {
    expect(conformValue(int(1), { not: {} }).ok).toBe(false);
    expect(conformValue(int(1), { $generic: 3 }).ok).toBe(true);
  });

  test("a private value validates by shape and its content never reaches the failure list", () => {
    const secret: Value = { kind: "string", value: "hunter2", private: true };
    expect(conformValue(secret, { type: "string" }).ok).toBe(true);
    const failed = conformValue(secret, { type: "integer" });
    expect(failed.ok).toBe(false);
    if (!failed.ok) expect(JSON.stringify(failed.failures)).not.toContain("hunter2");
  });
});

describe("decode-then-check (the codec lifts, conformValue checks)", () => {
  test("wire JSON lifts and checks", () => {
    expect(conformValue(jsonToValue({ name: "alice" }), GREETER_INPUT).ok).toBe(true);
  });

  test("a fraction becomes a number and fails an integer schema", () => {
    expect(conformValue(jsonToValue(1.5), { type: "integer" }).ok).toBe(false);
    expect(conformValue(jsonToValue(1), { type: "integer" }).ok).toBe(true);
  });
});

describe("generic instantiation", () => {
  test("fillGenericSchema substitutes by GenericId and typeSubstitutionOf reads the bindings", () => {
    const schema: JSONSchema = {
      type: "object",
      properties: { x: { $generic: 7 } },
      required: ["x"],
      additionalProperties: true,
    };
    const substitution = typeSubstitutionOf(
      { T: 7 },
      { T: { kind: "type", schema: { type: "integer" } } },
    );
    const filled = fillGenericSchema(substitution, schema);
    expect(filled.properties?.x).toEqual({ type: "integer" });
    expect(conformValue(record({ x: int(1) }), filled).ok).toBe(true);
    expect(conformValue(record({ x: str("s") }), filled).ok).toBe(false);
  });
});
