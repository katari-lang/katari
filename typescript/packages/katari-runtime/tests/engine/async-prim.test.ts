// E0 (async engine) demonstration: content-transform prims materialize ref
// bytes through the injected fetcher. `executePrim` is async; concat awaits
// `materialize` for ref operands and stays direct for inline ones. == / match
// / length never reach here (hash/metadata only).

import { describe, expect, it } from "vitest";
import { executePrim } from "../../src/engine/prim.js";
import type { BytesRep, Value } from "../../src/engine/value.js";
import { mkSecret, mkString } from "../../src/engine/value.js";

// A fetcher backed by an in-memory id → bytes table. Inline reps are decoded
// directly by `materializeText` and never reach here; only refs are fetched.
function fetcher(table: Record<string, string>): (rep: BytesRep) => Promise<Uint8Array> {
  return async (rep) => {
    if (rep.kind === "inline") return new TextEncoder().encode(rep.text);
    const text = table[rep.id];
    if (text === undefined) throw new Error(`no blob for ref ${rep.id}`);
    return new TextEncoder().encode(text);
  };
}

const strRef = (id: string): Value => ({
  kind: "string",
  rep: { kind: "ref", module: "core", id, hash: `h-${id}`, size: 0 },
});

describe("async engine: concat materialize", () => {
  it("joins two inline operands without fetching", async () => {
    const calls: string[] = [];
    const materialize = (rep: BytesRep) => {
      if (rep.kind === "ref") calls.push(rep.id);
      return Promise.resolve(new TextEncoder().encode(rep.kind === "inline" ? rep.text : ""));
    };
    const r = await executePrim("concat", { lhs: mkString("foo"), rhs: mkString("bar") }, materialize);
    expect(r).toEqual(mkString("foobar"));
    expect(calls).toHaveLength(0); // inline path never calls the fetcher
  });

  it("fetches both ref operands and joins their content", async () => {
    const materialize = fetcher({ a: "hello ", b: "world" });
    const r = await executePrim("concat", { lhs: strRef("a"), rhs: strRef("b") }, materialize);
    expect(r).toEqual(mkString("hello world"));
  });

  it("mixes a ref operand with an inline one", async () => {
    const materialize = fetcher({ a: "ref-part/" });
    const r = await executePrim("concat", { lhs: strRef("a"), rhs: mkString("inline-part") }, materialize);
    expect(r).toEqual(mkString("ref-part/inline-part"));
  });

  it("preserves secret taint across a materialized concat", async () => {
    const materialize = fetcher({ a: "plain" });
    const r = await executePrim(
      "concat",
      { lhs: strRef("a"), rhs: mkSecret("token") },
      materialize,
    );
    expect(r).toEqual(mkSecret("plaintoken"));
  });

  it("a pure prim ignores materialize and resolves immediately", async () => {
    const materialize = fetcher({});
    const r = await executePrim(
      "add",
      { lhs: { kind: "number", value: 2 }, rhs: { kind: "number", value: 3 } },
      materialize,
    );
    expect(r).toEqual({ kind: "number", value: 5 });
  });
});
