// The file API's explicit delete, through the actor: an uploaded (api-root-owned) blob's row is freed in
// the delete commit and its BYTES are deleted from the `BlobStore` strictly after that commit (the
// substrate's durable-first byte reclaim). This is the reclamation path for files — engine-owned blobs are
// reclaimed by their owner's lifecycle instead, and must refuse this delete.

import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import type { BlobId, ProjectId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-file-delete" as ProjectId;
const FILE = "blob-file" as BlobId;

/** An `InMemoryBlobStore` that records byte deletions — the post-commit reclaim is fire-and-forget, so the
 *  test polls this record rather than racing the store's map. */
class RecordingBlobStore extends InMemoryBlobStore {
  readonly deleted: BlobId[] = [];

  override async delete(projectId: ProjectId, blobId: BlobId): Promise<void> {
    this.deleted.push(blobId);
    await super.delete(projectId, blobId);
  }
}

/** Spin the event loop until `predicate` holds (the byte reclaim runs after the delete commit resolves). */
async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

function makeActor(blobs: RecordingBlobStore): ProjectActor {
  return new ProjectActor({
    projectId: PROJECT,
    ir: new SnapshotRegistry(),
    prims: new PrimRegistry(),
    blobs,
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    persistence: new InMemoryPersistence(),
  });
}

describe("file delete through the actor", () => {
  test("upload then delete: the row's commit resolves true, then the bytes are reclaimed", async () => {
    const blobs = new RecordingBlobStore();
    const actor = makeActor(blobs);
    await blobs.put(PROJECT, FILE, new Uint8Array([1, 2, 3]));
    await actor.uploadBlob(FILE, { hash: "hash", size: 3, semanticKind: "file" });

    expect(await actor.deleteBlob(FILE)).toBe(true);
    await waitUntil(() => blobs.deleted.includes(FILE));
    await expect(blobs.get(PROJECT, FILE)).rejects.toThrow(/not found/);

    // The file is gone, so a repeat delete is a plain miss (the API's 404).
    expect(await actor.deleteBlob(FILE)).toBe(false);
  });

  test("deleting an unknown file resolves false without touching the store", async () => {
    const blobs = new RecordingBlobStore();
    const actor = makeActor(blobs);
    expect(await actor.deleteBlob("blob-unknown" as BlobId)).toBe(false);
    expect(blobs.deleted).toEqual([]);
  });
});
