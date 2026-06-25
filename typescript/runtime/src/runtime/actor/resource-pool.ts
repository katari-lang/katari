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
// re-written here in the same commit). Blob ownership is updated in memory but not yet persisted (blobs have
// no producer — see `engine/ascent.ts`).

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
  /** Blob ids whose row changed this turn (registered / re-owned) and ids reclaimed this turn — flushed by
   *  `persist`, symmetric to the scope sets. */
  private readonly dirtyBlobs = new Set<BlobId>();
  private readonly freedBlobs = new Set<BlobId>();

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
  }

  /** Reclaim a blob (intra-instance GC / teardown): drop it from the warm store and stage its row deletion.
   *  Freeing the bytes (`BlobStore.delete`) is a separate post-commit step (durable-first). */
  freeBlob(blobId: BlobId): void {
    delete this.store.blobs[blobId];
    this.dirtyBlobs.delete(blobId);
    this.freedBlobs.add(blobId);
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

  /** Write the scopes touched this turn into the transaction: upsert each still-live one (with its current
   *  owner — possibly `null` for one in transit), then delete each one the GC freed. No-op when nothing was
   *  touched. (A scope freed by an instance *drop* is reclaimed by that cascade instead, not here.) */
  async persist(tx: PersistenceTx): Promise<void> {
    for (const scopeId of this.dirty) {
      const scope = this.store.scopes[scopeId];
      if (scope !== undefined) await tx.putScope(serializeScope(this.projectId, scope));
    }
    for (const scopeId of this.freed) await tx.deleteScope(scopeId);
    for (const blobId of this.dirtyBlobs) {
      const blob = this.store.blobs[blobId];
      if (blob !== undefined) await tx.putBlob(serializeBlob(this.projectId, blobId, blob));
    }
    for (const blobId of this.freedBlobs) await tx.dropBlob(blobId);
    this.dirty.clear();
    this.freed.clear();
    this.dirtyBlobs.clear();
    this.freedBlobs.clear();
  }
}
