// BlobStore — the physical byte layer under the 3-layer value model.
//
// The ValueStore splits into two concerns:
//   - metadata (value_refs / api_files / value_blobs refcount) → Postgres
//   - blob bytes (content-addressed, keyed by hash)            → BlobStore
//
// Postgres is great at the relational metadata but a poor home for large
// binary blobs (RDS storage/IOPS/backup/WAL all balloon). So the bytes live
// here behind a small interface. Katari's blob layer is **S3-compatible
// only** — there is no on-disk fallback. That is a deliberate safety choice:
// a silent local-disk default is the classic "deployed to ephemeral storage,
// lost data on restart" footgun, so a missing/misconfigured blob backend is a
// hard startup error (see `createBlobStoreFromEnv`). S3 is also the portable
// target — it reaches every cloud (AWS / R2 / B2 / Spaces / Wasabi / …) and
// every self-hostable store (SeaweedFS / Garage / Ceph / versitygw / …).
//
//   - S3BlobStore      — the only production backend. Real AWS uses the
//                        default credential chain (e.g. the ECS task IAM
//                        role); any S3-compatible store works via
//                        KATARI_S3_ENDPOINT + forcePathStyle.
//   - InMemoryBlobStore — tests.
//
// Dev / self-host both ship an S3-compatible container (adobe/s3mock for dev,
// SeaweedFS for self-host), so "S3-only" never means "needs a cloud account".
//
// Blobs are content-addressed, so writes are idempotent: putting the same
// (projectId, hash) twice is a no-op. Refcounting + the "delete at zero"
// decision stay in Postgres (PgValueStore); this layer only does the
// physical put / get / range / delete of the bytes.

import { setTimeout as sleep } from "node:timers/promises";
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
      // S3 API is a de-facto standard, so this works against any compatible
      // store (R2 / B2 / Spaces / Wasabi / Scaleway / Ceph / SeaweedFS /
      // Garage / …) — not just AWS. The one portability trap: AWS SDK v3 now
      // adds a CRC32 checksum trailer to PutObject by default, which many
      // compatible providers reject. Pin both to WHEN_REQUIRED so we only emit
      // checksums where the operation truly needs them (still correct on real
      // AWS); this is what keeps "S3-compatible" actually compatible.
      requestChecksumCalculation: "WHEN_REQUIRED",
      responseChecksumValidation: "WHEN_REQUIRED",
    });
    this.bucket = options.bucket;
    this.prefix = options.prefix ?? "";
  }

  private key(projectId: string, hash: string): string {
    return `${this.prefix}${projectId}/${hash}`;
  }

  /**
   * Ensure the bucket exists (idempotent). Used by bundled self-host stores
   * (SeaweedFS / s3mock) where the bucket isn't pre-provisioned; cloud deploys
   * leave KATARI_S3_CREATE_BUCKET unset and create the bucket out-of-band with
   * their own (least-privilege) tooling. Already-exists is swallowed.
   */
  async ensureBucket(): Promise<void> {
    try {
      await this.client.send(new this.commands.CreateBucketCommand({ Bucket: this.bucket }));
    } catch (err) {
      const name = (err as { name?: string }).name;
      if (name === "BucketAlreadyOwnedByYou" || name === "BucketAlreadyExists") return;
      throw err;
    }
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
 * Build the (S3-compatible) BlobStore from the environment.
 *
 *   - `KATARI_S3_BUCKET` (required) — the bucket. Its ABSENCE is a hard error:
 *     there is no on-disk fallback, so a misconfigured deploy fails fast at
 *     startup instead of silently writing to ephemeral disk and losing data.
 *   - `KATARI_S3_ENDPOINT` / `KATARI_S3_FORCE_PATH_STYLE` — point at any
 *     S3-compatible store (SeaweedFS / R2 / B2 / s3mock / …). Omit for real AWS.
 *   - `KATARI_S3_REGION` (or `AWS_REGION`), `KATARI_S3_PREFIX` — optional.
 *   - `KATARI_S3_CREATE_BUCKET=true` — ensure the bucket on boot (bundled
 *     self-host / dev stores). Cloud deploys leave it unset and pre-create the
 *     bucket with their own least-privilege tooling.
 *
 * S3 credentials are read by the AWS SDK's default provider chain (env
 * AWS_ACCESS_KEY_ID/SECRET, or on AWS the instance/task IAM role) — not here.
 */
export async function createBlobStoreFromEnv(logger: Logger): Promise<BlobStore> {
  const explicit = process.env.KATARI_BLOB_STORE;
  if (explicit !== undefined && explicit !== "" && explicit !== "s3") {
    throw new Error(
      `KATARI_BLOB_STORE='${explicit}' is not supported — Katari's blob layer is S3-compatible only. ` +
        "Set KATARI_S3_BUCKET (+ KATARI_S3_ENDPOINT for a self-hosted store) and leave KATARI_BLOB_STORE unset or =s3.",
    );
  }
  const bucket = process.env.KATARI_S3_BUCKET;
  if (bucket === undefined || bucket === "") {
    throw new Error(
      "blob storage is not configured: set KATARI_S3_BUCKET (S3-compatible storage is required; " +
        "there is no local-disk fallback). For a self-hosted store also set KATARI_S3_ENDPOINT " +
        "(e.g. http://seaweedfs:8333) + KATARI_S3_FORCE_PATH_STYLE=true; for AWS just set the bucket + region.",
    );
  }

  const s3Module = await import("@aws-sdk/client-s3");
  const store = new S3BlobStore(
    {
      bucket,
      prefix: process.env.KATARI_S3_PREFIX,
      region: process.env.KATARI_S3_REGION ?? process.env.AWS_REGION,
      endpoint: process.env.KATARI_S3_ENDPOINT,
      forcePathStyle: process.env.KATARI_S3_FORCE_PATH_STYLE === "true",
    },
    s3Module,
  );
  logger.log("info", "blob store: s3", {
    bucket,
    endpoint: process.env.KATARI_S3_ENDPOINT ?? "(aws default)",
    prefix: process.env.KATARI_S3_PREFIX ?? "",
  });
  if (process.env.KATARI_S3_CREATE_BUCKET === "true") {
    // Bundled stores (SeaweedFS) may still be coming up on a cold
    // `docker compose up`, so retry briefly rather than crash-looping the
    // whole runtime on the readiness race. A genuine misconfig still surfaces
    // (the last error is rethrown after the window).
    const ATTEMPTS = 10;
    for (let attempt = 1; ; attempt++) {
      try {
        await store.ensureBucket();
        logger.log("info", "blob store: ensured bucket exists", { bucket });
        break;
      } catch (err) {
        if (attempt >= ATTEMPTS) throw err;
        logger.log("warn", "blob store: bucket not ready, retrying", {
          bucket,
          attempt,
          error: err instanceof Error ? err.message : String(err),
        });
        await sleep(1500);
      }
    }
  }
  return store;
}
