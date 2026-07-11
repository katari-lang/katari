// The stdlib sub-module prims (`prelude.json.*`, `prelude.record.*`, `prelude.array.*`,
// `prelude.string.*`) and `prelude.get_metadata`, exercised directly through the registry (no
// actor). JSON round-trips cover the wire conventions (nested `$constructor`, `$agent` / `$closure`
// references carrying their snapshot, `$ref` handles) and the total encode/decode bijection.

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
import { KatariThrow } from "../src/runtime/engine/throw-signal.js";
import type { BlobId, ProjectId, ScopeId, SnapshotId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-interop" as ProjectId;
const SNAPSHOT = "snapshot-interop" as SnapshotId;

const prims = new PrimRegistry();

function contextWith(ir: SnapshotRegistry = new SnapshotRegistry()): PrimContext {
  return {
    projectId: PROJECT,
    ir,
    blobs: new InMemoryBlobStore(),
    blobEntryOf: () => undefined,
  };
}

/** A context whose delegate carried a `[T]` instantiation (what a call site stamps for `decode[T]`). */
function contextWithT(schema: JSONSchema): PrimContext {
  return { ...contextWith(), generics: { T: { kind: "type", schema } } };
}

function run(name: string, fields: Record<string, Value>, context = contextWith()): Promise<Value> {
  return prims.run(name, { kind: "record", fields }, context);
}

/** Assert a prim rejects with a typed `KatariThrow` whose payload is the given error data ctor carrying
 *  a `{ message }` matching `pattern` — the shape the engine raises `prelude.throw` with. */
async function expectThrows(promise: Promise<Value>, ctor: string, pattern: RegExp): Promise<void> {
  const error = await promise.then(
    () => {
      throw new Error("expected the prim to throw");
    },
    (thrown: unknown) => thrown,
  );
  expect(error).toBeInstanceOf(KatariThrow);
  if (error instanceof KatariThrow) {
    expect(error.payload.kind).toBe("record");
    if (error.payload.kind === "record") {
      expect(error.payload.ctor).toBe(ctor);
      const message = error.payload.fields.message;
      expect(message?.kind).toBe("string");
      if (message?.kind === "string") expect(message.value).toMatch(pattern);
    }
  }
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

/** The `$constructor` tag of one entry of a parsed `json_object` tree. */
function constructorOfEntry(parsed: Value, key: string): string | undefined {
  if (parsed.kind !== "record") throw new Error(`expected a record, got ${parsed.kind}`);
  const entries = parsed.fields.entries;
  if (entries === undefined || entries.kind !== "record") {
    throw new Error("expected a json_object with an entries record");
  }
  const entry = entries.fields[key];
  if (entry === undefined || entry.kind !== "record") {
    throw new Error(`expected a tagged entry at "${key}"`);
  }
  return entry.ctor === undefined ? undefined : String(entry.ctor);
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

  test("parse tags a fraction-less number json_integer, a fractional one json_number", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"a":30,"b":1.5,"c":1.0}') });
    // Assert the tags themselves (a round-trip comparison would pass even without the split).
    // `1.0` collapses to json_integer by design: JSON has one number type, so integer-ness of the
    // parsed value is all the boundary can split on.
    expect(constructorOfEntry(parsed, "a")).toBe("prelude.json.json_integer");
    expect(constructorOfEntry(parsed, "b")).toBe("prelude.json.json_number");
    expect(constructorOfEntry(parsed, "c")).toBe("prelude.json.json_integer");
  });

  test("parse throws a typed `parse_error` on malformed JSON", async () => {
    await expectThrows(
      run("prelude.json.parse", { text: str("{oops") }),
      "prelude.json.parse_error",
      /json\.parse: malformed JSON/,
    );
  });

  test("stringify inverts parse", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"a":[1,2],"b":"x"}') });
    const text = await run("prelude.json.stringify", { value: parsed });
    expect(text).toEqual(str('{"a":[1,2],"b":"x"}'));
  });

  test("encode embeds a plain record by its wire form", async () => {
    const encoded = await run("prelude.json.encode", {
      value: { kind: "record", fields: { name: str("tool"), n: int(1) } },
    });
    await expect(asJson(encoded)).resolves.toEqual({ name: "tool", n: 1 });
  });

  test("encode treats a json value like any data value (no special case) and decode inverts it", async () => {
    // `json` is an ordinary data type: encoding a json value yields its nested tagged wire form, and
    // decode[T] re-tags it back — the total round-trip law decode(encode(x)) == x, uniform in T.
    const original = jsonValueFromJson("hi");
    const encoded = await run("prelude.json.encode", { value: original });
    await expect(asJson(encoded)).resolves.toEqual({
      $constructor: "prelude.json.json_string",
      value: { value: "hi" },
    });
    await expect(run("prelude.json.decode", { value: encoded }, contextWithT({}))).resolves.toEqual(
      original,
    );
  });

  test("encode nests a data value's fields under `value` and decode re-tags it", async () => {
    const data: Value = {
      kind: "record",
      fields: { n: int(3) },
      ctor: createAgentName("main.box"),
    };
    const encoded = await run("prelude.json.encode", { value: data });
    await expect(asJson(encoded)).resolves.toEqual({ $constructor: "main.box", value: { n: 3 } });
    const decoded = await run("prelude.json.decode", { value: encoded }, contextWithT({}));
    expect(decoded).toEqual(data);
  });

  test("encode renders an agent as its $agent reference (with snapshot) and decode reconstructs it", async () => {
    const agent: Value = { kind: "agent", name: createAgentName("main.tool"), snapshot: SNAPSHOT };
    const encoded = await run("prelude.json.encode", { value: agent });
    await expect(asJson(encoded)).resolves.toEqual({ $agent: "main.tool", snapshot: SNAPSHOT });
    await expect(run("prelude.json.decode", { value: encoded }, contextWithT({}))).resolves.toEqual(agent);
  });

  test("encode renders a closure as its $closure reference and decode reconstructs it", async () => {
    const closure: Value = {
      kind: "closure",
      blockId: 1,
      scopeId: 0 as ScopeId,
      snapshot: SNAPSHOT,
      module: "main",
    };
    const encoded = await run("prelude.json.encode", { value: closure });
    await expect(asJson(encoded)).resolves.toEqual({
      $closure: 1,
      scopeId: 0,
      snapshot: SNAPSHOT,
      module: "main",
    });
    await expect(run("prelude.json.decode", { value: encoded }, contextWithT({}))).resolves.toEqual(closure);
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

  test("decode[T] validates against T's schema and throws a typed `decode_error` on a mismatch", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"x":1,"y":2}') });
    await expect(run("prelude.json.decode", { value: parsed }, contextWithT(POINT))).resolves.toEqual({
      kind: "record",
      fields: { x: int(1), y: int(2) },
    });
    const bad = await run("prelude.json.parse", { text: str('{"x":"one"}') });
    await expectThrows(
      run("prelude.json.decode", { value: bad }, contextWithT(POINT)),
      "prelude.json.decode_error",
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
    await expectThrows(
      run("prelude.json.parse_as", { text: str('{"y":2}') }, contextWithT(POINT)),
      "prelude.json.decode_error",
      /json\.parse_as: .*missing required field "x"/,
    );
    await expectThrows(
      run("prelude.json.parse_as", { text: str("{oops") }, contextWithT(POINT)),
      "prelude.json.parse_error",
      /json\.parse_as: malformed JSON/,
    );
  });

  test("to_text fuses stringify(encode(x)) and inverts parse_as", async () => {
    const mixed: Value = {
      kind: "record",
      fields: {
        a: int(1),
        box: { kind: "record", ctor: createAgentName("main.box"), fields: { value: int(3) } },
        j: jsonValueFromJson("hi"),
      },
    };
    const fused = await run("prelude.json.to_text", { value: mixed });
    const composed = await run("prelude.json.stringify", {
      value: await run("prelude.json.encode", { value: mixed }),
    });
    expect(fused).toEqual(composed);
    if (fused.kind !== "string") throw new Error("expected a string");
    // parse_as[unknown] of to_text(x) round-trips x (the nested $constructor entries re-tag).
    await expect(
      run("prelude.json.parse_as", { text: fused }, contextWithT({})),
    ).resolves.toEqual(mixed);
  });

  test("stringify takes json only; the generic pipe is stringify(encode(x))", async () => {
    await expect(
      run("prelude.json.stringify", {
        value: { kind: "record", fields: { a: int(1) } },
      }),
    ).rejects.toThrow(/expected a json value/);
    const embedded = await run("prelude.json.encode", {
      value: { kind: "record", fields: { a: int(1), b: str("x") } },
    });
    await expect(run("prelude.json.stringify", { value: embedded })).resolves.toEqual(
      str('{"a":1,"b":"x"}'),
    );
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

  test("record.merge combines entries with the right value winning on a shared key", async () => {
    await expect(
      run("prelude.record.merge", {
        left: { kind: "record", fields: { a: int(1), b: int(2) } },
        right: { kind: "record", fields: { b: int(20), c: int(3) } },
      }),
    ).resolves.toEqual({ kind: "record", fields: { a: int(1), b: int(20), c: int(3) } });
  });

  test("array.contains / index_of use structural equality; flatten / reverse / range reshape", async () => {
    const records: Value = {
      kind: "array",
      elements: [
        { kind: "record", fields: { x: int(1) } },
        { kind: "record", fields: { x: int(2) } },
      ],
    };
    await expect(
      run("prelude.array.contains", { target: records, value: { kind: "record", fields: { x: int(2) } } }),
    ).resolves.toEqual({ kind: "boolean", value: true });
    await expect(
      run("prelude.array.index_of", { target: records, value: { kind: "record", fields: { x: int(2) } } }),
    ).resolves.toEqual(int(1));
    await expect(
      run("prelude.array.index_of", { target: records, value: { kind: "record", fields: { x: int(9) } } }),
    ).resolves.toEqual({ kind: "null" });
    await expect(
      run("prelude.array.flatten", {
        target: {
          kind: "array",
          elements: [
            { kind: "array", elements: [int(1)] },
            { kind: "array", elements: [] },
            { kind: "array", elements: [int(2), int(3)] },
          ],
        },
      }),
    ).resolves.toEqual({ kind: "array", elements: [int(1), int(2), int(3)] });
    await expect(
      run("prelude.array.reverse", { target: { kind: "array", elements: [int(1), int(2)] } }),
    ).resolves.toEqual({ kind: "array", elements: [int(2), int(1)] });
    await expect(run("prelude.array.range", { start: int(2), end: int(5) })).resolves.toEqual({
      kind: "array",
      elements: [int(2), int(3), int(4)],
    });
    await expect(run("prelude.array.range", { start: int(3), end: int(3) })).resolves.toEqual({
      kind: "array",
      elements: [],
    });
  });

  test("array.range refuses an over-large span rather than allocating unboundedly", async () => {
    // The span is materialised synchronously on the actor's serial turn, so an unbounded (possibly
    // AI-supplied) bound would stall or OOM the project. It is rejected as a plain Error (a panic at the
    // prim seam) rather than run — fail-safe, since a billion-element range is a logic error.
    await expect(
      run("prelude.array.range", { start: int(0), end: int(20_000_000) }),
    ).rejects.toThrow(/exceeding the/);
    // A range at the ceiling is unaffected (checked cheaply, without building it).
    await expect(run("prelude.array.range", { start: int(5), end: int(5) })).resolves.toEqual({
      kind: "array",
      elements: [],
    });
  });

  test("string.starts_with / ends_with / index_of / replace / trim / case fold", async () => {
    await expect(
      run("prelude.string.starts_with", { value: str("hello"), search: str("he") }),
    ).resolves.toEqual({ kind: "boolean", value: true });
    await expect(
      run("prelude.string.ends_with", { value: str("hello"), search: str("he") }),
    ).resolves.toEqual({ kind: "boolean", value: false });
    // index_of counts code points: the hit after an astral character is at 2, not 3.
    await expect(
      run("prelude.string.index_of", { value: str("a👍b"), search: str("b") }),
    ).resolves.toEqual(int(2));
    await expect(
      run("prelude.string.index_of", { value: str("abc"), search: str("zz") }),
    ).resolves.toEqual({ kind: "null" });
    // The replacement is literal text — `$&` must not be read as a substitution pattern.
    await expect(
      run("prelude.string.replace", { value: str("a-b-c"), search: str("-"), replacement: str("$&") }),
    ).resolves.toEqual(str("a$&b$&c"));
    await expect(
      run("prelude.string.replace", { value: str("abc"), search: str(""), replacement: str("x") }),
    ).resolves.toEqual(str("abc"));
    await expect(run("prelude.string.trim", { value: str("  hi\n") })).resolves.toEqual(str("hi"));
    await expect(run("prelude.string.to_upper", { value: str("hé") })).resolves.toEqual(str("HÉ"));
    await expect(run("prelude.string.to_lower", { value: str("HÉ") })).resolves.toEqual(str("hé"));
  });

  test("string.to_integer / to_number accept exactly the declared grammar, null otherwise", async () => {
    await expect(run("prelude.string.to_integer", { value: str("-42") })).resolves.toEqual(int(-42));
    await expect(run("prelude.string.to_integer", { value: str("+7") })).resolves.toEqual(int(7));
    // Not the canonical integer form: fractional, padded, hex, and empty are all null.
    for (const text of ["42.0", " 42", "0x10", "", "abc"]) {
      await expect(run("prelude.string.to_integer", { value: str(text) })).resolves.toEqual({
        kind: "null",
      });
    }
    // A magnitude the number model cannot hold exactly must be null, not silently rounded.
    await expect(
      run("prelude.string.to_integer", { value: str("9007199254740993") }),
    ).resolves.toEqual({ kind: "null" });
    await expect(run("prelude.string.to_number", { value: str("-1.5e3") })).resolves.toEqual({
      kind: "number",
      value: -1500,
    });
    // JSON's grammar only: the `Number(...)` extras (hex, Infinity, whitespace) are all null.
    for (const text of ["0x10", "Infinity", " 1", "1e999", ""]) {
      await expect(run("prelude.string.to_number", { value: str(text) })).resolves.toEqual({
        kind: "null",
      });
    }
  });
});

describe("prelude.math", () => {
  const num = (value: number): Value => ({ kind: "number", value });

  test("abs / min / max preserve integer-ness like the arithmetic operators", async () => {
    await expect(run("prelude.math.abs", { value: int(-3) })).resolves.toEqual(int(3));
    await expect(run("prelude.math.abs", { value: num(-3.5) })).resolves.toEqual(num(3.5));
    await expect(run("prelude.math.min", { left: int(2), right: int(5) })).resolves.toEqual(int(2));
    await expect(run("prelude.math.max", { left: int(2), right: num(5.5) })).resolves.toEqual(
      num(5.5),
    );
  });

  test("floor / ceil / round convert number to integer (round is half away from zero)", async () => {
    await expect(run("prelude.math.floor", { value: num(1.9) })).resolves.toEqual(int(1));
    await expect(run("prelude.math.floor", { value: num(-1.1) })).resolves.toEqual(int(-2));
    await expect(run("prelude.math.ceil", { value: num(1.1) })).resolves.toEqual(int(2));
    await expect(run("prelude.math.ceil", { value: num(-0.5) })).resolves.toEqual(int(0));
    await expect(run("prelude.math.round", { value: num(2.5) })).resolves.toEqual(int(3));
    // Half away from zero: -2.5 rounds to -3 (JS Math.round alone would give -2).
    await expect(run("prelude.math.round", { value: num(-2.5) })).resolves.toEqual(int(-3));
    await expect(run("prelude.math.round", { value: num(-0.4) })).resolves.toEqual(int(0));
  });
});

describe("prelude.reflection.get_metadata", () => {
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
      "prelude.reflection.get_metadata",
      { value: { kind: "agent", name: createAgentName("main.greeter"), snapshot: SNAPSHOT } },
      context,
    );
    expect(metadata.kind).toBe("record");
    if (metadata.kind !== "record") return;
    expect(metadata.ctor).toBe("prelude.reflection.agent_metadata");
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
      "prelude.reflection.get_metadata",
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
    await expect(run("prelude.reflection.get_metadata", { value: int(1) }, contextWith(irWith()))).rejects.toThrow(
      /callable/,
    );
  });

  test("a reactor-backed tool presents its minted name / description / schemas", async () => {
    const context = contextWith(irWith());
    const toolSchema = {
      type: "object",
      properties: { city: { type: "string" } },
      required: ["city"],
    };
    // The shape `prelude.mcp.provide` mints: a $tool value carrying its reactor context (opaque to
    // metadata) and the server-declared signature (output schema optional — `{}`/unknown when undeclared).
    const tool: Value = {
      kind: "tool",
      reactor: "mcp",
      name: "weather",
      description: "Looks up the weather.",
      context: { kind: "record", fields: { url: str("https://mcp.example.test/mcp") } },
      snapshot: SNAPSHOT,
      inputSchema: {
        type: "object",
        properties: { city: { type: "string" } },
        required: ["city"],
      },
      outputSchema: { type: "string" },
    };
    const metadata = await run("prelude.reflection.get_metadata", { value: tool }, context);
    if (metadata.kind !== "record") throw new Error("expected a record");
    expect(metadata.fields.name).toEqual(str("weather"));
    expect(metadata.fields.description).toEqual(str("Looks up the weather."));
    const input = metadata.fields.input;
    const output = metadata.fields.output;
    if (input === undefined || output === undefined) throw new Error("metadata is missing schemas");
    await expect(asJson(input)).resolves.toEqual(toolSchema);
    await expect(asJson(output)).resolves.toEqual({ type: "string" });
    // Without a declared output schema, the output is unknown (`{}`).
    const bare = await run(
      "prelude.reflection.get_metadata",
      { value: { ...tool, outputSchema: undefined } },
      context,
    );
    if (bare.kind !== "record" || bare.fields.output === undefined) throw new Error("expected output");
    await expect(asJson(bare.fields.output)).resolves.toEqual({});
  });
});

describe("prelude.file", () => {
  const BLOB = "blob-file-prim" as BlobId;
  // The PNG magic bytes — a recognisable fixture whose base64 is stable.
  const BYTES = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);

  /** A context whose byte store holds the fixture bytes and whose catalog holds its row, plus the
   *  slim `file` handle naming them (identity only — metadata comes from the catalog). */
  async function fileContext(contentType?: string): Promise<{ context: PrimContext; file: Value }> {
    const blobs = new InMemoryBlobStore();
    await blobs.put(PROJECT, BLOB, BYTES);
    const context: PrimContext = {
      projectId: PROJECT,
      ir: new SnapshotRegistry(),
      blobs,
      blobEntryOf: (blobId) =>
        blobId === BLOB
          ? {
              owner: null,
              hash: "hash-file-prim",
              size: BYTES.length,
              semanticKind: "file",
              ...(contentType !== undefined ? { contentType } : {}),
            }
          : undefined,
    };
    const file: Value = { kind: "ref", semanticKind: "file", blobId: BLOB };
    return { context, file };
  }

  test("read_base64 returns the blob's bytes base64-encoded", async () => {
    const { context, file } = await fileContext("image/png");
    const result = await run("prelude.file.read_base64", { value: file }, context);
    expect(result).toEqual({ kind: "string", value: Buffer.from(BYTES).toString("base64") });
  });

  test("content_type reads the CATALOG row's MIME type, degrading to \"\" when unrecorded", async () => {
    const withType = await fileContext("image/png");
    await expect(
      run("prelude.file.content_type", { value: withType.file }, withType.context),
    ).resolves.toEqual({ kind: "string", value: "image/png" });
    const without = await fileContext();
    await expect(
      run("prelude.file.content_type", { value: without.file }, without.context),
    ).resolves.toEqual({ kind: "string", value: "" });
  });

  test("size reads the catalog row (the slim handle carries no metadata)", async () => {
    const { context, file } = await fileContext();
    await expect(run("prelude.file.size", { value: file }, context)).resolves.toEqual({
      kind: "integer",
      value: BYTES.length,
    });
  });

  test("a dangling handle (deleted, or a made-up id) fails loudly with the id", async () => {
    const { context } = await fileContext();
    const dangling: Value = { kind: "ref", semanticKind: "file", blobId: "blob-made-up" as BlobId };
    await expect(run("prelude.file.size", { value: dangling }, context)).rejects.toThrow(
      /blob-made-up does not exist/,
    );
  });

  test("a bare { $ref } handle decodes to a file value (what an AI replays suffices)", async () => {
    const handle = jsonValueFromJson({ image: { $ref: "blob-someone-elses" } });
    await expect(
      run("prelude.json.decode", { value: handle }, contextWithT({})),
    ).resolves.toEqual({
      kind: "record",
      fields: {
        image: { kind: "ref", semanticKind: "file", blobId: "blob-someone-elses" },
      },
    });
  });

  test("a non-file argument is rejected (a blob-backed string is not a file)", async () => {
    const { context } = await fileContext();
    const stringRef: Value = { kind: "ref", semanticKind: "string", blobId: BLOB };
    await expect(run("prelude.file.read_base64", { value: stringRef }, context)).rejects.toThrow(
      /expected a file/,
    );
  });
});
