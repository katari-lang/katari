// Unit test for the shared ResourcePool's two-step reown — the mechanism that lets a value's captured
// resources cross a reactor boundary. The case that matters most is a *run* result: a run root (a core
// instance) RELEASES the result's captured scopes to in-transit as it retires, and the api root REOWNS them
// — the same path a core caller uses for a sub-call. This is what fixes the run-result drop (previously a
// run result's scopes were dropped because the api root never re-owned them).

import { describe, expect, test } from "vitest";
import type { PersistedScope } from "../src/runtime/actor/persistence-codec.js";
import type { PersistenceTx } from "../src/runtime/actor/persistence.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import type { ProjectStore } from "../src/runtime/engine/types.js";
import {
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
  return {
    instances: {},
    scopes: {
      0: { id: toScopeId(0), parentId: null, owner, values: {} },
      1: { id: toScopeId(1), parentId: toScopeId(0), owner, values: { 5: { kind: "integer", value: 1 } } },
      2: { id: toScopeId(2), parentId: toScopeId(1), owner, values: {} },
    },
    nextScopeId: 3,
    blobOwners: {},
  };
}

/** A closure value capturing scope 2 (so its whole chain 2,1,0 is reachable). */
const closure: Value = {
  kind: "closure",
  blockId: 0,
  scopeId: toScopeId(2),
  snapshot: "snap" as SnapshotId,
  module: "",
};

/** A PersistenceTx that only records the scopes written (the rest are no-ops). */
function recordingTx(): { tx: PersistenceTx; scopes: PersistedScope[] } {
  const scopes: PersistedScope[] = [];
  const tx: PersistenceTx = {
    async putDelegation() {},
    async putEscalation() {},
    async putInstance() {},
    async putScope(scope) {
      scopes.push(scope);
    },
    async dropInstance() {},
    async consumeOutbox() {},
    async produceOutbox() {},
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
