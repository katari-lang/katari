// Unit test for the resource walker behind scope / blob ascent: it must find every scope a closure
// captures (the whole lexical chain) and every blob a value references, through nested records / arrays.

import { describe, expect, test } from "vitest";
import { reachableResources } from "../src/runtime/engine/ascent.js";
import type { ProjectStore } from "../src/runtime/engine/types.js";
import type { BlobId, SnapshotId } from "../src/runtime/ids.js";
import { toScopeId } from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

describe("reachableResources", () => {
  test("collects a closure's whole scope chain and every blob ref, through nesting", () => {
    // scope 2 -> 1 -> 0 (root). A closure captures scope 2, so the chain 2,1,0 is reachable.
    const store: ProjectStore = {
      instances: {},
      scopes: {
        0: { id: toScopeId(0), parentId: null, owner: null, values: {} },
        1: { id: toScopeId(1), parentId: toScopeId(0), owner: null, values: {} },
        2: { id: toScopeId(2), parentId: toScopeId(1), owner: null, values: {} },
      },
      nextScopeId: 3,
      blobOwners: {},
    };
    const value: Value = {
      kind: "record",
      fields: {
        f: {
          kind: "closure",
          blockId: 0,
          scopeId: toScopeId(2),
          snapshot: "snap" as SnapshotId,
          module: "",
        },
        g: {
          kind: "array",
          elements: [
            { kind: "integer", value: 1 },
            { kind: "ref", semanticKind: "file", blobId: "blob-a" as BlobId, hash: "h", size: 9 },
          ],
        },
      },
    };

    const { scopes, blobs } = reachableResources(store, value);
    expect([...scopes].sort((left, right) => left - right)).toEqual([
      toScopeId(0),
      toScopeId(1),
      toScopeId(2),
    ]);
    expect([...blobs]).toEqual(["blob-a" as BlobId]);
  });

  test("a scalar captures no resources", () => {
    const store: ProjectStore = { instances: {}, scopes: {}, nextScopeId: 0, blobOwners: {} };
    const { scopes, blobs } = reachableResources(store, { kind: "integer", value: 42 });
    expect(scopes.size).toBe(0);
    expect(blobs.size).toBe(0);
  });
});
