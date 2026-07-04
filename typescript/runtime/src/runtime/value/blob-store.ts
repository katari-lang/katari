// BlobStore: the pluggable byte backend behind a blob ref. A blob's metadata (hash / size /
// content_type / semantic_kind) lives in the `blobs` table; its bytes live here, keyed by
// (projectId, blobId). Ships an in-memory store (the dev seam) and an S3-backed store for production —
// both behind the one interface, so the engine and the file API are unchanged by the choice.
//
// `getRange` exists for bounded reads of a large blob (a streaming download, a partial materialise)
// without pulling the whole object — the engine's hot path stays bounded even when a value is big.

import {
  CreateBucketCommand,
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
  S3ServiceException,
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

/** S3 connection config for a blob store (an AWS bucket, or any S3-compatible endpoint like SeaweedFS). */
export interface BlobS3Config {
  bucket: string;
  region: string;
  /** A non-AWS endpoint (e.g. SeaweedFS / s3mock); omitted for real AWS S3. */
  endpoint?: string;
  /** Path-style addressing (`endpoint/bucket/key`), which most S3-compatible servers need. */
  forcePathStyle: boolean;
  /** Create the bucket on boot if it is absent (idempotent). For a local S3 mock whose bucket is
   *  not provisioned out of band; leave false against real AWS, where the app usually lacks (and
   *  should not need) `CreateBucket` permission and the bucket is managed separately. */
  createBucket: boolean;
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

  /** Create the bucket if configured to and it is absent (idempotent) — called once at boot. This is also
   *  the runtime's first S3 contact, so it doubles as a readiness gate: a local mock may still be starting
   *  when the runtime boots. An already-owned bucket is success; a 4xx (auth / config) fails fast; a
   *  connection failure or 5xx is retried a bounded number of times, then propagates (a real
   *  misconfiguration should fail the boot, not surface later as a failed upload). */
  async ensureBucket(): Promise<void> {
    if (!this.config.createBucket) return;
    for (let attempt = 1; ; attempt++) {
      try {
        await this.client.send(new CreateBucketCommand({ Bucket: this.config.bucket }));
        return;
      } catch (error) {
        const name = error instanceof S3ServiceException ? error.name : "";
        if (name === "BucketAlreadyOwnedByYou" || name === "BucketAlreadyExists") return;
        const status =
          error instanceof S3ServiceException ? error.$metadata.httpStatusCode : undefined;
        const isClientError = status !== undefined && status >= 400 && status < 500;
        if (isClientError || attempt >= 20) throw error;
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
    }
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
    // An empty half-open range `[n, n)` reads nothing — match `InMemoryBlobStore`'s `slice(start, end)` and
    // never send S3 a reversed `bytes=n-(n-1)` range (which it rejects with 416 / returns the whole object).
    if (start >= end) return new Uint8Array(0);
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

/** Ensure a configured blob store is ready to serve — for S3 with `createBucket`, create the bucket if it
 *  is absent (idempotent). Called once at boot, before serving, so the first upload never races a missing
 *  bucket. A no-op for the in-memory store and for S3 without `createBucket`. */
export async function ensureBlobStoreReady(store: BlobStore): Promise<void> {
  if (store instanceof S3BlobStore) await store.ensureBucket();
}
