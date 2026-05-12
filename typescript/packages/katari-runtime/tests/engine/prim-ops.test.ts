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
    const a = { kind: "array", elements: [num1(1), num1(2)] } as const;
    const b = { kind: "array", elements: [num1(1), num1(2)] } as const;
    expect(valueEquals(a, b)).toBe(true);
  });

  it("fails recoverable on bad args", () => {
    expect(() =>
      executePrim("add", { lhs: { kind: "string", value: "hi" }, rhs: num1(1) }),
    ).toThrow(/invalid args/);
  });
});

describe("engine: runner dispatches prim create without crashing", () => {
  it("runs a parentless prim through create", () => {
    const state = createState({
      metadata: { schemaVersion: 1 },
      name: "test",
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
      handlers: {},
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
    // No errors, no outbound. The prim ran but, having no parent, just
    // sat there — that's fine for the smoke test.
    expect(result.errors).toEqual([]);
    expect(result.outbound).toEqual([]);
  });
});

function num(a: number, b: number) {
  return { lhs: { kind: "number" as const, value: a }, rhs: { kind: "number" as const, value: b } };
}

function num1(n: number) {
  return { kind: "number" as const, value: n };
}
