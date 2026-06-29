// Mid-call FFI blob production + ascent: a running handler produces a blob (its bytes already staged in the
// BlobStore) and the ffi reactor registers it as owned by the call's instance; on the call's result the base
// reactor's `send` releases it to in-transit (`owner = null`), ready for the core caller to reown. This is the
// producer that makes the symmetric scope/blob ascent fire for an FFI-produced blob.

import { describe, expect, test } from "vitest";
import { FfiReactor } from "../src/runtime/actor/ffi-reactor.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import {
  type BlobId,
  type DelegationId,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";

const PROJECT = "project-ffi-blob" as ProjectId;
const DELEGATION = "delegation-1" as DelegationId;
const SNAPSHOT = "snapshot-1" as SnapshotId;
const BLOB = "blob-produced" as BlobId;

/** Open one in-flight ffi call (an external delegate routed from core), returning the reactor + its store. */
function openCall(): { ffi: FfiReactor; store: ReturnType<typeof createProjectStore> } {
  const store = createProjectStore();
  const pool = new ResourcePool(PROJECT, store);
  const ffi = new FfiReactor(PROJECT, new StubFfiTransport(), pool);
  const delegate: ExternalEvent = {
    kind: "delegate",
    delegation: DELEGATION,
    target: { kind: "external", key: "greet", snapshot: SNAPSHOT },
    argument: null,
    from: "core",
    to: "ffi",
  };
  ffi.react(delegate);
  return { ffi, store };
}

describe("FFI mid-call blob production", () => {
  test("registerProducedBlob owns the blob by the call's instance, then the result releases it to in-transit", () => {
    const { ffi, store } = openCall();

    // Mid-call: the handler produced a blob (bytes already in the BlobStore); register its ownership.
    ffi.registerProducedBlob(DELEGATION, BLOB, { hash: "hash", size: 3, semanticKind: "file" });
    const owner = store.blobs[BLOB]?.owner;
    expect(owner).toBeDefined();
    expect(owner).not.toBeNull();

    // The handler returns the blob handle: completing the call releases the blob to in-transit (owner = null),
    // so the core caller can reown it — the first leg of the ascent.
    ffi.complete({
      delegation: DELEGATION,
      outcome: {
        kind: "result",
        value: { $ref: BLOB, semanticKind: "file", size: 3, hash: "hash" },
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
    ffi.registerProducedBlob("delegation-gone" as DelegationId, BLOB, {
      hash: "hash",
      size: 3,
      semanticKind: "file",
    });
    expect(store.blobs[BLOB]).toBeUndefined();
  });
});
