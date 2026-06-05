// Round-trip tests for closure serialize / materialize (#5, eager-ref).
//
// A closure is frozen at its literal into a content blob — its body block +
// snapshot + captured scope chain + the body's compiled metadata. Captured
// secrets are encrypted at rest; closures are always content refs (a captured
// closure passes through verbatim). The self-reference var is re-bound to the
// closure's own ref on materialize (recursion = re-materialize).

import { randomBytes } from "node:crypto";
import { beforeAll, describe, expect, it } from "vitest";
import {
  decodeClosureBlob,
  materializeClosure,
  serializeClosure,
} from "../src/engine/closure-codec.js";
import type { ScopeId } from "../src/engine/id.js";
import type { State } from "../src/engine/state.js";
import { mkSecret, mkString, type RefRep, type Value } from "../src/engine/value.js";
import type { Block, BlockId, IRModule } from "../src/ir/types.js";
import { resetKeyCacheForTesting } from "../src/secret-crypto.js";

beforeAll(() => {
  if (process.env.KATARI_SECRET_KEY === undefined || process.env.KATARI_SECRET_KEY === "") {
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  }
  resetKeyCacheForTesting();
});

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

/** A BlockAgent whose compiled metadata the closure blob denormalizes. */
function agentBlock(id: number): Block {
  return {
    kind: "blockAgent",
    body: {
      qualifiedName: `m.agent${id}`,
      input: { kind: "inputNamed", body: [] },
      entryBody: 0,
      name: `agent${id}`,
      description: `desc${id}`,
      inputSchema: '{"type":"object"}',
      outputSchema: '{"type":"string"}',
    },
  };
}

function makeIr(blockIds: number[]): IRModule {
  const blocks: Record<number, Block> = {};
  for (const id of blockIds) blocks[id] = agentBlock(id);
  return {
    metadata: { schemaVersion: 1 },
    blocks: blocks as IRModule["blocks"],
    entries: {},
    nameTable: { varNames: {}, blockNames: {} },
  };
}

/** Minimal State — only the fields the codec reads / writes are real. */
function emptyState(ir: IRModule): State {
  return {
    irModule: ir,
    scopes: {},
    closures: {},
    nextClosureId: 0,
    scopeCount: 0,
  } as unknown as State;
}

const sid = (s: string) => s as ScopeId;
const bid = (n: number) => n as BlockId;

describe("closure-codec", () => {
  it("round-trips a captured chain + metadata + re-binds self", async () => {
    const issuer = emptyState(makeIr([42]));
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

    const content = decodeClosureBlob(await getBytes(ref));
    expect(content.blockId).toBe(42);
    expect(content.snapshot).toBe("snap-1");
    expect(content.selfVar).toBe(9);
    // Self-describing metadata denormalized from the BlockAgent.
    expect(content.metadata).toEqual({
      name: "agent42",
      description: "desc42",
      inputSchema: '{"type":"object"}',
      outputSchema: '{"type":"string"}',
    });

    const receiver = emptyState(makeIr([]));
    const newCid = materializeClosure(content, receiver, ref);
    const record = receiver.closures[newCid];
    expect(record.blockId).toBe(42);

    const inner = receiver.scopes[record.scopeId];
    expect(inner.values[2]).toEqual(mkString("hi"));
    const root = receiver.scopes[inner.parentId!];
    expect(root.values[1]).toEqual({ kind: "number", value: 10 });
    expect(record.scopeId).not.toBe("inner"); // grafted with a fresh id

    // The self var (9) is re-bound to the closure's OWN ref.
    expect(inner.values[9]).toEqual({ kind: "closure", ref });
  });

  it("a captured closure ref passes through verbatim (no nested serialization)", async () => {
    const nestedRef: RefRep = { kind: "ref", module: "core", id: "nested", hash: "hn", size: 5 };
    const issuer = emptyState(makeIr([8]));
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
    expect(content.scopes[0].values[5]).toEqual({ kind: "closure", ref: nestedRef });

    const receiver = emptyState(makeIr([]));
    const newCid = materializeClosure(content, receiver, ref);
    const sc = receiver.scopes[receiver.closures[newCid].scopeId];
    expect(sc.values[5]).toEqual({ kind: "closure", ref: nestedRef });
  });

  it("encrypts a captured secret at rest, decrypts it on materialize", async () => {
    const issuer = emptyState(makeIr([1]));
    const secret: Value = mkSecret("sk-live-xyz");
    issuer.scopes[sid("s")] = {
      id: sid("s"),
      parentId: null,
      values: { 1: secret },
    };

    const { putBytes, getBytes } = makeBlobStore();
    const ref = await serializeClosure(issuer, {
      blockId: bid(1),
      scopeId: sid("s"),
      snapshot: "snap",
      selfVar: 0,
      putBytes,
    });

    // At rest the captured secret is an AES-GCM envelope, NOT plaintext.
    const content = decodeClosureBlob(await getBytes(ref));
    const stored = content.scopes[0].values[1] as Record<string, unknown>;
    expect(typeof stored.$envelope).toBe("string");
    expect(stored.kind).toBeUndefined();
    // The plaintext must not appear anywhere in the blob bytes.
    expect(new TextDecoder().decode(await getBytes(ref))).not.toContain("sk-live-xyz");

    // Materialize decrypts it back to the live secret value.
    const receiver = emptyState(makeIr([]));
    const newCid = materializeClosure(content, receiver, ref);
    const sc = receiver.scopes[receiver.closures[newCid].scopeId];
    expect(sc.values[1]).toEqual(secret);
  });
});
