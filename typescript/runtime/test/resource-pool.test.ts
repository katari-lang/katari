// Unit test for the shared ResourcePool's two-step reown — the mechanism that lets a value's captured
// resources cross a reactor boundary. The case that matters most is a *run* result: a run root (a core
// instance) RELEASES the result's captured scopes to in-transit as it retires, and the api root REOWNS them
// — the same path a core caller uses for a sub-call. This is what fixes the run-result drop (previously a
// run result's scopes were dropped because the api root never re-owned them).

import { describe, expect, test } from "vitest";
import type { PersistedScope } from "../src/runtime/actor/persistence-codec.js";
import { NO_OP_TX, type PersistenceTx } from "../src/runtime/actor/persistence.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import { rebuildScopeOwnerIndex } from "../src/runtime/engine/scope.js";
import type { BlobEntry, ProjectStore } from "../src/runtime/engine/types.js";
import {
  type BlobId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
  toScopeId,
} from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-pool" as ProjectId;
const RUN_ROOT = "instance-run-root" as InstanceId;
const API_ROOT = "api-root" as InstanceId;

/** A store with a closure's scope chain 2 -> 1 -> 0, all owned by `owner`. */
function storeOwnedBy(owner: InstanceId): ProjectStore {
  const store: ProjectStore = {
    instances: {},
    scopes: {
      0: { id: toScopeId(0), parentId: null, owner, values: {} },
      1: { id: toScopeId(1), parentId: toScopeId(0), owner, values: { 5: { kind: "integer", value: 1 } } },
      2: { id: toScopeId(2), parentId: toScopeId(1), owner, values: {} },
    },
    scopesByOwner: new Map(),
    nextScopeId: 3,
    blobs: {},
  };
  rebuildScopeOwnerIndex(store);
  return store;
}

/** A closure value capturing scope 2 (so its whole chain 2,1,0 is reachable). */
const closure: Value = {
  kind: "closure",
  blockId: 0,
  scopeId: toScopeId(2),
  snapshot: "snap" as SnapshotId,
  module: "",
};

/** A PersistenceTx whose `pool` port records the scopes written (every other port is a no-op). Built off the
 *  shared `NO_OP_TX`, so it never drifts from the interface. */
function recordingTx(): { tx: PersistenceTx; scopes: PersistedScope[] } {
  const scopes: PersistedScope[] = [];
  const tx: PersistenceTx = {
    ...NO_OP_TX,
    pool: {
      ...NO_OP_TX.pool,
      async putScope(scope) {
        scopes.push(scope);
      },
    },
  };
  return { tx, scopes };
}

describe("ResourcePool", () => {
  test("a run result's scopes release to in-transit, then reown to the api root (not dropped)", async () => {
    const store = storeOwnedBy(RUN_ROOT);
    const pool = new ResourcePool(PROJECT, store);

    // The run root retires: it releases the result's captured scopes to in-transit (owner = null).
    pool.release(closure, RUN_ROOT);
    for (const id of [0, 1, 2]) expect(store.scopes[id]?.owner).toBeNull();

    // That release is persisted (owner = null) — the in-transit row survives the run root's drop cascade.
    const released = recordingTx();
    await pool.persist(released.tx);
    expect(released.scopes.map((scope) => scope.scopeId).sort()).toEqual([0, 1, 2]);
    expect(released.scopes.every((scope) => scope.ownerInstanceId === null)).toBe(true);

    // The api root reowns the result (the fix): the scopes now belong to the permanent api root, so the
    // returned closure stays callable rather than dropping with the run root.
    pool.reown(closure, API_ROOT);
    for (const id of [0, 1, 2]) expect(store.scopes[id]?.owner).toBe(API_ROOT);

    const reowned = recordingTx();
    await pool.persist(reowned.tx);
    expect(reowned.scopes.map((scope) => scope.scopeId).sort()).toEqual([0, 1, 2]);
    expect(reowned.scopes.every((scope) => scope.ownerInstanceId === API_ROOT)).toBe(true);
  });

  test("persist is a no-op when no scope was touched, and reown only claims in-transit scopes", async () => {
    const store = storeOwnedBy(RUN_ROOT);
    const pool = new ResourcePool(PROJECT, store);

    // Nothing touched yet → no writes.
    const untouched = recordingTx();
    await pool.persist(untouched.tx);
    expect(untouched.scopes).toHaveLength(0);

    // reown leaves scopes already owned by someone else (not in-transit) alone.
    pool.reown(closure, API_ROOT);
    for (const id of [0, 1, 2]) expect(store.scopes[id]?.owner).toBe(RUN_ROOT);
    const afterReown = recordingTx();
    await pool.persist(afterReown.tx);
    expect(afterReown.scopes).toHaveLength(0);
  });

  test("markOwnedDirty flushes the scopes a running instance mutated this turn", async () => {
    const store = storeOwnedBy(RUN_ROOT);
    const pool = new ResourcePool(PROJECT, store);

    pool.markOwnedDirty(RUN_ROOT);
    const flushed = recordingTx();
    await pool.persist(flushed.tx);
    expect(flushed.scopes.map((scope) => scope.scopeId).sort()).toEqual([0, 1, 2]);
    expect(flushed.scopes.every((scope) => scope.ownerInstanceId === RUN_ROOT)).toBe(true);

    // The dirty set cleared after the flush.
    const again = recordingTx();
    await pool.persist(again.tx);
    expect(again.scopes).toHaveLength(0);
  });
});

describe("ResourcePool blob reclaim", () => {
  const OWNER = "instance-blob-owner" as InstanceId;
  const OTHER = "instance-blob-other" as InstanceId;
  const MINE = "blob-mine" as BlobId;
  const THEIRS = "blob-theirs" as BlobId;
  const TRANSIT = "blob-transit" as BlobId;

  const blobEntry = (owner: InstanceId | null): BlobEntry => ({
    owner,
    hash: "hash",
    size: 3,
    semanticKind: "file",
  });

  /** A store seeded with blobs only (no scopes); `owners` maps each blob id to its owner. */
  function storeWithBlobs(owners: Record<string, InstanceId | null>): ProjectStore {
    const blobs: Record<string, BlobEntry> = {};
    for (const [blobId, owner] of Object.entries(owners)) blobs[blobId] = blobEntry(owner);
    return {
      instances: {},
      scopes: {},
      scopesByOwner: new Map(),
      nextScopeId: 0,
      blobs,
    };
  }

  /** A PersistenceTx whose `pool` port records the blob rows written / dropped. */
  function recordingBlobTx(): { tx: PersistenceTx; put: BlobId[]; dropped: BlobId[] } {
    const put: BlobId[] = [];
    const dropped: BlobId[] = [];
    const tx: PersistenceTx = {
      ...NO_OP_TX,
      pool: {
        ...NO_OP_TX.pool,
        async putBlob(blob) {
          put.push(blob.blobId);
        },
        async dropBlob(blobId) {
          dropped.push(blobId);
        },
      },
    };
    return { tx, put, dropped };
  }

  test("reclaimBlobsOwnedBy frees the owner's blobs' bytes (row via cascade), leaving other owners' alone", async () => {
    const store = storeWithBlobs({ [MINE]: OWNER, [THEIRS]: OTHER, [TRANSIT]: null });
    const pool = new ResourcePool(PROJECT, store);

    pool.reclaimBlobsOwnedBy(OWNER);
    // Only the dropping instance's own blob leaves the warm store; another owner's and an in-transit one stay.
    expect(store.blobs[MINE]).toBeUndefined();
    expect(store.blobs[THEIRS]).toBeDefined();
    expect(store.blobs[TRANSIT]).toBeDefined();

    const { tx, put, dropped } = recordingBlobTx();
    const reclaimed = await pool.persist(tx);
    // Its bytes are reported for post-commit deletion; its ROW is left to the instance's drop cascade (no
    // explicit dropBlob), and nothing it owned is re-upserted.
    expect(reclaimed).toEqual([MINE]);
    expect(dropped).toEqual([]);
    expect(put).toEqual([]);

    // The reclaimed-bytes set cleared after the flush.
    expect(await pool.persist(recordingBlobTx().tx)).toEqual([]);
  });

  test("freeBlob drops the row AND frees the bytes (intra-instance GC)", async () => {
    const store = storeWithBlobs({ [MINE]: OWNER });
    const pool = new ResourcePool(PROJECT, store);

    pool.freeBlob(MINE);
    expect(store.blobs[MINE]).toBeUndefined();

    const { tx, dropped } = recordingBlobTx();
    const reclaimed = await pool.persist(tx);
    expect(reclaimed).toEqual([MINE]);
    expect(dropped).toEqual([MINE]);
  });
});
