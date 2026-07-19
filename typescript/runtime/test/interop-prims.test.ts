// The stdlib sub-module prims (`prelude.json.*`, `prelude.record.*`, `prelude.array.*`,
// `prelude.string.*`) and `prelude.get_metadata`, exercised directly through the registry (no actor).
// `parse` reads text through the value codec (a `$katari_ref` becomes a file; a document with no reserved
// key round-trips verbatim). `stringify` is TOTAL: a document round-trips key-for-key
// (`stringify(parse(s)) == s`), and a non-document value renders its canonical wire form (a data value nests
// under `$katari_value`, an agent / closure reference carries its snapshot, a file is a `$katari_ref`
// handle). `validate[T]` checks a value against T's schema and returns it unchanged, or throws
// `validation_error`.

import {
  createAgentName,
  type IRModule,
  type Json,
  type JSONSchema,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import type { PrimContext } from "../src/runtime/engine/context.js";
import type { CoreInstance, ProjectStore } from "../src/runtime/engine/types.js";
import { valueEquals, valueToJson } from "../src/runtime/value/codec.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { KatariThrow } from "../src/runtime/engine/throw-signal.js";
import {
  type BlobId,
  type DelegationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
  toThreadId,
} from "../src/runtime/ids.js";
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

/** A context whose delegate carried a `[T]` instantiation (what a call site stamps for `validate[T]`). */
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

/** Flatten a schema / requests metadata value (a plain document value) back to bare JSON for comparison. */
async function asJson(value: Value): Promise<Json> {
  return valueToJson(value, "reveal");
}

function str(value: string): Value {
  return { kind: "string", value };
}

function int(value: number): Value {
  return { kind: "integer", value };
}

describe("prelude.json", () => {
  test("parse lifts a document into PLAIN values (records, arrays, scalars; keys verbatim)", async () => {
    const parsed = await run("prelude.json.parse", {
      text: str('{"name":"alice","age":30,"score":1.5,"tags":["x"],"ok":true,"nothing":null}'),
    });
    // No tagged tree: a document is an ordinary record, its scalars ordinary scalars.
    expect(parsed).toEqual({
      kind: "record",
      fields: {
        name: str("alice"),
        age: int(30),
        score: { kind: "number", value: 1.5 },
        tags: { kind: "array", elements: [str("x")] },
        ok: { kind: "boolean", value: true },
        nothing: { kind: "null" },
      },
    });
  });

  test("parse splits a fraction-less number to integer, a fractional one to number", async () => {
    // `1.0` collapses to integer by design: JSON has one number type, so integer-ness is all the
    // boundary can split on.
    const parsed = await run("prelude.json.parse", { text: str('{"a":30,"b":1.5,"c":1.0}') });
    if (parsed.kind !== "record") throw new Error("expected a record");
    expect(parsed.fields.a).toEqual(int(30));
    expect(parsed.fields.b).toEqual({ kind: "number", value: 1.5 });
    expect(parsed.fields.c).toEqual(int(1));
  });

  test("parse interprets a `$katari_ref` marker into a file; a non-reserved `$` key stays a field", async () => {
    const withMarker = await run("prelude.json.parse", {
      text: str('{"doc":{"$katari_ref":"blob-abc"}}'),
    });
    expect(withMarker).toEqual({
      kind: "record",
      fields: { doc: { kind: "ref", semanticKind: "file", blobId: "blob-abc" } },
    });
    // A `$`-prefixed key outside the reserved `$katari_` namespace is an ordinary field (external JSON's
    // `$ref` / `$constructor` never carry katari meaning).
    const literal = await run("prelude.json.parse", {
      text: str('{"$ref":"#/defs/x","$constructor":"main.box"}'),
    });
    expect(literal).toEqual({
      kind: "record",
      fields: { $ref: str("#/defs/x"), $constructor: str("main.box") },
    });
  });

  test("parse throws a typed `parse_error` on malformed JSON", async () => {
    await expectThrows(
      run("prelude.json.parse", { text: str("{oops") }),
      "prelude.json.parse_error",
      /json\.parse: malformed JSON/,
    );
  });

  test("stringify inverts parse (keys verbatim, `$` uninterpreted)", async () => {
    const parsed = await run("prelude.json.parse", { text: str('{"a":[1,2],"b":"x","$ref":"y"}') });
    const text = await run("prelude.json.stringify", { value: parsed });
    expect(text).toEqual(str('{"a":[1,2],"b":"x","$ref":"y"}'));
  });

  test("stringify is TOTAL: a data value nests under `$katari_value`, a file becomes its `$katari_ref` handle", async () => {
    const data: Value = {
      kind: "record",
      fields: { n: int(3) },
      ctor: createAgentName("main.box"),
    };
    const dataText = await run("prelude.json.stringify", { value: data });
    if (dataText.kind !== "string") throw new Error("expected a string");
    expect(JSON.parse(dataText.value)).toEqual({ $katari_constructor: "main.box", $katari_value: { n: 3 } });

    const file: Value = { kind: "ref", semanticKind: "file", blobId: "blob-x" as BlobId };
    const fileText = await run("prelude.json.stringify", { value: file });
    if (fileText.kind !== "string") throw new Error("expected a string");
    expect(JSON.parse(fileText.value)).toEqual({ $katari_ref: "blob-x", $katari_semantic_kind: "file" });
  });

  const POINT: JSONSchema = {
    type: "object",
    properties: { x: { type: "integer" }, y: { type: "integer" } },
    required: ["x", "y"],
    additionalProperties: true,
  };

  test("validate[T] returns a conforming value unchanged and throws `validation_error` on a mismatch", async () => {
    const point: Value = { kind: "record", fields: { x: int(1), y: int(2) } };
    await expect(
      run("prelude.json.validate", { value: point }, contextWithT(POINT)),
    ).resolves.toEqual(point);
    await expectThrows(
      run("prelude.json.validate", { value: { kind: "record", fields: { y: int(2) } } }, contextWithT(POINT)),
      "prelude.json.validation_error",
      /json\.validate: .*missing required field "x"/,
    );
  });

  test("validate[unknown] accepts and returns any value unchanged (a pure check, no rewrite)", async () => {
    const value: Value = {
      kind: "record",
      fields: { image: { kind: "record", fields: { $ref: str("blob-abc") } } },
    };
    await expect(run("prelude.json.validate", { value }, contextWithT({}))).resolves.toEqual(value);
  });

  test("stringify renders a MIXED tree's canonical form (data nests, file becomes $katari_ref, keys verbatim)", async () => {
    const mixed: Value = {
      kind: "record",
      fields: {
        a: int(1),
        box: { kind: "record", ctor: createAgentName("main.box"), fields: { value: int(3) } },
        special: { kind: "record", fields: { $ref: str("literal") } },
        handle: { kind: "ref", semanticKind: "file", blobId: "blob-x" as BlobId },
      },
    };
    const text = await run("prelude.json.stringify", { value: mixed });
    if (text.kind !== "string") throw new Error("expected a string");
    // A `data` value nests under `$katari_value`; a `file` becomes its `$katari_ref` handle. A record's own
    // keys read VERBATIM — a value-plane `$ref` key (outside the reserved namespace) shows as `$ref`.
    expect(JSON.parse(text.value)).toEqual({
      a: 1,
      box: { $katari_constructor: "main.box", $katari_value: { value: 3 } },
      special: { $ref: "literal" },
      handle: { $katari_ref: "blob-x", $katari_semantic_kind: "file" },
    });
  });

  test("stringify(parse(s)) == s (the document identity law, whitespace aside)", async () => {
    const source = '{"a":[1,2.5],"b":{"$ref":"x"},"c":null}';
    const parsed = await run("prelude.json.parse", { text: str(source) });
    const text = await run("prelude.json.stringify", { value: parsed });
    expect(text).toEqual(str(source));
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
        [createAgentName("main.greeter")]: { block: 0, private: false },
        [createAgentName("main.identity")]: { block: 2, private: false },
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
    // The shape `prelude.mcp.provide` mints: a $katari_tool value carrying its reactor context (opaque to
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

  test("a dangling handle (freed, or a made-up id) throws the catchable `file.gone`", async () => {
    const { context } = await fileContext();
    const dangling: Value = { kind: "ref", semanticKind: "file", blobId: "blob-made-up" as BlobId };
    // A catchable typed throw now, not a panic: a program can recover, and a `replay` converter can select it.
    await expectThrows(
      run("prelude.file.size", { value: dangling }, context),
      "prelude.file.gone",
      /blob-made-up is gone/,
    );
  });

  test("a non-file argument is rejected (a blob-backed string is not a file)", async () => {
    const { context } = await fileContext();
    const stringRef: Value = { kind: "ref", semanticKind: "string", blobId: BLOB };
    await expect(run("prelude.file.read_base64", { value: stringRef }, context)).rejects.toThrow(
      /expected a file/,
    );
  });
});

describe("prelude.file producers (from_base64 / free)", () => {
  const PROJECT_ID = "project-file-producer" as ProjectId;
  const RUN = "run-file-producer" as InstanceId;
  const INSTANCE = "instance-file-producer" as InstanceId;
  // "AQID" is the base64 of the bytes [1, 2, 3].
  const BYTES = new Uint8Array([1, 2, 3]);
  const BASE64 = Buffer.from(BYTES).toString("base64");

  /** A minimal core instance carrying the `runId` the run-ownership check reads. */
  function instanceInRun(id: InstanceId, runId: InstanceId): CoreInstance {
    return {
      kind: "core",
      id,
      delegationId: "d" as DelegationId,
      callerReactor: "core",
      runId,
      target: { kind: "named", name: "demo.main" as never, snapshot: "snap" as SnapshotId },
      argument: null,
      status: "running",
      rootThreadId: toThreadId(0),
      threads: {},
      cancelExits: {},
      finalizers: [],
      phase: { kind: "running" },
      nextThreadId: 0,
      nextCallId: 0,
      nextAskId: 0,
    };
  }

  /** A turn context whose blob write seams are backed by a real `ResourcePool` over a store holding one
   *  running instance of `RUN` — so `from_base64` registers a blob owned by that instance and `free`'s
   *  run-ownership check resolves against it, exactly as the core reactor wires them. */
  function turnContext(): { context: PrimContext; pool: ResourcePool; blobs: InMemoryBlobStore } {
    const store: ProjectStore = {
      instances: { [INSTANCE]: instanceInRun(INSTANCE, RUN) },
      scopes: {},
      scopesByOwner: new Map(),
      nextScopeId: 0,
      blobs: {},
      blobsByOwner: new Map(),
    };
    const pool = new ResourcePool(PROJECT_ID, store);
    const blobs = new InMemoryBlobStore();
    const context: PrimContext = {
      projectId: PROJECT_ID,
      ir: new SnapshotRegistry(),
      blobs,
      blobEntryOf: (blobId) => store.blobs[blobId],
      blobEffects: {
        produce: (blobId, entry) => pool.registerBlob(blobId, { owner: INSTANCE, ...entry }),
        freeInRun: (blobId) => pool.deleteBlobOwnedInRun(blobId, RUN),
      },
    };
    return { context, pool, blobs };
  }

  function refOf(value: Value): BlobId {
    if (value.kind !== "ref") throw new Error("expected a file ref");
    return value.blobId;
  }

  test("from_base64 mints a file whose bytes / type read back, owned by the running instance", async () => {
    const { context } = turnContext();
    const file = await run(
      "prelude.file.from_base64",
      { content: str(BASE64), content_type: str("image/png") },
      context,
    );
    expect(file.kind).toBe("ref");
    if (file.kind === "ref") expect(file.semanticKind).toBe("file");

    // The produced file reads back through the ordinary readers (same context / catalog / byte store).
    await expect(run("prelude.file.read_base64", { value: file }, context)).resolves.toEqual({
      kind: "string",
      value: BASE64,
    });
    await expect(run("prelude.file.content_type", { value: file }, context)).resolves.toEqual({
      kind: "string",
      value: "image/png",
    });
    await expect(run("prelude.file.size", { value: file }, context)).resolves.toEqual({
      kind: "integer",
      value: BYTES.length,
    });
  });

  test("two from_base64 of the SAME bytes are DIFFERENT files (a file is a resource, not a literal)", async () => {
    const { context } = turnContext();
    const first = await run("prelude.file.from_base64", { content: str(BASE64), content_type: str("") }, context);
    const second = await run("prelude.file.from_base64", { content: str(BASE64), content_type: str("") }, context);
    // Distinct blob identities → not `==`: freeing one must never dangle the other's ref.
    expect(refOf(first)).not.toBe(refOf(second));
    expect(valueEquals(first, second)).toBe(false);
  });

  test("malformed base64 throws the catchable `malformed_base64`", async () => {
    const { context } = turnContext();
    await expectThrows(
      run("prelude.file.from_base64", { content: str("not valid base64!!"), content_type: str("") }, context),
      "prelude.file.malformed_base64",
      /not valid base64/,
    );
  });

  test("free reclaims a run-owned file; a later read throws `file.gone`", async () => {
    const { context } = turnContext();
    const file = await run("prelude.file.from_base64", { content: str(BASE64), content_type: str("") }, context);

    await expect(run("prelude.file.free", { value: file }, context)).resolves.toEqual({ kind: "null" });
    // The catalog row is gone the instant it is freed, so the reader reports `gone` (not stale bytes).
    await expectThrows(
      run("prelude.file.read_base64", { value: file }, context),
      "prelude.file.gone",
      /is gone/,
    );
  });

  test("free is idempotent: freeing an already-freed handle is a silent no-op", async () => {
    const { context } = turnContext();
    const file = await run("prelude.file.from_base64", { content: str(BASE64), content_type: str("") }, context);
    await run("prelude.file.free", { value: file }, context);
    // A retried block that frees the same handle again must not throw or diverge.
    await expect(run("prelude.file.free", { value: file }, context)).resolves.toEqual({ kind: "null" });
  });

  test("free cannot reclaim a file the run does not own (an uploaded file stays readable)", async () => {
    const { context, pool, blobs } = turnContext();
    // A user-uploaded file: bytes in the store, its row owned by the api root (an id absent from `instances`),
    // the way an upload registers it — outside any run.
    const uploaded = "blob-uploaded" as BlobId;
    const apiRoot = "instance-api-root" as InstanceId;
    await blobs.put(PROJECT_ID, uploaded, BYTES);
    pool.registerBlob(uploaded, { owner: apiRoot, hash: "h", size: BYTES.length, semanticKind: "file" });
    const file: Value = { kind: "ref", semanticKind: "file", blobId: uploaded };

    await run("prelude.file.free", { value: file }, context);
    // Untouched — freeing another owner's file is a no-op, so it still reads back.
    await expect(run("prelude.file.read_base64", { value: file }, context)).resolves.toEqual({
      kind: "string",
      value: BASE64,
    });
  });
});
