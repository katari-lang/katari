// ValueStore — the 3-layer byte-sequence storage abstraction.
//
// Design: docs/2026-05-30-storage-schema-and-api.md §2 / §4, value-and-streaming §3.
//
// Three layers, mirroring the run / delegation "persistent record + freeable
// resource" split (D30):
//
//   - ephemeral ref (`value_refs`)   — CORE/FFI intermediate values. Owned by
//                                      a shard, reclaimed by reachability GC.
//   - persistent file (`api_files`)  — API-owned record. User deletes it; not
//                                      traversal-GC'd (= multi-server safe).
//   - shared blob (`value_blobs`)    — project-wide content-addressed bytes.
//                                      Both layers reference it by hash; a
//                                      refcount frees it at zero.
//
// `ref = a module's handle, blob = the file's bytes`. A ref/file points at a
// blob by hash; many refs may share one blob (dedup).
//
// This interface lives in the runtime (the lower layer) so engine modules can
// consume it; `katari-api-server` provides the Postgres / in-memory impls.
// `projectId` is a plain string here (ambient context, not a value's identity)
// to keep the runtime decoupled from the api-server's branded ids.

import type { RefModule } from "../engine/value.js";

/** Producer of an ephemeral ref. (`api` is the persistent-file path instead.) */
export type EphemeralOwner = "core" | "ffi";

/** Which byte-sequence kind a ref / blob carries. `closure` is a serialized
 *  closure env (an internal node holding nested refs — Phase G GC opens it to
 *  trace them; the others are leaves). */
export type ValueSemanticKind = "string" | "file" | "secret" | "closure";

/**
 * v0.1.0 ref lifecycle. `building` / `cancelled` (observable streaming) are
 * v0.2 — in v0.1.0 a ref is `complete` the moment it becomes visible.
 */
export type ValueRefState = "complete" | "errored";

/** Identity + content addressing of a freshly produced blob. */
export type ProduceResult = {
  id: string;
  hash: string;
  size: number;
};

/** Consume-side metadata of a ref (data-plane `.../state`). */
export type RefState = {
  module: RefModule;
  id: string;
  state: ValueRefState;
  semanticKind: ValueSemanticKind;
  hash: string | null;
  size: number | null;
  contentType?: string;
  errorMessage?: string;
};

/** A persistent project file (`api_files` row). */
export type FileRecord = {
  id: string;
  hash: string;
  size: number;
  contentType?: string;
  displayName?: string;
  createdAt: string;
};

/**
 * Streaming producer handle: `open` → `pushChunk`* → `close`. Pushed bytes
 * accumulate in a host-side buffer; `close` computes the hash, dedups against
 * existing blobs, and persists in fixed-size chunks (no per-chunk DB write —
 * D32). `abort` marks the ref `errored`. A handle is single-use.
 */
export interface ProduceHandle {
  readonly id: string;
  pushChunk(bytes: Uint8Array): Promise<void>;
  close(): Promise<ProduceResult>;
  abort(errorMessage: string): Promise<void>;
}

export type PutInput = {
  projectId: string;
  owner: EphemeralOwner;
  bytes: Uint8Array;
  semanticKind: ValueSemanticKind;
  contentType?: string;
  /** Binds the ref to a shard; the shard's end sweeps it (`sweepInstance`). */
  ownerInstanceId?: string;
};

export type OpenInput = Omit<PutInput, "bytes">;

export type CreateFileInput = {
  projectId: string;
  bytes: Uint8Array;
  contentType?: string;
  displayName?: string;
};

/**
 * Maximum bytes a single produce may buffer before the host rejects it. The
 * produce path holds the whole payload in memory until `close`, so this caps
 * per-value host memory. Larger payloads are a v0.2 streaming concern.
 */
export const MAX_PRODUCE_BYTES = 100 * 1024 * 1024;

export interface ValueStore {
  // ── produce: ephemeral ref (owner = core / ffi) ──────────────────────────
  /** Produce a complete blob from bytes already in hand. */
  putComplete(input: PutInput): Promise<ProduceResult>;
  /** Open a streaming producer for a large payload (host-buffered until close). */
  open(input: OpenInput): Promise<ProduceHandle>;

  // ── consume: ref → hash → blob ───────────────────────────────────────────
  /** Metadata only (no bytes). `null` if the ref is unknown. */
  getState(projectId: string, module: RefModule, id: string): Promise<RefState | null>;
  /** Full bytes. `null` if unknown / errored. */
  fetch(projectId: string, module: RefModule, id: string): Promise<Uint8Array | null>;
  /** Partial bytes `[offset, offset+length)` (data-plane HTTP Range). */
  fetchRange(
    projectId: string,
    module: RefModule,
    id: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null>;

  // ── persistent files (api_files) ─────────────────────────────────────────
  createFile(input: CreateFileInput): Promise<FileRecord>;
  getFile(projectId: string, id: string): Promise<FileRecord | null>;
  listFiles(projectId: string): Promise<FileRecord[]>;
  deleteFile(projectId: string, id: string): Promise<boolean>;

  /**
   * Promote an ephemeral ref to a persistent file (`katari.value.persist`).
   * Creates an `api_files` record sharing the ref's blob (refcount += 1); the
   * caller rewrites the value's rep to `module: "api", id: <file id>`. The
   * source ephemeral ref is left for normal reachability GC. `null` if the
   * source ref is unknown or not yet `complete`.
   */
  persistRef(input: {
    projectId: string;
    module: EphemeralOwner;
    id: string;
    displayName?: string;
  }): Promise<FileRecord | null>;

  // ── GC primitives (reachability walk itself is Phase G) ──────────────────
  /**
   * Delete every ephemeral ref in `projectId` whose `(owner, id)` is NOT in
   * `reachable`, then sweep blobs that drop to refcount 0. Returns the count
   * of refs removed. The reachable set comes from a CORE-state walk (Phase G).
   */
  sweepUnreachable(
    projectId: string,
    reachable: ReadonlyArray<{ owner: EphemeralOwner; id: string }>,
  ): Promise<number>;
  /** Delete every ephemeral ref bound to a dead shard, then sweep blobs. */
  sweepInstance(projectId: string, ownerInstanceId: string): Promise<number>;
}
