// BlobStore — the physical byte layer under the 3-layer value model.
//
// The ValueStore splits into two concerns:
//   - metadata (value_refs / api_files / value_blobs refcount) → Postgres
//   - blob bytes (content-addressed, keyed by hash)            → BlobStore
//
// Postgres is great at the relational metadata but a poor home for large
// binary blobs (RDS storage/IOPS/backup/WAL all balloon). So the bytes live
// here behind a small interface, and the deploy picks the backend:
//
//   - LocalBlobStore   — files on disk. Dev / single-host with a persistent
//                        volume. NOT for ECS (task-local disk is ephemeral).
//   - S3BlobStore      — production (ECS uses the task IAM role; no creds in
//                        env). Range reads map straight to S3's Range header.
//   - InMemoryBlobStore — tests.
//
// Blobs are content-addressed, so writes are idempotent: putting the same
// (projectId, hash) twice is a no-op. Refcounting + the "delete at zero"
// decision stay in Postgres (PgValueStore); this layer only does the
// physical put / get / range / delete of the bytes.

import { constants as fsConstants } from "node:fs";
import { access, mkdir, open, readFile, rm, unlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { Logger } from "@katari-lang/runtime";

export interface BlobStore {
  /** Persist `bytes` under `(projectId, hash)`. Idempotent: a repeat put of
   *  the same hash is a no-op (content-addressed). */
  put(projectId: string, hash: string, bytes: Uint8Array): Promise<void>;
  /** Full bytes, or `null` if the blob is absent. */
  get(projectId: string, hash: string): Promise<Uint8Array | null>;
  /** Bytes `[offset, offset+length)`. `null` if the blob is absent; a short
   *  read (range past EOF) returns the available tail. */
  getRange(
    projectId: string,
    hash: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null>;
  /** Physically remove the bytes. Called by the refcount sweep once the last
   *  referrer is gone. Absent blob = no-op (idempotent). */
  delete(projectId: string, hash: string): Promise<void>;
}

// ─── In-memory (tests) ───────────────────────────────────────────────────────

export class InMemoryBlobStore implements BlobStore {
  private readonly blobs = new Map<string, Uint8Array>();

  private static key(projectId: string, hash: string): string {
    return `${projectId}|${hash}`;
  }

  async put(projectId: string, hash: string, bytes: Uint8Array): Promise<void> {
    const key = InMemoryBlobStore.key(projectId, hash);
    if (!this.blobs.has(key)) this.blobs.set(key, bytes.slice());
  }

  async get(projectId: string, hash: string): Promise<Uint8Array | null> {
    const bytes = this.blobs.get(InMemoryBlobStore.key(projectId, hash));
    return bytes !== undefined ? bytes.slice() : null;
  }

  async getRange(
    projectId: string,
    hash: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null> {
    const bytes = this.blobs.get(InMemoryBlobStore.key(projectId, hash));
    if (bytes === undefined) return null;
    const start = Math.max(0, offset);
    const end = Math.min(bytes.length, start + Math.max(0, length));
    return bytes.slice(start, end);
  }

  async delete(projectId: string, hash: string): Promise<void> {
    this.blobs.delete(InMemoryBlobStore.key(projectId, hash));
  }
}

// ─── Local filesystem ─────────────────────────────────────────────────────────

export class LocalBlobStore implements BlobStore {
  constructor(private readonly root: string) {}

  // Shard by a 2-char hash prefix so one project's dir doesn't accumulate a
  // single flat directory of millions of entries.
  private path(projectId: string, hash: string): string {
    const shard = hash.slice(0, 2);
    return join(this.root, projectId, shard, hash);
  }

  async put(projectId: string, hash: string, bytes: Uint8Array): Promise<void> {
    const path = this.path(projectId, hash);
    try {
      await access(path, fsConstants.F_OK);
      return; // already present — content-addressed, nothing to do
    } catch {
      // not present; write it
    }
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, bytes);
  }

  async get(projectId: string, hash: string): Promise<Uint8Array | null> {
    try {
      return await readFile(this.path(projectId, hash));
    } catch (err) {
      if (isNotFound(err)) return null;
      throw err;
    }
  }

  async getRange(
    projectId: string,
    hash: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null> {
    const start = Math.max(0, offset);
    const want = Math.max(0, length);
    if (want === 0) return new Uint8Array(0);
    let handle: Awaited<ReturnType<typeof open>> | null = null;
    try {
      handle = await open(this.path(projectId, hash), "r");
      const buffer = Buffer.alloc(want);
      const { bytesRead } = await handle.read(buffer, 0, want, start);
      return buffer.subarray(0, bytesRead);
    } catch (err) {
      if (isNotFound(err)) return null;
      throw err;
    } finally {
      await handle?.close();
    }
  }

  async delete(projectId: string, hash: string): Promise<void> {
    try {
      await unlink(this.path(projectId, hash));
    } catch (err) {
      if (!isNotFound(err)) throw err;
    }
  }

  /** Test helper: wipe the whole root. Not part of the interface. */
  async clear(): Promise<void> {
    await rm(this.root, { recursive: true, force: true });
  }
}

function isNotFound(err: unknown): boolean {
  return (
    typeof err === "object" &&
    err !== null &&
    "code" in err &&
    (err as { code?: string }).code === "ENOENT"
  );
}

// ─── S3 (production) ───────────────────────────────────────────────────────────

export type S3BlobStoreOptions = {
  bucket: string;
  /** Key prefix, e.g. "blobs/". Empty for bucket root. */
  prefix?: string;
  region?: string;
  /** Override endpoint for S3-compatible stores (MinIO, R2). */
  endpoint?: string;
  /** Force path-style addressing (MinIO and some compatibles need this). */
  forcePathStyle?: boolean;
};

export class S3BlobStore implements BlobStore {
  private readonly client: import("@aws-sdk/client-s3").S3Client;
  private readonly bucket: string;
  private readonly prefix: string;
  // The S3 command classes, captured at construction so the import only loads
  // when an S3 store is actually used.
  private readonly commands: typeof import("@aws-sdk/client-s3");

  constructor(options: S3BlobStoreOptions, s3Module: typeof import("@aws-sdk/client-s3")) {
    this.commands = s3Module;
    this.client = new s3Module.S3Client({
      region: options.region,
      endpoint: options.endpoint,
      forcePathStyle: options.forcePathStyle,
    });
    this.bucket = options.bucket;
    this.prefix = options.prefix ?? "";
  }

  private key(projectId: string, hash: string): string {
    return `${this.prefix}${projectId}/${hash}`;
  }

  async put(projectId: string, hash: string, bytes: Uint8Array): Promise<void> {
    const Key = this.key(projectId, hash);
    // Content-addressed: skip the upload if the object already exists.
    try {
      await this.client.send(new this.commands.HeadObjectCommand({ Bucket: this.bucket, Key }));
      return;
    } catch (err) {
      if (!isS3NotFound(err)) throw err;
    }
    await this.client.send(
      new this.commands.PutObjectCommand({ Bucket: this.bucket, Key, Body: bytes }),
    );
  }

  async get(projectId: string, hash: string): Promise<Uint8Array | null> {
    try {
      const res = await this.client.send(
        new this.commands.GetObjectCommand({ Bucket: this.bucket, Key: this.key(projectId, hash) }),
      );
      if (res.Body === undefined) return null;
      return await res.Body.transformToByteArray();
    } catch (err) {
      if (isS3NotFound(err)) return null;
      throw err;
    }
  }

  async getRange(
    projectId: string,
    hash: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null> {
    const start = Math.max(0, offset);
    const want = Math.max(0, length);
    if (want === 0) return new Uint8Array(0);
    try {
      const res = await this.client.send(
        new this.commands.GetObjectCommand({
          Bucket: this.bucket,
          Key: this.key(projectId, hash),
          Range: `bytes=${start}-${start + want - 1}`,
        }),
      );
      if (res.Body === undefined) return null;
      return await res.Body.transformToByteArray();
    } catch (err) {
      if (isS3NotFound(err)) return null;
      throw err;
    }
  }

  async delete(projectId: string, hash: string): Promise<void> {
    await this.client.send(
      new this.commands.DeleteObjectCommand({
        Bucket: this.bucket,
        Key: this.key(projectId, hash),
      }),
    );
  }
}

function isS3NotFound(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const name = (err as { name?: string }).name;
  const status = (err as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode;
  return name === "NotFound" || name === "NoSuchKey" || status === 404;
}

// ─── Factory ───────────────────────────────────────────────────────────────────

/**
 * Build the BlobStore the environment asks for:
 *
 *   - `KATARI_BLOB_STORE=s3`    — S3 (requires `KATARI_S3_BUCKET`).
 *   - `KATARI_BLOB_STORE=local` — filesystem (`KATARI_BLOB_DIR`, default
 *                                 `./katari-data/blobs`).
 *   - unset — `s3` when `KATARI_S3_BUCKET` is present, else `local` with a
 *             loud warning (so a prod deploy that forgot the S3 config doesn't
 *             silently write to ephemeral container disk).
 *
 * S3 credentials are NOT read from here: the AWS SDK's default provider chain
 * picks them up (on ECS that is the task IAM role — nothing in env).
 */
export async function createBlobStoreFromEnv(logger: Logger): Promise<BlobStore> {
  const explicit = process.env.KATARI_BLOB_STORE;
  const bucket = process.env.KATARI_S3_BUCKET;
  const mode = explicit ?? (bucket !== undefined && bucket !== "" ? "s3" : "local");

  if (mode === "s3") {
    if (bucket === undefined || bucket === "") {
      throw new Error("KATARI_BLOB_STORE=s3 requires KATARI_S3_BUCKET");
    }
    const s3Module = await import("@aws-sdk/client-s3");
    logger.log("info", "blob store: s3", { bucket, prefix: process.env.KATARI_S3_PREFIX ?? "" });
    return new S3BlobStore(
      {
        bucket,
        prefix: process.env.KATARI_S3_PREFIX,
        region: process.env.KATARI_S3_REGION ?? process.env.AWS_REGION,
        endpoint: process.env.KATARI_S3_ENDPOINT,
        forcePathStyle: process.env.KATARI_S3_FORCE_PATH_STYLE === "true",
      },
      s3Module,
    );
  }

  const dir = process.env.KATARI_BLOB_DIR ?? "./katari-data/blobs";
  if (explicit !== "local") {
    logger.log(
      "warn",
      `blob store: local filesystem (${dir}) — set KATARI_S3_BUCKET for durable storage. ` +
        "Container-local disk is ephemeral; do NOT use 'local' in a stateless deploy (e.g. ECS Fargate).",
      { dir },
    );
  } else {
    logger.log("info", "blob store: local filesystem", { dir });
  }
  return new LocalBlobStore(dir);
}
