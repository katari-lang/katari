// Persist-time promotion (E1) + E0 materialize, end-to-end at the value-model
// level: a large inline string promotes to a content-addressed ref at persist,
// and a later concat materializes it back through the injected fetcher. Small
// strings stay inline; secrets are never promoted (no secret refs in v0.1.0).

import { describe, expect, it } from "vitest";
import { executePrim } from "../../src/engine/prim.js";
import { promoteCheckpoint } from "../../src/engine/snapshot.js";
import type { BytesRep, RefRep, Value } from "../../src/engine/value.js";
import { mkSecret, mkString } from "../../src/engine/value.js";
import { hashText } from "../../src/storage/hash.js";

// A minimal value store: promote writes bytes under a fresh id; fetch reads by
// id. Stands in for the host's ValueStore at the engine boundary.
function mockStore() {
  const blobs = new Map<string, Uint8Array>();
  let counter = 0;
  const promote = async (text: string): Promise<RefRep> => {
    const bytes = new TextEncoder().encode(text);
    const id = `blob-${counter++}`;
    blobs.set(id, bytes);
    return { kind: "ref", module: "core", id, hash: hashText(text), size: bytes.length };
  };
  const materialize = (rep: BytesRep): Promise<Uint8Array> => {
    if (rep.kind === "inline") return Promise.resolve(new TextEncoder().encode(rep.text));
    const bytes = blobs.get(rep.id);
    if (bytes === undefined) throw new Error(`no blob for ${rep.id}`);
    return Promise.resolve(bytes);
  };
  return { blobs, promote, materialize };
}

const repOf = (v: Value): BytesRep => {
  if (v.kind !== "string" && v.kind !== "secret") throw new Error("not a byte-seq value");
  return v.rep;
};

describe("persist promotion", () => {
  it("promotes large inline strings, leaves small ones and secrets inline", async () => {
    const { promote, blobs } = mockStore();
    const big = "x".repeat(100);
    const tree = {
      big: mkString(big),
      small: mkString("hi"),
      secret: mkSecret("y".repeat(100)),
      nested: [mkString("z".repeat(100)), { inner: mkString("q".repeat(100)) }],
      // biome-ignore lint/suspicious/noExplicitAny: test tree stands in for a checkpoint
    } as any;

    const promoted = await promoteCheckpoint(tree, promote, 5);

    expect(repOf(promoted.big).kind).toBe("ref");
    expect(repOf(promoted.small).kind).toBe("inline"); // under threshold
    expect(repOf(promoted.secret).kind).toBe("inline"); // secrets never promote
    expect(repOf(promoted.nested[0]).kind).toBe("ref"); // nested in an array
    expect(repOf(promoted.nested[1].inner).kind).toBe("ref"); // deeply nested
    // 3 large strings promoted → 3 blobs (secret excluded).
    expect(blobs.size).toBe(3);
    // The ref's hash is the content hash of the original text.
    expect((repOf(promoted.big) as RefRep).hash).toBe(hashText(big));
  });

  it("a promoted ref round-trips: == by hash, concat by materialize", async () => {
    const { promote, materialize } = mockStore();
    const original = "conversation ".repeat(50);
    const promoted = await promoteCheckpoint(
      // biome-ignore lint/suspicious/noExplicitAny: minimal checkpoint stand-in
      { history: mkString(original) } as any,
      promote,
      5,
    );
    const ref = promoted.history as Value;
    expect(ref.kind).toBe("string");
    expect(repOf(ref).kind).toBe("ref");

    // == against an inline string of the same content: hash match, no fetch.
    const eq = await executePrim("primitive.eq", { lhs: ref, rhs: mkString(original) }, materialize);
    expect(eq).toEqual({ kind: "boolean", value: true });

    // concat materializes the ref and joins.
    const joined = await executePrim("primitive.concat", { lhs: ref, rhs: mkString("!") }, materialize);
    expect(joined).toEqual(mkString(`${original}!`));
  });

  it("already-promoted (ref) strings pass through a second promotion unchanged", async () => {
    const { promote } = mockStore();
    const ref: Value = {
      kind: "string",
      rep: { kind: "ref", module: "core", id: "stable", hash: "h", size: 999 },
    };
    // biome-ignore lint/suspicious/noExplicitAny: minimal checkpoint stand-in
    const promoted = await promoteCheckpoint({ x: ref } as any, promote, 5);
    expect((promoted.x as Value)).toEqual(ref); // same ref id, not re-promoted
  });
});
