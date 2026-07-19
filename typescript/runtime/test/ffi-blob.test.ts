// Mid-call FFI blob production + ascent: a running handler produces a blob (its bytes already staged in the
// BlobStore) and the ffi reactor registers it as owned by the call's instance; on the call's result the base
// reactor's `send` releases it to in-transit (`owner = null`), ready for the core caller to reown. This is the
// producer that makes the symmetric scope/blob ascent fire for an FFI-produced blob.

import { describe, expect, test } from "vitest";
import { FfiReactor } from "../src/runtime/actor/ffi-reactor.js";
import { NO_OP_TX } from "../src/runtime/actor/persistence.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import {
  type BlobId,
  type DelegationId,
  type InstanceId,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";

const PROJECT = "project-ffi-blob" as ProjectId;
const DELEGATION = "delegation-1" as DelegationId;
const RUN = "run-1" as InstanceId;
const SNAPSHOT = "snapshot-1" as SnapshotId;
const BLOB = "blob-produced" as BlobId;

/** Open one in-flight ffi call (an external delegate routed from core), returning the reactor + its pool +
 *  store. */
function openCall(): {
  ffi: FfiReactor;
  pool: ResourcePool;
  store: ReturnType<typeof createProjectStore>;
} {
  const store = createProjectStore();
  const pool = new ResourcePool(PROJECT, store);
  const ffi = new FfiReactor(PROJECT, new StubFfiTransport(), pool, new SnapshotRegistry());
  const delegate: ExternalEvent = {
    kind: "delegate",
    delegation: DELEGATION,
    target: { kind: "external", key: "greet", snapshot: SNAPSHOT },
    argument: null,
    from: "core",
    to: "ffi",
    run: RUN,
  };
  ffi.react(delegate);
  return { ffi, pool, store };
}

describe("FFI mid-call blob production", () => {
  test("registerProducedBlob owns the blob by the call's instance, then the result releases it to in-transit", () => {
    const { ffi, store } = openCall();

    // Mid-call: the handler produced a blob (bytes already in the BlobStore); register its ownership.
    const registered = ffi.registerProducedBlob(DELEGATION, BLOB, {
      hash: "hash",
      size: 3,
      semanticKind: "file",
    });
    expect(registered).toBe(true);
    const owner = store.blobs[BLOB]?.owner;
    expect(owner).toBeDefined();
    expect(owner).not.toBeNull();

    // The handler returns the blob handle: completing the call releases the blob to in-transit (owner = null),
    // so the core caller can reown it — the first leg of the ascent.
    ffi.complete({
      delegation: DELEGATION,
      outcome: {
        kind: "result",
        value: { $katari_ref: BLOB, $katari_semantic_kind: "file", size: 3, hash: "hash" },
      },
    });
    expect(store.blobs[BLOB]?.owner).toBeNull();

    // The call acked its caller (core) with the blob-carrying result.
    const sends = ffi.drainSends();
    expect(sends).toHaveLength(1);
    expect(sends[0]?.kind).toBe("delegateAck");
  });

  test("registerProducedBlob is a no-op for an unknown delegation (the call already gone)", () => {
    const { ffi, store } = openCall();
    const registered = ffi.registerProducedBlob("delegation-gone" as DelegationId, BLOB, {
      hash: "hash",
      size: 3,
      semanticKind: "file",
    });
    expect(registered).toBe(false);
    expect(store.blobs[BLOB]).toBeUndefined();
  });

  test("a produced blob the cancelled call never returned has its bytes reclaimed at the call's drop", async () => {
    const { ffi, pool, store } = openCall();

    // The handler produced a blob (owned by the call), but the call is cancelled before it could return it:
    // a `terminate` then the transport's `cancelled` confirmation drop the call, leaving the blob owned.
    ffi.registerProducedBlob(DELEGATION, BLOB, { hash: "hash", size: 3, semanticKind: "file" });
    ffi.react({ kind: "terminate", delegation: DELEGATION, from: "core", to: "ffi", run: RUN });
    ffi.complete({ delegation: DELEGATION, outcome: { kind: "cancelled" } });
    expect(ffi.drainSends()[0]?.kind).toBe("terminateAck");

    // Persisting the call's drop reclaims the blob it still owned: the base reactor's instance-drop path frees
    // it from the warm store, and the pool reports its bytes for the post-commit BlobStore delete.
    await ffi.persist(NO_OP_TX);
    const reclaimedBytes = await pool.persist(NO_OP_TX);
    expect(reclaimedBytes).toContain(BLOB);
    expect(store.blobs[BLOB]).toBeUndefined();
  });
});
