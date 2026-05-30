// Smoke test for the engine layer:
//   - executePrim returns the right Value for representative prims
//   - the runner can dispatch a PrimThread's `create` event and the prim
//     computes its result without crashing
//
// executePrim is async (content-transform prims may materialize ref bytes);
// these tests use inline values only, so the injected materializer `M` is
// never actually called (it throws if it is, to catch an unexpected fetch).

import { describe, expect, it } from "vitest";
import {
  applyEvent,
  type AskId,
  type CallId,
  CORE_ENDPOINT,
  createScopeId,
  createState,
  createThreadId,
  type Event,
  type PrimThread,
} from "../../src/engine/index.js";
import { executePrim, valueEquals } from "../../src/engine/prim.js";
import { type BytesRep, mkSecret, mkString, type Value } from "../../src/engine/value.js";

const M = async (_rep: BytesRep): Promise<Uint8Array> => {
  throw new Error("prim-ops: unexpected ref materialize (tests use inline values)");
};

describe("engine: prim builtin", () => {
  it("computes arithmetic", async () => {
    expect(await executePrim("add", num(3, 4), M)).toEqual({ kind: "number", value: 7 });
    expect(await executePrim("mul", num(3, 4), M)).toEqual({ kind: "number", value: 12 });
    expect(await executePrim("sub", num(10, 4), M)).toEqual({ kind: "number", value: 6 });
    expect(await executePrim("div", num(10, 4), M)).toEqual({ kind: "number", value: 2.5 });
    expect(await executePrim("mod", num(10, 4), M)).toEqual({ kind: "number", value: 2 });
    expect(await executePrim("neg", { value: num1(7) }, M)).toEqual({ kind: "number", value: -7 });
  });

  it("compares numbers", async () => {
    expect(await executePrim("lt", num(1, 2), M)).toEqual({ kind: "boolean", value: true });
    expect(await executePrim("ge", num(2, 2), M)).toEqual({ kind: "boolean", value: true });
  });

  it("structural equality", () => {
    const a: Value = { kind: "array", elements: [num1(1), num1(2)] };
    const b: Value = { kind: "array", elements: [num1(1), num1(2)] };
    expect(valueEquals(a, b)).toBe(true);
  });

  it("fails recoverable on bad args", async () => {
    await expect(executePrim("add", { lhs: mkString("hi"), rhs: num1(1) }, M)).rejects.toThrow(
      /invalid args/,
    );
  });

  it("concat propagates taint: string + string = string", async () => {
    expect(await executePrim("concat", { lhs: mkString("a"), rhs: mkString("b") }, M)).toEqual(
      mkString("ab"),
    );
  });

  it("concat propagates taint: secret + string = secret", async () => {
    expect(
      await executePrim("concat", { lhs: mkSecret("tok"), rhs: mkString("/api") }, M),
    ).toEqual(mkSecret("tok/api"));
  });

  it("concat propagates taint: string + secret = secret", async () => {
    expect(
      await executePrim("concat", { lhs: mkString("Bearer "), rhs: mkSecret("tok") }, M),
    ).toEqual(mkSecret("Bearer tok"));
  });

  it("format passes secrets through preserving the variant", async () => {
    expect(await executePrim("format", { value: mkSecret("x") }, M)).toEqual(mkSecret("x"));
    expect(await executePrim("format", { value: mkString("x") }, M)).toEqual(mkString("x"));
  });

  it("to_string refuses to launder secret taint into a plain string", async () => {
    await expect(executePrim("to_string", { value: mkSecret("x") }, M)).rejects.toThrow(
      /refusing to stringify a secret/,
    );
  });

  it("record.empty produces an empty record value", async () => {
    const r = await executePrim("record.empty", {}, M);
    expect(r.kind).toBe("record");
    if (r.kind === "record") expect(Object.keys(r.entries)).toEqual([]);
  });

  it("record.set inserts entries copy-on-write", async () => {
    const empty = await executePrim("record.empty", {}, M);
    const r1 = await executePrim(
      "record.set",
      { record: empty, key: mkString("name"), value: mkString("alice") },
      M,
    );
    expect(r1).toEqual({ kind: "record", entries: { name: mkString("alice") } });
    // Original stays empty (immutable).
    if (empty.kind === "record") expect(Object.keys(empty.entries)).toEqual([]);
  });

  it("json.parse wraps each JSON shape in its `primitive.json_*` constructor", async () => {
    expect(await executePrim("json.parse", { text: mkString("null") }, M)).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_null",
      fields: {},
    });
    expect(await executePrim("json.parse", { text: mkString("true") }, M)).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_boolean",
      fields: { value: { kind: "boolean", value: true } },
    });
    expect(await executePrim("json.parse", { text: mkString("42") }, M)).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_integer",
      fields: { value: { kind: "number", value: 42 } },
    });
    expect(await executePrim("json.parse", { text: mkString("3.5") }, M)).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_number",
      fields: { value: { kind: "number", value: 3.5 } },
    });
    expect(await executePrim("json.parse", { text: mkString('"hi"') }, M)).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_string",
      fields: { value: mkString("hi") },
    });
  });

  it("json.parse raises a `json_parse_error` request on malformed input", async () => {
    await expect(executePrim("json.parse", { text: mkString("{") }, M)).rejects.toThrow(
      /raised request 'primitive.json_parse_error'/,
    );
  });

  it("json.stringify is the inverse of json.parse for canonical values", async () => {
    const r = await executePrim("json.parse", { text: mkString('{"a":1,"b":[2,3]}') }, M);
    const s = await executePrim("json.stringify", { value: r }, M);
    expect(s).toEqual(mkString('{"a":1,"b":[2,3]}'));
  });

  it("json.stringify is total over `json` values (no secret refusal path)", async () => {
    // The defensive check fires if a non-json tagged value slips through.
    await expect(executePrim("json.stringify", { value: mkSecret("tok") }, M)).rejects.toThrow(
      /expected a json value, got secret/,
    );
  });
});

describe("engine: runner dispatches prim create without crashing", () => {
  it("runs a parentless prim through create", async () => {
    const state = createState({
      metadata: { schemaVersion: 1 },
      blocks: {},
      entries: {},
      nameTable: { varNames: {}, blockNames: {} },
    });
    const threadId = createThreadId();
    const scopeId = createScopeId();
    state.scopes[scopeId] = { id: scopeId, parentId: null, values: {} };

    const prim: PrimThread = {
      kind: "prim",
      id: threadId,
      parent: null,
      parentCallId: null,
      scopeId,
      status: "running",
      children: {},
      nextCallId: 0 as CallId,
      nextAskId: 0 as AskId,
      askIdMap: {},
      primName: "add",
      args: { lhs: num1(2), rhs: num1(3) },
    };
    state.threads[threadId] = prim;

    const event: Event = {
      from: CORE_ENDPOINT,
      to: CORE_ENDPOINT,
      payload: { kind: "create", threadId },
    };

    const result = await applyEvent(state, event);
    // No outbound. The prim ran but, having no parent, just sat there.
    expect(result.outbound).toEqual([]);
  });
});

function num(a: number, b: number) {
  return { lhs: num1(a), rhs: num1(b) };
}

function num1(n: number): Value {
  return { kind: "number", value: n };
}
