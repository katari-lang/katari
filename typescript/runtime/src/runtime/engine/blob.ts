// Blob-ownership operations over the per-project blob ledger — the exact counterpart of `scope.ts`'s
// scope-ownership helpers. A blob's `owner` drives the same reclaim / ascent / hoist lifecycle a scope's
// does (a dropping instance's blobs cascade with it; an in-transit blob sits at `owner = null`). These
// helpers keep the derived `blobsByOwner` index in step with every owner change, so the per-owner sweeps
// (an instance teardown, the ownership hoist) read one instance's bucket instead of scanning the whole
// ledger. The bytes themselves live in the `BlobStore`; this touches only the warm `ProjectStore.blobs`
// row (owner + descriptor), exactly as `scope.ts` touches only the scope node.

import type { BlobId, InstanceId } from "../ids.js";
import type { BlobEntry, ProjectStore } from "./types.js";

/** Add `blobId` to `owner`'s bucket in the `blobsByOwner` index (a no-op for an in-transit blob). */
function addOwnedBlob(store: ProjectStore, blobId: BlobId, owner: InstanceId | null): void {
  if (owner === null) return;
  let owned = store.blobsByOwner.get(owner);
  if (owned === undefined) {
    owned = new Set();
    store.blobsByOwner.set(owner, owned);
  }
  owned.add(blobId);
}

/** Drop `blobId` from `owner`'s bucket, removing the bucket once it empties (a no-op for an in-transit
 *  blob or a missing bucket). */
function removeOwnedBlob(store: ProjectStore, blobId: BlobId, owner: InstanceId | null): void {
  if (owner === null) return;
  const owned = store.blobsByOwner.get(owner);
  if (owned === undefined) return;
  owned.delete(blobId);
  if (owned.size === 0) store.blobsByOwner.delete(owner);
}

/** Register a fresh blob entry into the warm store, indexing it under its owner. */
export function registerBlobEntry(store: ProjectStore, blobId: BlobId, entry: BlobEntry): void {
  store.blobs[blobId] = entry;
  addOwnedBlob(store, blobId, entry.owner);
}

/** Re-own a blob, keeping the `blobsByOwner` index in step with `entry.owner` (a no-op if it is absent). */
export function setBlobOwner(
  store: ProjectStore,
  blobId: BlobId,
  newOwner: InstanceId | null,
): void {
  const entry = store.blobs[blobId];
  if (entry === undefined) return;
  removeOwnedBlob(store, blobId, entry.owner);
  entry.owner = newOwner;
  addOwnedBlob(store, blobId, newOwner);
}

/** The blob ids `owner` currently owns (the live `blobsByOwner` bucket, copied so callers may mutate the
 *  store while iterating). */
export function blobsOwnedBy(store: ProjectStore, owner: InstanceId): BlobId[] {
  return [...(store.blobsByOwner.get(owner) ?? [])];
}

/** Delete a blob entry from the store and drop it from its owner's bucket. */
export function deleteBlobEntry(store: ProjectStore, blobId: BlobId): void {
  const entry = store.blobs[blobId];
  if (entry !== undefined) removeOwnedBlob(store, blobId, entry.owner);
  delete store.blobs[blobId];
}

/** Rebuild `blobsByOwner` from the current `blobs` ledger — used after a bulk load / reset replaces the
 *  ledger wholesale (the incremental helpers maintain it during normal operation), mirroring
 *  `rebuildScopeOwnerIndex`. */
export function rebuildBlobOwnerIndex(store: ProjectStore): void {
  store.blobsByOwner = new Map();
  for (const key of Object.keys(store.blobs)) {
    const blobId = key as BlobId;
    const entry = store.blobs[blobId];
    if (entry !== undefined) addOwnedBlob(store, blobId, entry.owner);
  }
}
