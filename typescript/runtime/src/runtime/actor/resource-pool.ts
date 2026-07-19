// ResourcePool: the shared scope (and blob-ownership) resource — an *independent* resource, not CORE-owned.
// CORE allocates scopes and the engine reads / writes their variables, but the scope resource's ownership
// lifecycle and persistence live here, where every reactor's base class reaches them through a narrow
// release / reown / persist view. That sharing is what lets a value's captured resources cross a reactor
// boundary: the sender RELEASES them from its owner (→ in-transit, `owner = null`), the receiver REOWNS them
// to its own owner — a core caller re-owning a sub-call's result, and the api root re-owning a *run* result,
// by the same path. (Physically the scopes still live in the engine's `ProjectStore`; this view touches them
// in place, so the engine code is unchanged.)
//
// Persistence is independent of the instance Layer 2: a turn marks the scopes it touched (the running
// instance's own scopes, plus any whose ownership changed) and `persist` writes exactly those — scopes are
// no longer carried inside `putInstance`. In-memory is the source of truth; a freed scope is reclaimed by its
// owner instance's drop (cascade), and an in-transit scope survives that drop (its `owner = null` row is
// re-written here in the same commit). Blob rows follow the same shape (dirty / freed sets, flushed by
// `persist`); a reclaimed blob's BYTES are deleted from the `BlobStore` strictly after the commit (see
// `reclaimedBytes`).

import { reachableResources } from "../engine/ascent.js";
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
  ) {}

  /** Register a freshly produced blob (a file upload, or a future engine string-promotion) — its ownership +
   *  descriptor, the bytes having already been put to the `BlobStore`. The warm store is the SoT; `persist`
   *  writes the row. */
  registerBlob(blobId: BlobId, entry: BlobEntry): void {
    this.store.blobs[blobId] = entry;
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

  /** Reclaim a single blob found dead by an intra-instance GC: drop it from the warm store, stage its durable
   *  row deletion, and stage its bytes for post-commit deletion. (The teardown path uses `reclaimBlobsOwnedBy`,
   *  which leaves the row to the instance's drop cascade.) */
  freeBlob(blobId: BlobId): void {
    delete this.store.blobs[blobId];
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
    for (const key of Object.keys(this.store.blobs)) {
      const blobId = key as BlobId;
      if (this.store.blobs[blobId]?.owner === instanceId) {
        delete this.store.blobs[blobId];
        this.dirtyBlobs.delete(blobId);
        this.reclaimedBytes.add(blobId);
      }
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

  /** Re-own to `to` each listed blob still owned by `from` — the produced blobs a completing external call
   *  did NOT ascend by value (a direct mcp call's literal `json` tree carries a produced blob as a `$katari_ref`
   *  string, not a real ref, so the value-driven release never freed it from the ephemeral call instance).
   *  Adopting them onto the long-lived run keeps them readable past the call's drop; the run's teardown
   *  reclaims them. A blob already released to in-transit (owner = null, a value-carried one the caller will
   *  reown) does not match `from`, so it is left alone. */
  reassignOwnedBlobs(from: InstanceId, to: InstanceId, blobIds: Iterable<BlobId>): void {
    for (const blobId of blobIds) {
      const blob = this.store.blobs[blobId];
      if (blob?.owner === from) {
        blob.owner = to;
        this.dirtyBlobs.add(blobId);
      }
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
      const blob = this.store.blobs[blobId];
      if (blob?.owner === owner) {
        blob.owner = null;
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
      const blob = this.store.blobs[blobId];
      if (blob?.owner === null) {
        blob.owner = owner;
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
