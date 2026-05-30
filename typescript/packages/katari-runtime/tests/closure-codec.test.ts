// Round-trip tests for closure serialize / materialize (#5).
//
// A closure crossing a shard boundary is frozen to a content blob and grafted
// into the receiver with fresh scope ids. These tests exercise the three shapes
// that matter: a plain captured chain, a self-recursive closure, and a nested
// (non-self) closure that promotes to its own ref.

import { describe, expect, it } from "vitest";
import {
  decodeClosureBlob,
  materializeClosure,
  serializeClosure,
} from "../src/engine/closure-codec.js";
import type { ClosureId, ScopeId } from "../src/engine/id.js";
import type { State } from "../src/engine/state.js";
import { mkString, type RefRep, type Value } from "../src/engine/value.js";
import type { BlockId } from "../src/ir/types.js";

function makeBlobStore() {
  const blobs = new Map<string, Uint8Array>();
  let counter = 0;
  return {
    putBytes: async (bytes: Uint8Array): Promise<RefRep> => {
      const id = `blob-${counter++}`;
      blobs.set(id, bytes);
      return { kind: "ref", module: "core", id, hash: id, size: bytes.length };
    },
    getBytes: async (ref: RefRep): Promise<Uint8Array> => {
      const b = blobs.get(ref.id);
      if (b === undefined) throw new Error(`no blob ${ref.id}`);
      return b;
    },
  };
}

/** Minimal State — only the fields the codec reads / writes are real. */
function emptyState(): State {
  return {
    scopes: {},
    closures: {},
    nextClosureId: 0,
    scopeCount: 0,
  } as unknown as State;
}

const sid = (s: string) => s as ScopeId;
const cid = (n: number) => n as ClosureId;
const bid = (n: number) => n as BlockId;

describe("closure-codec", () => {
  it("round-trips a captured scope chain into a fresh shard", async () => {
    const issuer = emptyState();
    issuer.scopes[sid("root")] = {
      id: sid("root"),
      parentId: null,
      values: { 1: { kind: "number", value: 10 } },
    };
    issuer.scopes[sid("inner")] = {
      id: sid("inner"),
      parentId: sid("root"),
      values: { 2: mkString("hi") },
    };
    issuer.closures[cid(0)] = { id: cid(0), blockId: bid(42), scopeId: sid("inner") };

    const { putBytes, getBytes } = makeBlobStore();
    const ref = await serializeClosure(issuer, cid(0), "snap-1", putBytes);
    expect(ref.module).toBe("core");

    const content = decodeClosureBlob(await getBytes(ref));
    expect(content.blockId).toBe(42);
    expect(content.snapshot).toBe("snap-1");

    const receiver = emptyState();
    const newCid = materializeClosure(content, receiver);
    const record = receiver.closures[newCid];
    expect(record.blockId).toBe(42);

    // Fresh ids, but the chain resolves the captured values.
    const inner = receiver.scopes[record.scopeId];
    expect(inner.values[2]).toEqual(mkString("hi"));
    const root = receiver.scopes[inner.parentId!];
    expect(root.values[1]).toEqual({ kind: "number", value: 10 });
    expect(receiver.scopeCount).toBe(2);
    // Grafted with fresh ids (not the issuer's "root" / "inner").
    expect(record.scopeId).not.toBe("inner");
  });

  it("records + re-binds a self-reference (recursive local agent)", async () => {
    const issuer = emptyState();
    issuer.scopes[sid("s")] = {
      id: sid("s"),
      parentId: null,
      values: {
        1: { kind: "number", value: 5 },
        2: { kind: "closure", closureId: cid(0) }, // the agent's own var → itself
      },
    };
    issuer.closures[cid(0)] = { id: cid(0), blockId: bid(7), scopeId: sid("s") };

    const { putBytes, getBytes } = makeBlobStore();
    const ref = await serializeClosure(issuer, cid(0), "snap", putBytes);
    const content = decodeClosureBlob(await getBytes(ref));

    expect(content.selfVar).toBe(2);
    expect(content.scopes[0].values[2]).toBeUndefined(); // self binding omitted
    expect(content.scopes[0].values[1]).toEqual({ kind: "number", value: 5 });

    const receiver = emptyState();
    const newCid = materializeClosure(content, receiver);
    const sc = receiver.scopes[receiver.closures[newCid].scopeId];
    // Self var re-bound to the NEW closure id (not the issuer's id 0).
    expect(sc.values[2]).toEqual({ kind: "closure", closureId: newCid });
  });

  it("promotes a nested (non-self) closure to its own ref", async () => {
    const issuer = emptyState();
    issuer.scopes[sid("n")] = {
      id: sid("n"),
      parentId: null,
      values: { 1: { kind: "number", value: 99 } },
    };
    issuer.closures[cid(1)] = { id: cid(1), blockId: bid(8), scopeId: sid("n") };
    issuer.scopes[sid("o")] = {
      id: sid("o"),
      parentId: null,
      values: { 5: { kind: "closure", closureId: cid(1) } },
    };
    issuer.closures[cid(0)] = { id: cid(0), blockId: bid(9), scopeId: sid("o") };
    issuer.nextClosureId = 2;

    const { putBytes, getBytes } = makeBlobStore();
    const ref = await serializeClosure(issuer, cid(0), "snap", putBytes);
    const content = decodeClosureBlob(await getBytes(ref));

    const nested = content.scopes[0].values[5] as Value;
    expect(nested.kind).toBe("closure");
    expect("ref" in nested).toBe(true); // serialized to its own blob

    const receiver = emptyState();
    const newCid = materializeClosure(content, receiver);
    const sc = receiver.scopes[receiver.closures[newCid].scopeId];
    const mat = sc.values[5] as Value;
    expect(mat.kind).toBe("closure");
    // Stays a ref — a nested closure is materialized lazily, only when invoked.
    expect("ref" in mat).toBe(true);
  });

  it("refuses to serialize a closure that captures a secret", async () => {
    const issuer = emptyState();
    issuer.scopes[sid("s")] = {
      id: sid("s"),
      parentId: null,
      values: { 1: { kind: "secret", rep: { kind: "inline", text: "sk-live" } } },
    };
    issuer.closures[cid(0)] = { id: cid(0), blockId: bid(1), scopeId: sid("s") };

    const { putBytes } = makeBlobStore();
    await expect(serializeClosure(issuer, cid(0), "snap", putBytes)).rejects.toThrow(/secret/);
  });
});
