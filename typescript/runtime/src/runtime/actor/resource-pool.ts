// ResourcePool: the shared scope (and blob-ownership) resource — an *independent* resource, not CORE-owned.
// CORE allocates scopes and the engine reads / writes their variables, but the scope resource's ownership
// lifecycle and persistence live here, where every reactor's base class reaches them through a narrow
// release / reown / reassign / persist view.
//
// Two ownership disciplines meet here, differing only for BLOBS:
//   - SCOPES ascend purely value-driven: the sender RELEASES the scopes a crossing value captures from its
//     owner (→ in-transit, `owner = null`), and the receiver REOWNS them to its own owner — a core caller
//     re-owning a sub-call's returned closure, the api root re-owning a *run* result, by the same path. A
//     scope the value did not capture is not reachable from anywhere above, so it is simply reclaimed at its
//     owner's teardown. This is unchanged.
//   - BLOBS additionally HOIST: every observable upward event (a `delegateAck` result, an `escalate`'s
//     carried ask) reassigns ALL of the sending instance's remaining blobs one delegation step up, onto the
//     caller instance — value-carried or not. A text plane (an AI transcript, a `stringify`d JSON tree)
//     carries a blob's id but not its ownership, so a blob a value did NOT reach still has to climb with the
//     event, or an id the caller remembers would dangle the moment the producer instance completes. The
//     hoist (`reassignOwnedBlobs`) is the reactor base's job; this view only supplies the reassign. The one
//     boundary that stays purely value-driven for blobs too is run→api: the run instance is permanent, so
//     hoisting onto it would pin every blob for the run's life (the base skips the hoist there — see
//     `Reactor.send`). The only IMPLICIT blob reclaim left is `reclaimBlobsOwnedBy`, an instance's teardown:
//     a cancel (or a failure) reclaims exactly the blobs still below the cut, since a completed instance
//     hoisted its holdings out on its final upward event before teardown ran.
//
// (Physically the scopes / blobs still live in the engine's `ProjectStore`; this view touches them in place,
// so the engine code is unchanged.)
//
// Persistence is independent of the instance Layer 2: a turn marks the scopes it touched (the running
// instance's own scopes, plus any whose ownership changed) and `persist` writes exactly those — scopes are
// no longer carried inside `putInstance`. In-memory is the source of truth; a freed scope is reclaimed by its
// owner instance's drop (cascade), and an in-transit scope survives that drop (its `owner = null` row is
// re-written here in the same commit). Blob rows follow the same shape (dirty / freed sets, flushed by
// `persist`); a reclaimed blob's BYTES are deleted from the `BlobStore` strictly after the commit (see
// `reclaimedBytes`).

import { reachableResources } from "../engine/ascent.js";
import { blobsOwnedBy, deleteBlobEntry, registerBlobEntry, setBlobOwner } from "../engine/blob.js";
import { deleteScope, scopesOwnedBy, setScopeOwner } from "../engine/scope.js";
import type { BlobEntry, ProjectStore } from "../engine/types.js";
import type { BlobId, InstanceId, ProjectId, ScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { PersistenceTx } from "./persistence.js";
import { serializeBlob, serializeScope } from "./persistence-codec.js";

export class ResourcePool {
  /** Scope ids whose row changed this turn (allocated / mutated / re-owned) — flushed and cleared by
   *  `persist`. Empty for a turn that touched no scope, so `persist` is then a no-op. */
  private readonly dirty = new Set<ScopeId>();
  /** Scope ids freed this turn (intra-instance GC) — their durable row is deleted by `persist`. */
  private readonly freed = new Set<ScopeId>();
  /** Blob ids whose row changed this turn (registered / re-owned) and ids whose row was explicitly dropped this
   *  turn (intra-instance GC) — flushed by `persist`, symmetric to the scope sets. */
  private readonly dirtyBlobs = new Set<BlobId>();
  private readonly freedBlobs = new Set<BlobId>();
  /** Blob ids whose BYTES the substrate must delete from the `BlobStore` strictly AFTER this turn's commit:
   *  once the rows referencing a reclaimed blob are durably gone, its bytes are unreferenced and safe to free
   *  (durable-first — deleting inline would orphan live bytes if the commit then rolled back). Populated by a
   *  reclaim — an intra-instance GC (`freeBlob`) or an owning instance's teardown (`reclaimBlobsOwnedBy`) — and
   *  returned by `persist` for the substrate to act on once the commit succeeds. */
  private readonly reclaimedBytes = new Set<BlobId>();

  constructor(
    private readonly projectId: ProjectId,
    private readonly store: ProjectStore,
    /** Resolve the run an arbitrary blob OWNER belongs to — for `files.free`'s run-scoped reclaim (below). A
     *  `core` engine instance carries its run in the store; a NON-core owner (a long-lived webhook / mcp
     *  serve endpoint call instance a delivery's residual blob hoisted onto) is not in the store, so the actor
     *  wires a resolver spanning every reactor's received edge. The default — a bare pool (a unit test) — sees
     *  only the store's core instances, which is exactly the pre-existing behaviour. */
    private readonly runOfOwner: (owner: InstanceId) => InstanceId | undefined = (owner) =>
      store.instances[owner]?.runId,
  ) {}

  /** Register a freshly produced blob (a file upload, or a future engine string-promotion) — its ownership +
   *  descriptor, the bytes having already been put to the `BlobStore`. The warm store is the SoT; `persist`
   *  writes the row. */
  registerBlob(blobId: BlobId, entry: BlobEntry): void {
    registerBlobEntry(this.store, blobId, entry);
    this.dirtyBlobs.add(blobId);
  }

  /** Free a scope the GC found dead: drop it from the warm store (and the owner index) and stage its durable
   *  row for deletion. */
  free(scopeId: ScopeId): void {
    deleteScope(this.store, scopeId);
    this.dirty.delete(scopeId);
    this.freed.add(scopeId);
  }

  /** Drop the pool's per-turn staging after a poisoned commit. The scope rows themselves live in the engine's
   *  `ProjectStore` (the pool is only a view over them), so they — and the owner index — are cleared and
   *  reloaded by the core reactor's reset, not here; this clears only what the pool itself owns. */
  reset(): void {
    this.dirty.clear();
    this.freed.clear();
    this.dirtyBlobs.clear();
    this.freedBlobs.clear();
    this.reclaimedBytes.clear();
  }

  /** Free a blob on an explicit user delete, but only when `owner` still owns it — the file API deletes
   *  api-root-owned blobs (files) and must not touch one owned by an engine instance (an in-flight FFI
   *  call's mid-call upload). Returns whether the blob existed under `owner` and was freed. There is no
   *  reference check: a live run still holding the deleted blob's ref reads it as gone — the explicit
   *  delete is the user's call. */
  deleteBlobOwnedBy(blobId: BlobId, owner: InstanceId): boolean {
    if (this.store.blobs[blobId]?.owner !== owner) return false;
    this.freeBlob(blobId);
    return true;
  }

  /** Free a blob a program explicitly released via `files.free`, but only when it belongs to `runId`'s run —
   *  the run-scoped counterpart of `deleteBlobOwnedBy`. A produced blob HOISTS up its call chain, so by the
   *  time `free` runs it may be owned by ANY ancestor instance of the run — a core sub-call, or a long-lived
   *  webhook / mcp serve endpoint call instance a delivery's residual blob climbed onto — not just the
   *  current one. So ownership is checked at the RUN, via `runOfOwner` (which resolves both a core instance's
   *  run from the store AND a non-core endpoint call instance's run from its owning reactor), not by a
   *  store-only `core`-instance lookup that would refuse a blob owned by an endpoint call. An api-root-owned
   *  upload is naturally refused: the api root is a sentinel, summoned by no delegation, so it belongs to no
   *  run — `runOfOwner` returns `undefined` for it (a program cannot free a user-uploaded file — the file
   *  API's domain). An in-transit blob (`owner = null`) and another run's blob miss the same way. SILENT and
   *  IDEMPOTENT (no return, no throw): a missing / freed / foreign blob is a no-op, so a retried block that
   *  frees the same handle across attempts behaves identically. */
  deleteBlobOwnedInRun(blobId: BlobId, runId: InstanceId): void {
    const entry = this.store.blobs[blobId];
    if (entry === undefined || entry.owner === null) return;
    if (this.runOfOwner(entry.owner) !== runId) return;
    this.freeBlob(blobId);
  }

  /** Reclaim a single blob found dead by an intra-instance GC: drop it from the warm store, stage its durable
   *  row deletion, and stage its bytes for post-commit deletion. (The teardown path uses `reclaimBlobsOwnedBy`,
   *  which leaves the row to the instance's drop cascade.) */
  freeBlob(blobId: BlobId): void {
    deleteBlobEntry(this.store, blobId);
    this.dirtyBlobs.delete(blobId);
    this.freedBlobs.add(blobId);
    this.reclaimedBytes.add(blobId);
  }

  /** Reclaim every blob a dropping instance still owns — the ones it did NOT ascend out as a result (an
   *  ascending blob was released to in-transit, `owner = null`, before the drop, so it does not match here).
   *  Drop each from the warm store and stage its bytes for post-commit deletion; the durable ROW is removed by
   *  the instance's own drop cascade (the `blobs` FK), so — unlike `freeBlob` — no explicit row delete is
   *  staged. Called from the base reactor's instance-drop path, so it is uniform for a core instance and an ffi
   *  call's instance alike (blob ownership is not a core-only concept). */
  reclaimBlobsOwnedBy(instanceId: InstanceId): void {
    // The `blobsByOwner` index gives this instance's blobs directly, so an instance teardown no longer scans
    // the whole ledger (symmetric to `reclaimScopesOwnedBy` reading `scopesOwnedBy`).
    for (const blobId of blobsOwnedBy(this.store, instanceId)) {
      deleteBlobEntry(this.store, blobId);
      this.dirtyBlobs.delete(blobId);
      this.reclaimedBytes.add(blobId);
    }
  }

  /** Reclaim every scope a dropping instance still owns, mirroring 'reclaimBlobsOwnedBy': drop each from the
   *  warm store (and the owner index); the durable rows are removed by the instance's own drop cascade, so no
   *  explicit row delete is staged. A core teardown already freed its scopes (`teardownInstance`), making this
   *  a no-op there — it exists for the non-core instance kinds (an ffi call holding a closure an inner
   *  delegation returned), which have no engine-side teardown. */
  reclaimScopesOwnedBy(instanceId: InstanceId): void {
    for (const scopeId of scopesOwnedBy(this.store, instanceId)) {
      deleteScope(this.store, scopeId);
      this.dirty.delete(scopeId);
    }
  }

  /** Re-own every blob `from` still holds onto `to` — the primitive the ownership hoist reassigns blobs with:
   *  every blob a completing / escalating instance still owns climbs one delegation step onto its caller,
   *  whether or not the crossing value reached it. Reads the `blobsByOwner` index (a copied bucket, safe to
   *  mutate while iterating), so it never scans the whole ledger. A blob already released to in-transit
   *  (owner = null, a value-carried one the receiver will reown) sits in no bucket, so it is left alone. */
  reassignOwnedBlobs(from: InstanceId, to: InstanceId): void {
    for (const blobId of blobsOwnedBy(this.store, from)) {
      setBlobOwner(this.store, blobId, to);
      this.dirtyBlobs.add(blobId);
    }
  }

  /** Release the resources `value` captures, currently owned by `owner`, to in-transit (`owner = null`) — so
   *  the value's recipient can re-own them rather than have them dropped with `owner`. Only `owner`'s own
   *  resources move; ancestors / others' are left as they are. */
  release(value: Value, owner: InstanceId): void {
    const { scopes, blobs } = reachableResources(this.store, value);
    for (const scopeId of scopes) {
      const scope = this.store.scopes[scopeId];
      if (scope?.owner === owner) {
        setScopeOwner(this.store, scope, null);
        this.dirty.add(scopeId);
      }
    }
    for (const blobId of blobs) {
      if (this.store.blobs[blobId]?.owner === owner) {
        setBlobOwner(this.store, blobId, null);
        this.dirtyBlobs.add(blobId);
      }
    }
  }

  /** Claim the in-transit resources `value` captures (`owner = null` → `owner`). Resources already owned (by
   *  this owner or an ancestor) are left as they are. */
  reown(value: Value, owner: InstanceId): void {
    const { scopes, blobs } = reachableResources(this.store, value);
    for (const scopeId of scopes) {
      const scope = this.store.scopes[scopeId];
      if (scope?.owner === null) {
        setScopeOwner(this.store, scope, owner);
        this.dirty.add(scopeId);
      }
    }
    for (const blobId of blobs) {
      if (this.store.blobs[blobId]?.owner === null) {
        setBlobOwner(this.store, blobId, owner);
        this.dirtyBlobs.add(blobId);
      }
    }
  }

  /** Mark every scope `owner` still holds as touched this turn — the engine mutates the running instance's
   *  scopes in place (allocate, bind a variable) without going through this view, so the reactor flushes the
   *  owner's scopes wholesale after its turn. (A dropping instance does NOT call this: its scopes are freed
   *  by the drop cascade, and the ones its result released are already in the dirty set as in-transit.) */
  markOwnedDirty(owner: InstanceId): void {
    for (const scopeId of scopesOwnedBy(this.store, owner)) this.dirty.add(scopeId);
  }

  /** Write the scopes / blobs touched this turn into the transaction: upsert each still-live one (with its
   *  current owner — possibly `null` for one in transit), then delete each row the GC freed. No-op when nothing
   *  was touched. (A scope / blob row freed by an instance *drop* is reclaimed by that cascade instead, not
   *  here.) Returns the blob ids whose BYTES the substrate must delete from the `BlobStore` AFTER the commit —
   *  the durable-first byte reclaim (rows gone ⇒ bytes unreferenced). */
  async persist(tx: PersistenceTx): Promise<BlobId[]> {
    const pool = tx.pool;
    for (const scopeId of this.dirty) {
      const scope = this.store.scopes[scopeId];
      if (scope !== undefined) await pool.putScope(serializeScope(this.projectId, scope));
    }
    for (const scopeId of this.freed) await pool.deleteScope(scopeId);
    for (const blobId of this.dirtyBlobs) {
      const blob = this.store.blobs[blobId];
      if (blob !== undefined) await pool.putBlob(serializeBlob(this.projectId, blobId, blob));
    }
    for (const blobId of this.freedBlobs) await pool.dropBlob(blobId);
    const reclaimedBytes = [...this.reclaimedBytes];
    this.dirty.clear();
    this.freed.clear();
    this.dirtyBlobs.clear();
    this.freedBlobs.clear();
    this.reclaimedBytes.clear();
    return reclaimedBytes;
  }
}
