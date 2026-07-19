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
const CORE_CALLER = "instance-core-caller" as InstanceId;
const SNAPSHOT = "snapshot-1" as SnapshotId;
const BLOB = "blob-produced" as BlobId;

/** Open one in-flight ffi call (an external delegate routed from core), returning the reactor + its pool +
 *  store. `caller` is the core instance that issued the call — the delegate carries it (as the base `send`
 *  would stamp), so a produced blob the result does not carry by value hoists onto it; omit it for the older
 *  cases that predate the hoist. */
function openCall(caller?: InstanceId): {
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
    ...(caller !== undefined ? { caller } : {}),
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

  test("a produced blob the result carries only by id hoists onto the core caller, surviving the call's drop", () => {
    // The handler produced a blob but its result does NOT carry it as a ref (a direct mcp call decoded to a
    // raw `json` tree, where the `$katari_ref` is an inert string). The value-driven release frees nothing, so the
    // call's completion — an upward event — hoists the blob one step onto the core caller that issued the call.
    // It must not be reclaimed by the ephemeral call instance's drop.
    const { ffi, store } = openCall(CORE_CALLER);
    ffi.registerProducedBlob(DELEGATION, BLOB, { hash: "hash", size: 3, semanticKind: "file" });

    ffi.complete({
      delegation: DELEGATION,
      // A scalar result: it captures no resource, so only the hoist moves the produced blob.
      outcome: { kind: "result", value: 42 },
    });

    expect(ffi.drainSends()[0]?.kind).toBe("delegateAck");
    // Hoisted onto the core caller (not released to in-transit, not reclaimed): the caller can still read it.
    expect(store.blobs[BLOB]?.owner).toBe(CORE_CALLER);
    expect([...(store.blobsByOwner.get(CORE_CALLER) ?? [])]).toEqual([BLOB]);
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

  test("a call cancelled before it ever sent an upward event has its produced blob reclaimed (never hoisted)", async () => {
    // The hoist only fires on an upward event. A call cancelled before it acked / escalated sent none, so its
    // produced blob never climbed — even with a known caller — and is reclaimed at the call's drop. This is
    // the one implicit reclaim: a cut prunes exactly what is still below it.
    const { ffi, pool, store } = openCall(CORE_CALLER);
    ffi.registerProducedBlob(DELEGATION, BLOB, { hash: "hash", size: 3, semanticKind: "file" });
    ffi.react({ kind: "terminate", delegation: DELEGATION, from: "core", to: "ffi", run: RUN });
    ffi.complete({ delegation: DELEGATION, outcome: { kind: "cancelled" } });
    expect(ffi.drainSends()[0]?.kind).toBe("terminateAck");
    // Not hoisted onto the caller — no upward event carried it up (it is still the ephemeral call's).
    expect(store.blobs[BLOB]?.owner).not.toBe(CORE_CALLER);
    expect(store.blobs[BLOB]?.owner).toBeDefined();

    await ffi.persist(NO_OP_TX);
    const reclaimedBytes = await pool.persist(NO_OP_TX);
    expect(reclaimedBytes).toContain(BLOB);
    expect(store.blobs[BLOB]).toBeUndefined();
    expect(store.blobsByOwner.get(CORE_CALLER)).toBeUndefined();
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

  test("a typed throw carrying a REAL blob ref releases it for the catcher, not reclaiming it with the failing call", async () => {
    // The handler produced a blob and throws a typed error whose payload carries it as a REAL `$katari_ref`
    // (the callee's unconditional wire decode reconstructs one). The reactor-level throw flows through the
    // base `send`, so the ref is RELEASED to in-transit (owner = null) for a catching handler to reown —
    // rather than left owned by the failing call instance, whose teardown would reclaim the bytes and dangle
    // the catcher's ref.
    const { ffi, pool, store } = openCall(CORE_CALLER);
    ffi.registerProducedBlob(DELEGATION, BLOB, { hash: "hash", size: 3, semanticKind: "file" });

    ffi.complete({
      delegation: DELEGATION,
      outcome: { kind: "throw", error: { $katari_ref: BLOB, $katari_semantic_kind: "file" } },
    });

    // The throw escalates (the call now awaits a caught answer), and the payload's ref rode UP with it.
    expect(ffi.drainSends()[0]?.kind).toBe("escalate");
    expect(store.blobs[BLOB]?.owner).toBeNull();

    // The throw resolves by the run failing: the call is terminated and dropped. Persisting that drop must NOT
    // reclaim the in-transit blob — before the fix it stayed owned by the call instance and its teardown freed
    // the bytes out from under the catcher's ref.
    ffi.react({ kind: "terminate", delegation: DELEGATION, from: "core", to: "ffi", run: RUN });
    await ffi.persist(NO_OP_TX);
    const reclaimedBytes = await pool.persist(NO_OP_TX);
    expect(reclaimedBytes).not.toContain(BLOB);
    expect(store.blobs[BLOB]?.owner).toBeNull();
  });

  test("a typed throw whose payload carries the blob's id only as text HOISTS it onto the caller, surviving teardown", async () => {
    // The blob's id rode only in some text plane the handler will read (the throw payload captures no
    // resource by value), so the hoist — not a value release — is what carries the blob up onto the caller.
    const { ffi, pool, store } = openCall(CORE_CALLER);
    ffi.registerProducedBlob(DELEGATION, BLOB, { hash: "hash", size: 3, semanticKind: "file" });

    ffi.complete({ delegation: DELEGATION, outcome: { kind: "throw", error: "boom" } });
    expect(ffi.drainSends()[0]?.kind).toBe("escalate");
    // Hoisted onto the core caller (not reclaimed, not left on the failing call instance).
    expect(store.blobs[BLOB]?.owner).toBe(CORE_CALLER);

    ffi.react({ kind: "terminate", delegation: DELEGATION, from: "core", to: "ffi", run: RUN });
    await ffi.persist(NO_OP_TX);
    const reclaimedBytes = await pool.persist(NO_OP_TX);
    expect(reclaimedBytes).not.toContain(BLOB);
    expect(store.blobs[BLOB]?.owner).toBe(CORE_CALLER);
  });
});
