// Persist-time promotion (E1) + E0 materialize, end-to-end at the value-model
// level: a large inline string promotes to a content-addressed ref at persist,
// and a later concat materializes it back through the injected fetcher. Small
// strings stay inline; secrets are never promoted (no secret refs in v0.1.0).

import { describe, expect, it } from "vitest";
import { executePrim } from "../../src/engine/prim.js";
import { type EngineCheckpoint, promoteCheckpoint } from "../../src/engine/snapshot.js";
import type { BytesRep, RefRep, Value } from "../../src/engine/value.js";
import { mkRecord, mkSecret, mkString } from "../../src/engine/value.js";
import { hashText } from "../../src/storage/hash.js";

// promoteCheckpoint walks the typed checkpoint structure (threads + scopes are
// the only Value-bearing fields), so a test value is placed in a scope slot and
// recovered from there. The promotion itself still recurses INTO the Value tree
// (arrays / records / nested strings), which is what these tests exercise.
function checkpointWith(value: Value): EngineCheckpoint {
  return {
    schemaVersion: 1,
    selfEndpoint: "core://main" as EngineCheckpoint["selfEndpoint"],
    ffiTargetEndpoint: "ext://ffi" as EngineCheckpoint["ffiTargetEndpoint"],
    envTargetEndpoint: "ext://env" as EngineCheckpoint["envTargetEndpoint"],
    threads: {},
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    scopes: { 1: { id: 1, parentId: null, values: { 0: value } } as any },
    closures: {},
    nextClosureId: 0,
    delegations: {},
    pendingDelegateOut: {},
    delegationSenders: {},
    escalationOwners: {},
    lastGcScopeCount: 0,
  };
}

async function promoteValue(
  value: Value,
  promote: (text: string) => Promise<RefRep>,
  threshold: number,
): Promise<Value> {
  const promoted = await promoteCheckpoint(checkpointWith(value), promote, threshold);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (promoted.scopes as any)[1].values[0] as Value;
}

const recordEntries = (v: Value): Record<string, Value> => {
  if (v.kind !== "record") throw new Error("not a record value");
  return v.entries;
};

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
    // A composite value the promotion recurses through: a record holding scalars,
    // a secret, and a nested array/record of large strings.
    const tree = mkRecord({
      big: mkString(big),
      small: mkString("hi"),
      secret: mkSecret("y".repeat(100)),
      nested: {
        kind: "array",
        elements: [mkString("z".repeat(100)), mkRecord({ inner: mkString("q".repeat(100)) })],
      },
    });

    const promoted = recordEntries(await promoteValue(tree, promote, 5));
    const nested = promoted.nested;
    if (nested.kind !== "array") throw new Error("nested not array");

    expect(repOf(promoted.big).kind).toBe("ref");
    expect(repOf(promoted.small).kind).toBe("inline"); // under threshold
    expect(repOf(promoted.secret).kind).toBe("inline"); // secrets never promote
    expect(repOf(nested.elements[0]!).kind).toBe("ref"); // nested in an array
    expect(repOf(recordEntries(nested.elements[1]!).inner!).kind).toBe("ref"); // deeply nested
    // 3 large strings promoted → 3 blobs (secret excluded).
    expect(blobs.size).toBe(3);
    // The ref's hash is the content hash of the original text.
    expect((repOf(promoted.big) as RefRep).hash).toBe(hashText(big));
  });

  it("a promoted ref round-trips: == by hash, concat by materialize", async () => {
    const { promote, materialize } = mockStore();
    const original = "conversation ".repeat(50);
    const ref = await promoteValue(mkString(original), promote, 5);
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
    const promoted = await promoteValue(ref, promote, 5);
    expect(promoted).toEqual(ref); // same ref id, not re-promoted
  });
});
