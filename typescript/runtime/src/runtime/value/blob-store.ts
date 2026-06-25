// BlobStore: the pluggable byte backend behind a blob ref. A blob's metadata (hash / size /
// content_type / semantic_kind) lives in the `blobs` table; its bytes live here, keyed by
// (projectId, blobId). Ships an in-memory store (the dev seam) and an S3-backed store for production —
// both behind the one interface, so the engine and the file API are unchanged by the choice.
//
// `getRange` exists for bounded reads of a large blob (a streaming download, a partial materialise)
// without pulling the whole object — the engine's hot path stays bounded even when a value is big.

import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
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

/** S3 connection config for a blob store (an AWS bucket, or any S3-compatible endpoint like MinIO). */
export interface BlobS3Config {
  bucket: string;
  region: string;
  /** A non-AWS endpoint (e.g. MinIO); omitted for real AWS S3. */
  endpoint?: string;
  /** Path-style addressing (`endpoint/bucket/key`), which MinIO and most S3-compatible servers need. */
  forcePathStyle: boolean;
}

/** The production store: one S3 object per blob, keyed `{projectId}/{blobId}`. Credentials come from the
 *  standard AWS chain (the SDK reads `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / a profile / a role). */
export class S3BlobStore implements BlobStore {
  private readonly client: S3Client;

  constructor(private readonly config: BlobS3Config) {
    this.client = new S3Client({
      region: config.region,
      ...(config.endpoint !== undefined ? { endpoint: config.endpoint } : {}),
      forcePathStyle: config.forcePathStyle,
    });
  }

  private key(projectId: ProjectId, blobId: BlobId): string {
    return `${projectId}/${blobId}`;
  }

  async put(projectId: ProjectId, blobId: BlobId, bytes: Uint8Array): Promise<void> {
    await this.client.send(
      new PutObjectCommand({
        Bucket: this.config.bucket,
        Key: this.key(projectId, blobId),
        Body: bytes,
        ContentLength: bytes.byteLength,
      }),
    );
  }

  async get(projectId: ProjectId, blobId: BlobId): Promise<Uint8Array> {
    const response = await this.client.send(
      new GetObjectCommand({ Bucket: this.config.bucket, Key: this.key(projectId, blobId) }),
    );
    if (response.Body === undefined)
      throw new Error(`blob not found: ${this.key(projectId, blobId)}`);
    return response.Body.transformToByteArray();
  }

  async getRange(
    projectId: ProjectId,
    blobId: BlobId,
    start: number,
    end: number,
  ): Promise<Uint8Array> {
    // HTTP byte ranges are inclusive; the interface's `end` is exclusive.
    const response = await this.client.send(
      new GetObjectCommand({
        Bucket: this.config.bucket,
        Key: this.key(projectId, blobId),
        Range: `bytes=${start}-${end - 1}`,
      }),
    );
    if (response.Body === undefined)
      throw new Error(`blob not found: ${this.key(projectId, blobId)}`);
    return response.Body.transformToByteArray();
  }

  async delete(projectId: ProjectId, blobId: BlobId): Promise<void> {
    await this.client.send(
      new DeleteObjectCommand({ Bucket: this.config.bucket, Key: this.key(projectId, blobId) }),
    );
  }
}

/** Build the blob store the host configured: S3 when an `s3` config is given, otherwise the in-memory dev
 *  store (bytes lost on restart — never use it in production). */
export function createBlobStore(s3: BlobS3Config | null): BlobStore {
  return s3 === null ? new InMemoryBlobStore() : new S3BlobStore(s3);
}
