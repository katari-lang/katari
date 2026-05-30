// Content-reading prims handle ref operands (not just concat). Once persist
// promotion makes a large string a ref, these must materialize it rather than
// throw — to_string / from_string / json.* and record-key reads.

import { describe, expect, it } from "vitest";
import { executePrim } from "../../src/engine/prim.js";
import type { BytesRep, Value } from "../../src/engine/value.js";
import { mkString } from "../../src/engine/value.js";

// id → text table; refs resolve through it, inline reps decode directly.
function fetcher(table: Record<string, string>): (rep: BytesRep) => Promise<Uint8Array> {
  return (rep) =>
    Promise.resolve(
      new TextEncoder().encode(rep.kind === "inline" ? rep.text : (table[rep.id] ?? "")),
    );
}

const strRef = (id: string): Value => ({
  kind: "string",
  rep: { kind: "ref", module: "core", id, hash: `h-${id}`, size: 0 },
});

describe("ref-aware content prims", () => {
  it("to_string materializes a ref string", async () => {
    const m = fetcher({ s: "hello world" });
    const r = await executePrim("to_string", { value: strRef("s") }, m);
    expect(r).toEqual(mkString(JSON.stringify("hello world")));
  });

  it("to_string materializes ref strings nested in an array", async () => {
    const m = fetcher({ a: "x", b: "y" });
    const arr: Value = { kind: "array", elements: [strRef("a"), strRef("b")] };
    const r = await executePrim("to_string", { value: arr }, m);
    expect(r).toEqual(mkString(JSON.stringify(["x", "y"])));
  });

  it("from_string materializes a ref JSON string and parses it", async () => {
    const m = fetcher({ j: '{"hello":true}' });
    const r = await executePrim("from_string", { text: strRef("j") }, m);
    // from_string decodes via valueFromRaw → a record value.
    expect(r.kind).toBe("record");
    if (r.kind === "record") {
      expect(r.entries.hello).toEqual({ kind: "boolean", value: true });
    }
  });

  it("record.get materializes a ref key", async () => {
    const m = fetcher({ k: "name" });
    const record: Value = { kind: "record", entries: { name: mkString("ada") } };
    const r = await executePrim("record.get", { record, key: strRef("k") }, m);
    expect(r).toEqual(mkString("ada"));
  });

  it("record.has materializes a ref key", async () => {
    const m = fetcher({ k: "present" });
    const record: Value = { kind: "record", entries: { present: { kind: "null" } } };
    const r = await executePrim("record.has", { record, key: strRef("k") }, m);
    expect(r).toEqual({ kind: "boolean", value: true });
  });

  it("inline operands still work (no fetch path)", async () => {
    const m = fetcher({});
    expect(await executePrim("to_string", { value: mkString("hi") }, m)).toEqual(
      mkString(JSON.stringify("hi")),
    );
  });
});
