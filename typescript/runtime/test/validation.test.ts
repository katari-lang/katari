// The schema-conformance walk (`conformValue` / `parseJson`): the delegate boundary's argument check.
// Covers the value-model foldbacks (integer-as-number subtyping, blob-string / file / callable
// reference schemas), the single repair (a missing `$constructor` against a pinned constructor — but
// never inside an `anyOf` trial, where the tag is what picks the branch), unions, tuples, closed
// records, and generic instantiation.

import { createAgentName, type JSONSchema } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import type { BlobId, ScopeId, SnapshotId } from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";
import {
  conformValue,
  fillGenericSchema,
  parseJson,
  typeSubstitutionOf,
} from "../src/runtime/value/validation.js";

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
  test("accepts a matching record and keeps its identity", () => {
    const value = record({ name: str("alice") });
    const result = conformValue(value, GREETER_INPUT);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.value).toBe(value);
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

  test("an integer satisfies a number schema without re-tagging", () => {
    const result = conformValue(int(3), { type: "number" });
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.value).toEqual(int(3));
  });

  test("a number does not satisfy an integer schema", () => {
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

  const DATA_SCHEMA: JSONSchema = {
    type: "object",
    properties: { $constructor: { const: "main.box" }, value: { type: "integer" } },
    required: ["$constructor", "value"],
    additionalProperties: true,
  };

  test("repairs a missing $constructor against a pinned constructor", () => {
    const result = conformValue(record({ value: int(1) }), DATA_SCHEMA);
    expect(result.ok).toBe(true);
    if (result.ok && result.value.kind === "record") {
      expect(result.value.ctor).toBe("main.box");
    }
  });

  test("rejects a mismatching $constructor", () => {
    expect(conformValue(record({ value: int(1) }, "main.other"), DATA_SCHEMA).ok).toBe(false);
  });

  test("does NOT repair inside an anyOf trial (an untagged record matches no union arm)", () => {
    const union: JSONSchema = {
      anyOf: [
        {
          type: "object",
          properties: { $constructor: { const: "main.box" }, value: { type: "integer" } },
          required: ["$constructor", "value"],
          additionalProperties: true,
        },
        {
          type: "object",
          properties: { $constructor: { const: "main.empty" } },
          required: ["$constructor"],
          additionalProperties: true,
        },
      ],
    };
    expect(conformValue(record({ value: int(1) }), union).ok).toBe(false);
    expect(conformValue(record({ value: int(1) }, "main.box"), union).ok).toBe(true);
    expect(conformValue(record({}, "main.empty"), union).ok).toBe(true);
  });

  test("checks tuples positionally and rejects a short tuple", () => {
    const tuple: JSONSchema = { type: "array", prefixItems: [{ type: "string" }, { type: "integer" }] };
    expect(
      conformValue({ kind: "array", elements: [str("a"), int(1)] }, tuple).ok,
    ).toBe(true);
    expect(conformValue({ kind: "array", elements: [str("a")] }, tuple).ok).toBe(false);
    expect(
      conformValue({ kind: "array", elements: [int(1), int(2)] }, tuple).ok,
    ).toBe(false);
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

describe("parseJson", () => {
  test("lifts and checks wire JSON in one step", () => {
    const result = parseJson({ name: "alice" }, GREETER_INPUT);
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.value).toEqual(record({ name: str("alice") }));
  });

  test("a fraction becomes a number and fails an integer schema", () => {
    expect(parseJson(1.5, { type: "integer" }).ok).toBe(false);
    expect(parseJson(1, { type: "integer" }).ok).toBe(true);
  });

  test("a $agent key in the JSON fails cleanly (callables cannot enter as JSON)", () => {
    const result = parseJson({ $agent: "main.tool" }, {});
    expect(result.ok).toBe(false);
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
