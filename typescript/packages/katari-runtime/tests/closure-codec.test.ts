// Round-trip tests for closure serialize / materialize (#5, eager-ref).
//
// A closure is frozen at its literal into a content blob (its body block +
// snapshot + captured scope chain) and grafted into a receiver with fresh scope
// ids. Closures are always content refs, so a captured closure passes through
// verbatim (no nested serialization). The self-reference var is re-bound to the
// closure's own ref on materialize (recursion = re-materialize).

import { describe, expect, it } from "vitest";
import {
  decodeClosureBlob,
  materializeClosure,
  serializeClosure,
} from "../src/engine/closure-codec.js";
import type { ScopeId } from "../src/engine/id.js";
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
const bid = (n: number) => n as BlockId;

describe("closure-codec", () => {
  it("round-trips a captured scope chain into a fresh shard + re-binds self", async () => {
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

    const { putBytes, getBytes } = makeBlobStore();
    const ref = await serializeClosure(issuer, {
      blockId: bid(42),
      scopeId: sid("inner"),
      snapshot: "snap-1",
      selfVar: 9,
      putBytes,
    });
    expect(ref.module).toBe("core");

    const content = decodeClosureBlob(await getBytes(ref));
    expect(content.blockId).toBe(42);
    expect(content.snapshot).toBe("snap-1");
    expect(content.selfVar).toBe(9);

    const receiver = emptyState();
    const newCid = materializeClosure(content, receiver, ref);
    const record = receiver.closures[newCid];
    expect(record.blockId).toBe(42);

    // Fresh ids, but the chain resolves the captured values.
    const inner = receiver.scopes[record.scopeId];
    expect(inner.values[2]).toEqual(mkString("hi"));
    const root = receiver.scopes[inner.parentId!];
    expect(root.values[1]).toEqual({ kind: "number", value: 10 });
    expect(receiver.scopeCount).toBe(2);
    expect(record.scopeId).not.toBe("inner"); // grafted with a fresh id

    // The self var (9) is re-bound to the closure's OWN ref (recursive
    // self-calls re-materialize the same blob).
    expect(inner.values[9]).toEqual({ kind: "closure", ref });
  });

  it("a captured closure ref passes through verbatim (no nested serialization)", async () => {
    const nestedRef: RefRep = { kind: "ref", module: "core", id: "nested", hash: "hn", size: 5 };
    const issuer = emptyState();
    issuer.scopes[sid("s")] = {
      id: sid("s"),
      parentId: null,
      values: { 5: { kind: "closure", ref: nestedRef } },
    };

    const { putBytes, getBytes } = makeBlobStore();
    const ref = await serializeClosure(issuer, {
      blockId: bid(8),
      scopeId: sid("s"),
      snapshot: "snap",
      selfVar: 1,
      putBytes,
    });
    const content = decodeClosureBlob(await getBytes(ref));
    // The nested closure is already a ref — stored verbatim, only its own blob
    // exists (one putBytes call), not a re-serialized copy.
    expect(content.scopes[0].values[5]).toEqual({ kind: "closure", ref: nestedRef });

    const receiver = emptyState();
    const newCid = materializeClosure(content, receiver, ref);
    const sc = receiver.scopes[receiver.closures[newCid].scopeId];
    expect(sc.values[5]).toEqual({ kind: "closure", ref: nestedRef });
  });

  it("refuses to serialize a closure that captures a secret", async () => {
    const issuer = emptyState();
    issuer.scopes[sid("s")] = {
      id: sid("s"),
      parentId: null,
      values: { 1: { kind: "secret", rep: { kind: "inline", text: "sk-live" } } },
    };
    const { putBytes } = makeBlobStore();
    await expect(
      serializeClosure(issuer, {
        blockId: bid(1),
        scopeId: sid("s"),
        snapshot: "snap",
        selfVar: 0,
        putBytes,
      }),
    ).rejects.toThrow(/secret/);
  });
});
