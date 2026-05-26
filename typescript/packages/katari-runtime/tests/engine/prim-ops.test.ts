// Smoke test for the engine layer:
//   - executePrim returns the right Value for representative prims
//   - the runner can dispatch a PrimThread's `create` event and the prim
//     computes its result without crashing
//
// Full integration (parent picks up the prim's done) waits until
// UserThread / collecting threads land in Phase B.4-B.5.

import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createState,
  createScopeId,
  createThreadId,
  CORE_ENDPOINT,
  type AskId,
  type CallId,
  type Event,
  type PrimThread,
} from "../../src/engine/index.js";
import { executePrim, valueEquals } from "../../src/engine/prim.js";
import type { Value } from "../../src/engine/value.js";

describe("engine: prim builtin", () => {
  it("computes arithmetic", () => {
    expect(executePrim("add", num(3, 4))).toEqual({ kind: "number", value: 7 });
    expect(executePrim("mul", num(3, 4))).toEqual({ kind: "number", value: 12 });
    expect(executePrim("sub", num(10, 4))).toEqual({ kind: "number", value: 6 });
    expect(executePrim("div", num(10, 4))).toEqual({ kind: "number", value: 2.5 });
    expect(executePrim("mod", num(10, 4))).toEqual({ kind: "number", value: 2 });
    expect(executePrim("neg", { value: { kind: "number", value: 7 } })).toEqual({ kind: "number", value: -7 });
  });

  it("compares numbers", () => {
    expect(executePrim("lt", num(1, 2))).toEqual({ kind: "boolean", value: true });
    expect(executePrim("ge", num(2, 2))).toEqual({ kind: "boolean", value: true });
  });

  it("structural equality", () => {
    const a: Value = { kind: "array", elements: [num1(1), num1(2)] };
    const b: Value = { kind: "array", elements: [num1(1), num1(2)] };
    expect(valueEquals(a, b)).toBe(true);
  });

  it("fails recoverable on bad args", () => {
    expect(() =>
      executePrim("add", { lhs: { kind: "string", value: "hi" }, rhs: num1(1) }),
    ).toThrow(/invalid args/);
  });

  it("concat propagates taint: string + string = string", () => {
    expect(
      executePrim("concat", {
        lhs: { kind: "string", value: "a" },
        rhs: { kind: "string", value: "b" },
      }),
    ).toEqual({ kind: "string", value: "ab" });
  });

  it("concat propagates taint: secret + string = secret", () => {
    expect(
      executePrim("concat", {
        lhs: { kind: "secret", value: "tok" },
        rhs: { kind: "string", value: "/api" },
      }),
    ).toEqual({ kind: "secret", value: "tok/api" });
  });

  it("concat propagates taint: string + secret = secret", () => {
    expect(
      executePrim("concat", {
        lhs: { kind: "string", value: "Bearer " },
        rhs: { kind: "secret", value: "tok" },
      }),
    ).toEqual({ kind: "secret", value: "Bearer tok" });
  });

  it("format passes secrets through preserving the variant", () => {
    expect(
      executePrim("format", { value: { kind: "secret", value: "x" } }),
    ).toEqual({ kind: "secret", value: "x" });
    expect(
      executePrim("format", { value: { kind: "string", value: "x" } }),
    ).toEqual({ kind: "string", value: "x" });
  });

  it("to_string refuses to launder secret taint into a plain string", () => {
    expect(() =>
      executePrim("to_string", { value: { kind: "secret", value: "x" } }),
    ).toThrow(/refusing to stringify a secret/);
  });

  it("record.empty produces an empty record value", () => {
    const r = executePrim("record.empty", {});
    expect(r.kind).toBe("record");
    if (r.kind === "record") expect(Object.keys(r.entries)).toEqual([]);
  });

  it("record.set inserts entries copy-on-write", () => {
    const empty = executePrim("record.empty", {});
    const r1 = executePrim("record.set", {
      record: empty,
      key: { kind: "string", value: "name" },
      value: { kind: "string", value: "alice" },
    });
    expect(r1).toEqual({
      kind: "record",
      entries: { name: { kind: "string", value: "alice" } },
    });
    // Original stays empty (immutable).
    if (empty.kind === "record") {
      expect(Object.keys(empty.entries)).toEqual([]);
    }
  });

  it("json.parse wraps each JSON shape in its `primitive.json_*` constructor", () => {
    expect(
      executePrim("json.parse", { text: { kind: "string", value: "null" } }),
    ).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_null",
      fields: {},
    });
    expect(
      executePrim("json.parse", { text: { kind: "string", value: "true" } }),
    ).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_boolean",
      fields: { value: { kind: "boolean", value: true } },
    });
    expect(
      executePrim("json.parse", { text: { kind: "string", value: "42" } }),
    ).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_integer",
      fields: { value: { kind: "number", value: 42 } },
    });
    expect(
      executePrim("json.parse", { text: { kind: "string", value: "3.5" } }),
    ).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_number",
      fields: { value: { kind: "number", value: 3.5 } },
    });
    expect(
      executePrim("json.parse", { text: { kind: "string", value: "\"hi\"" } }),
    ).toEqual({
      kind: "tagged",
      ctorId: "primitive.json_string",
      fields: { value: { kind: "string", value: "hi" } },
    });
  });

  it("json.parse raises a `json_parse_error` request on malformed input", () => {
    expect(() =>
      executePrim("json.parse", { text: { kind: "string", value: "{" } }),
    ).toThrow(/raised request 'primitive.json_parse_error'/);
  });

  it("json.stringify is the inverse of json.parse for canonical values", () => {
    const r = executePrim("json.parse", {
      text: { kind: "string", value: "{\"a\":1,\"b\":[2,3]}" },
    });
    const s = executePrim("json.stringify", { value: r });
    expect(s).toEqual({ kind: "string", value: "{\"a\":1,\"b\":[2,3]}" });
  });

  it("json.stringify is total over `json` values (no secret refusal path)", () => {
    // `json` is structurally restricted to the seven json_* ctors, so
    // there's no secret or closure can reach stringify by typing. The
    // defensive check still fires if a non-json tagged value slips
    // through (compiler bug), so verify that path too.
    expect(() =>
      executePrim("json.stringify", {
        value: { kind: "secret", value: "tok" },
      }),
    ).toThrow(/expected a json value, got secret/);
  });
});

describe("engine: runner dispatches prim create without crashing", () => {
  it("runs a parentless prim through create", () => {
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

    const result = applyEvent(state, event);
    // No outbound. The prim ran but, having no parent, just
    // sat there — that's fine for the smoke test.
    expect(result.outbound).toEqual([]);
  });
});

function num(a: number, b: number) {
  return { lhs: { kind: "number" as const, value: a }, rhs: { kind: "number" as const, value: b } };
}

function num1(n: number) {
  return { kind: "number" as const, value: n };
}
