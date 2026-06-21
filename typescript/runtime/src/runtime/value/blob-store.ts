// BlobStore: the pluggable byte backend behind a blob ref. A blob's metadata (hash / size /
// content_type / semantic_kind) lives in the `blobs` table; its bytes live here, keyed by
// (projectId, blobId). v0.1.0 ships an in-memory implementation as the seam; an FS- or S3-backed store
// drops in behind the same interface without touching the engine.
//
// `getRange` exists for bounded reads of a large blob (a streaming download, a partial materialise)
// without pulling the whole object — the engine's hot path stays bounded even when a value is big.

import type { BlobId, ProjectId } from "../ids.js";

export interface BlobStore {
  /** Store the bytes for a freshly produced blob. Content-addressed callers compute `blobId` upstream. */
  put(projectId: ProjectId, blobId: BlobId, bytes: Uint8Array): Promise<void>;
  /** Fetch a blob's full bytes. Rejects if the blob is absent. */
  get(projectId: ProjectId, blobId: BlobId): Promise<Uint8Array>;
  /** Fetch a half-open byte range `[start, end)` of a blob, for bounded / streaming reads. */
  getRange(projectId: ProjectId, blobId: BlobId, start: number, end: number): Promise<Uint8Array>;
  /** Drop a blob's bytes (its owning instance was released). Idempotent. */
  delete(projectId: ProjectId, blobId: BlobId): Promise<void>;
}

/** The seam implementation: an in-process `Map`. Real persistence (FS / S3) replaces this verbatim. */
export class InMemoryBlobStore implements BlobStore {
  private readonly objects = new Map<string, Uint8Array>();

  private key(projectId: ProjectId, blobId: BlobId): string {
    return `${projectId}/${blobId}`;
  }

  async put(projectId: ProjectId, blobId: BlobId, bytes: Uint8Array): Promise<void> {
    this.objects.set(this.key(projectId, blobId), bytes);
  }

  async get(projectId: ProjectId, blobId: BlobId): Promise<Uint8Array> {
    const bytes = this.objects.get(this.key(projectId, blobId));
    if (bytes === undefined) {
      throw new Error(`blob not found: ${this.key(projectId, blobId)}`);
    }
    return bytes;
  }

  async getRange(
    projectId: ProjectId,
    blobId: BlobId,
    start: number,
    end: number,
  ): Promise<Uint8Array> {
    const bytes = await this.get(projectId, blobId);
    return bytes.slice(start, end);
  }

  async delete(projectId: ProjectId, blobId: BlobId): Promise<void> {
    this.objects.delete(this.key(projectId, blobId));
  }
}
