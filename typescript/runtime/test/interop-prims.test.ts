// The stdlib sub-module prims (`prelude.json.*`, `prelude.record.*`, `prelude.array.*`,
// `prelude.string.*`) and `prelude.get_metadata`, exercised directly through the registry (no
// actor). JSON round-trips cover the wire conventions ($constructor / $agent / $ref) and the
// pass-through that lets `json.encode` mix plain fields with already-`json` values.

import {
  createAgentName,
  type IRModule,
  type Json,
  type JSONSchema,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import type { PrimContext } from "../src/runtime/engine/context.js";
import { jsonValueFromJson, jsonValueToJson } from "../src/runtime/engine/json-value.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { ProjectId, ScopeId, SnapshotId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-interop" as ProjectId;
const SNAPSHOT = "snapshot-interop" as SnapshotId;

const prims = new PrimRegistry();

function contextWith(ir: SnapshotRegistry = new SnapshotRegistry()): PrimContext {
  return { projectId: PROJECT, ir, blobs: new InMemoryBlobStore() };
}

/** A context whose delegate carried a `[T]` instantiation (what a call site stamps for `decode[T]`). */
function contextWithT(schema: JSONSchema): PrimContext {
  return { ...contextWith(), generics: { T: { kind: "type", schema } } };
}

function run(name: string, fields: Record<string, Value>, context = contextWith()): Promise<Value> {
  return prims.run(name, { kind: "record", fields }, context);
}

/** Round-trip helper: the prim result (a tagged `json` value) flattened back to bare JSON. */
async function asJson(value: Value): Promise<Json> {
  return jsonValueToJson(value, async (inner) => {
    if (inner.kind !== "string") throw new Error(`expected an inline string, got ${inner.kind}`);
    return inner.value;
  });
}

function str(value: string): Value {
  return { kind: "string", value };
}

function int(value: number): Value {
  return { kind: "integer", value };
}

describe("prelude.json", () => {
  test("parse lifts a document into tagged json values (integers split from numbers)", async () => {
    const parsed = await run("prelude.json.parse", {
      text: str('{"name":"alice","age":30,"score":1.5,"tags":["x"],"ok":true,"nothing":null}'),
    });
    expect(parsed.kind).toBe("record");
    if (parsed.kind === "record") expect(parsed.ctor).toBe("prelude.json.json_object");
    await expect(asJson(parsed)).resolves.toEqual({
      name: "alice",
      age: 30,
      score: 1.5,
      tags: ["x"],
      ok: true,
      nothing: null,
    });
  });

  test("parse panics (throws) on malformed JSON", async () => {
    await expect(run("prelude.json.parse", { text: str("{oops") })).rejects.toThrow(
      /json\.parse: malformed JSON/,
    );
  });

  test("stringify inverts parse", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"a":[1,2],"b":"x"}') });
    const text = await run("prelude.json.stringify", { value: parsed });
    expect(text).toEqual(str('{"a":[1,2],"b":"x"}'));
  });

  test("encode embeds a plain record and passes an existing json value through unchanged", async () => {
    const schema = jsonValueFromJson({ type: "string" });
    const encoded = await run("prelude.json.encode", {
      value: {
        kind: "record",
        fields: { name: str("tool"), input_schema: schema },
      },
    });
    await expect(asJson(encoded)).resolves.toEqual({
      name: "tool",
      input_schema: { type: "string" },
    });
  });

  test("encode keeps a data value's constructor and decode re-tags it", async () => {
    const data: Value = {
      kind: "record",
      fields: { value: int(3) },
      ctor: createAgentName("main.box"),
    };
    const encoded = await run("prelude.json.encode", { value: data });
    await expect(asJson(encoded)).resolves.toEqual({ $constructor: "main.box", value: 3 });
    const decoded = await run("prelude.json.decode", { value: encoded }, contextWithT({}));
    expect(decoded).toEqual(data);
  });

  test("encode renders an agent value as its $agent reference and decode refuses it", async () => {
    const agent: Value = { kind: "agent", name: createAgentName("main.tool"), snapshot: SNAPSHOT };
    const encoded = await run("prelude.json.encode", { value: agent });
    await expect(asJson(encoded)).resolves.toEqual({ $agent: "main.tool" });
    await expect(
      run("prelude.json.decode", { value: encoded }, contextWithT({})),
    ).rejects.toThrow(/callable/);
  });

  test("encode refuses a closure", async () => {
    const closure: Value = {
      kind: "closure",
      blockId: 1,
      scopeId: 0 as ScopeId,
      snapshot: SNAPSHOT,
      module: "main",
    };
    await expect(run("prelude.json.encode", { value: closure })).rejects.toThrow(/closure/);
  });

  test("decode flattens nested json values into plain values", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"xs":[1,"two"],"n":null}') });
    const decoded = await run("prelude.json.decode", { value: parsed }, contextWithT({}));
    expect(decoded).toEqual({
      kind: "record",
      fields: {
        xs: { kind: "array", elements: [int(1), str("two")] },
        n: { kind: "null" },
      },
    });
  });

  const POINT: JSONSchema = {
    type: "object",
    properties: { x: { type: "integer" }, y: { type: "integer" } },
    required: ["x", "y"],
    additionalProperties: true,
  };

  test("decode[T] validates against T's schema and panics on a mismatch", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"x":1,"y":2}') });
    await expect(run("prelude.json.decode", { value: parsed }, contextWithT(POINT))).resolves.toEqual({
      kind: "record",
      fields: { x: int(1), y: int(2) },
    });
    const bad = await run("prelude.json.parse", { text: str('{"x":"one"}') });
    await expect(run("prelude.json.decode", { value: bad }, contextWithT(POINT))).rejects.toThrow(
      /json\.decode: .*\$\.x/,
    );
  });

  test("decode without a carried [T] fails loud instead of skipping validation", async () => {
    const parsed = await run("prelude.json.parse", { text: str("1") });
    await expect(run("prelude.json.decode", { value: parsed })).rejects.toThrow(
      /json\.decode: .*instantiation/,
    );
  });

  test("parse_as[T] fuses parse + typed decode (no intermediate json tree)", async () => {
    await expect(
      run("prelude.json.parse_as", { text: str('{"x":1,"y":2}') }, contextWithT(POINT)),
    ).resolves.toEqual({ kind: "record", fields: { x: int(1), y: int(2) } });
    await expect(
      run("prelude.json.parse_as", { text: str('{"y":2}') }, contextWithT(POINT)),
    ).rejects.toThrow(/json\.parse_as: .*missing required field "x"/);
    await expect(
      run("prelude.json.parse_as", { text: str("{oops") }, contextWithT(POINT)),
    ).rejects.toThrow(/json\.parse_as: malformed JSON/);
  });

  test("stringify is generic: a plain record renders as its document (json still passes through)", async () => {
    await expect(
      run("prelude.json.stringify", {
        value: { kind: "record", fields: { a: int(1), b: str("x") } },
      }),
    ).resolves.toEqual(str('{"a":1,"b":"x"}'));
  });
});

describe("prelude.record / prelude.array / prelude.string", () => {
  const target: Value = { kind: "record", fields: { b: int(2), a: int(1) } };

  test("record.get / has / size / keys / entries / set / remove", async () => {
    await expect(run("prelude.record.get", { target, key: str("a") })).resolves.toEqual(int(1));
    await expect(run("prelude.record.get", { target, key: str("zz") })).resolves.toEqual({
      kind: "null",
    });
    await expect(run("prelude.record.has", { target, key: str("b") })).resolves.toEqual({
      kind: "boolean",
      value: true,
    });
    await expect(run("prelude.record.size", { target })).resolves.toEqual(int(2));
    await expect(run("prelude.record.keys", { target })).resolves.toEqual({
      kind: "array",
      elements: [str("a"), str("b")],
    });
    await expect(run("prelude.record.entries", { target })).resolves.toEqual({
      kind: "array",
      elements: [
        { kind: "array", elements: [str("a"), int(1)] },
        { kind: "array", elements: [str("b"), int(2)] },
      ],
    });
    await expect(run("prelude.record.set", { target, key: str("c"), value: int(3) })).resolves.toEqual({
      kind: "record",
      fields: { a: int(1), b: int(2), c: int(3) },
    });
    await expect(run("prelude.record.remove", { target, key: str("a") })).resolves.toEqual({
      kind: "record",
      fields: { b: int(2) },
    });
  });

  test("array.get / length / append / concat / slice", async () => {
    const xs: Value = { kind: "array", elements: [int(1), int(2), int(3)] };
    await expect(run("prelude.array.get", { target: xs, index: int(1) })).resolves.toEqual(int(2));
    await expect(run("prelude.array.get", { target: xs, index: int(9) })).resolves.toEqual({
      kind: "null",
    });
    await expect(run("prelude.array.length", { target: xs })).resolves.toEqual(int(3));
    await expect(run("prelude.array.append", { target: xs, value: int(4) })).resolves.toEqual({
      kind: "array",
      elements: [int(1), int(2), int(3), int(4)],
    });
    await expect(
      run("prelude.array.concat", {
        left: { kind: "array", elements: [int(1)] },
        right: { kind: "array", elements: [int(2)] },
      }),
    ).resolves.toEqual({ kind: "array", elements: [int(1), int(2)] });
    await expect(run("prelude.array.slice", { target: xs, start: int(1), end: int(9) })).resolves.toEqual(
      { kind: "array", elements: [int(2), int(3)] },
    );
  });

  test("string.length / split / join / slice / contains count code points", async () => {
    await expect(run("prelude.string.length", { value: str("a👍b") })).resolves.toEqual(int(3));
    await expect(run("prelude.string.split", { value: str("a👍b"), separator: str("") })).resolves.toEqual(
      { kind: "array", elements: [str("a"), str("👍"), str("b")] },
    );
    await expect(run("prelude.string.split", { value: str("a,b"), separator: str(",") })).resolves.toEqual(
      { kind: "array", elements: [str("a"), str("b")] },
    );
    await expect(
      run("prelude.string.join", {
        parts: { kind: "array", elements: [str("a"), str("b")] },
        separator: str("-"),
      }),
    ).resolves.toEqual(str("a-b"));
    await expect(
      run("prelude.string.slice", { value: str("a👍b"), start: int(1), end: int(2) }),
    ).resolves.toEqual(str("👍"));
    await expect(
      run("prelude.string.contains", { value: str("hello"), search: str("ell") }),
    ).resolves.toEqual({ kind: "boolean", value: true });
  });
});

describe("prelude.ai.get_metadata", () => {
  const GREETER_SCHEMA: SchemaInfo = {
    input: {
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
      additionalProperties: true,
    },
    output: { type: "string" },
    requests: [],
    genericBindings: {},
  };

  const IDENTITY_SCHEMA: SchemaInfo = {
    input: {
      type: "object",
      properties: { x: { $generic: 7 } },
      required: ["x"],
      additionalProperties: true,
    },
    output: { $generic: 7 },
    requests: [],
    genericBindings: { T: 7 },
  };

  function irWith(): SnapshotRegistry {
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: {
          block: {
            kind: "agent",
            body: 1,
            schema: GREETER_SCHEMA,
            description: "Returns a greeting.",
            defaults: {},
          },
          parameters: {},
        },
        1: { block: { kind: "sequence", operations: [], result: null }, parameters: {} },
        2: {
          block: { kind: "agent", body: 3, schema: IDENTITY_SCHEMA, description: "", defaults: {} },
          parameters: {},
        },
        3: { block: { kind: "sequence", operations: [], result: null }, parameters: {} },
      },
      entries: {
        [createAgentName("main.greeter")]: 0,
        [createAgentName("main.identity")]: 2,
      },
      names: {},
    };
    const registry = new SnapshotRegistry();
    registry.set(SNAPSHOT, "main", ir);
    return registry;
  }

  test("derives name / description / schemas as json values", async () => {
    const context = contextWith(irWith());
    const metadata = await run(
      "prelude.ai.get_metadata",
      { value: { kind: "agent", name: createAgentName("main.greeter"), snapshot: SNAPSHOT } },
      context,
    );
    expect(metadata.kind).toBe("record");
    if (metadata.kind !== "record") return;
    expect(metadata.ctor).toBe("prelude.ai.agent_metadata");
    expect(metadata.fields.name).toEqual(str("main.greeter"));
    expect(metadata.fields.description).toEqual(str("Returns a greeting."));
    const input = metadata.fields.input;
    const output = metadata.fields.output;
    const requests = metadata.fields.requests;
    if (input === undefined || output === undefined || requests === undefined) {
      throw new Error("metadata is missing schema fields");
    }
    await expect(asJson(input)).resolves.toEqual({
      type: "object",
      properties: { name: { type: "string" } },
      required: ["name"],
      additionalProperties: true,
    });
    await expect(asJson(output)).resolves.toEqual({ type: "string" });
    await expect(asJson(requests)).resolves.toEqual([]);
  });

  test("specialises a generic callable's schemas through its carried substitution", async () => {
    const context = contextWith(irWith());
    const metadata = await run(
      "prelude.ai.get_metadata",
      {
        value: {
          kind: "agent",
          name: createAgentName("main.identity"),
          snapshot: SNAPSHOT,
          generics: { T: { kind: "type", schema: { type: "integer" } } },
        },
      },
      context,
    );
    if (metadata.kind !== "record") throw new Error("expected a record");
    const output = metadata.fields.output;
    if (output === undefined) throw new Error("metadata is missing output");
    await expect(asJson(output)).resolves.toEqual({ type: "integer" });
  });

  test("refuses a non-callable value", async () => {
    await expect(run("prelude.ai.get_metadata", { value: int(1) }, contextWith(irWith()))).rejects.toThrow(
      /callable/,
    );
  });
});
