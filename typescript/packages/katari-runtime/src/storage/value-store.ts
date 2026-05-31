// ValueStore — the 3-layer byte-sequence storage abstraction.
//
// Design: docs/2026-05-30-storage-schema-and-api.md §2 / §4, value-and-streaming §3.
//
// Three layers, mirroring the run / delegation "persistent record + freeable
// resource" split (D30):
//
//   - ephemeral ref (`value_refs`)   — CORE/FFI intermediate values. Owned by
//                                      exactly one durable entity; ownership
//                                      moves up the delegation tree and the ref
//                                      is freed when its last owner drops it
//                                      (single-owner GC, Phase G).
//   - persistent file (`api_files`)  — API-owned record. User deletes it; not
//                                      ephemeral-GC'd (= multi-server safe).
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

/** A value-reference handle (owner module + id) — the closure adjacency unit. */
export type RefHandle = { module: RefModule; id: string };

export type PutInput = {
  projectId: string;
  owner: EphemeralOwner;
  bytes: Uint8Array;
  semanticKind: ValueSemanticKind;
  contentType?: string;
  /** The durable entity that owns this ref (a delegation while running, then a
   *  run / escalation). Ownership moves up the delegation tree at protocol
   *  events; a ref is freed when its last owner drops it. `undefined` = unowned
   *  (not yet GC-managed). */
  ownerDelegationId?: string;
  /** Refs this ref internally captures (closures). The upward ownership move
   *  follows these so a closure's captures travel with it. */
  refsTo?: ReadonlyArray<RefHandle>;
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
   * source ephemeral ref is left for its owner's normal release. `null` if the
   * source ref is unknown or not yet `complete`.
   */
  persistRef(input: {
    projectId: string;
    module: EphemeralOwner;
    id: string;
    displayName?: string;
  }): Promise<FileRecord | null>;

  // ── ownership transitions (single-owner GC, Phase G) ─────────────────────
  //
  // Ownership moves UP the delegation tree at protocol events; a blob is freed
  // when its last ref is dropped. `escapeSeed` / `seed` are the refs found in
  // the crossing value; the store expands them transitively through `refs_to`
  // (closure captures), restricted to refs the source entity owns.

  /**
   * A ref-owning entity terminated. Within the refs owned by `ownerId`: the
   * transitive closure (via `refs_to`) of `escapeSeed` is RE-OWNED by
   * `toOwnerId` (the surviving owner — the parent delegation, or the entity
   * itself for a root that becomes a persistent run). Every other ref owned by
   * `ownerId` is DROPPED. Returns the number of blobs physically freed.
   */
  releaseOwner(
    projectId: string,
    ownerId: string,
    toOwnerId: string,
    escapeSeed: ReadonlyArray<RefHandle>,
  ): Promise<number>;

  /**
   * Escalation / borrow-up: re-own the transitive closure (via `refs_to`) of
   * `seed` within the refs owned by `fromOwnerId` to `toOwnerId`. Nothing is
   * dropped — the source entity keeps running.
   */
  transferOwnership(
    projectId: string,
    fromOwnerId: string,
    toOwnerId: string,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<void>;

  /**
   * Crash backstop. Drop every ref whose `ownerDelegationId` is non-null and
   * NOT in `liveOwnerIds` (the union of live delegations / runs / escalations),
   * then free blobs that hit refcount 0. Unowned refs (null owner) are left
   * alone. Returns the number of blobs freed. Run on boot + periodically to
   * reclaim refs whose explicit release was lost to a crash.
   */
  sweepRefsWithDeadOwners(projectId: string, liveOwnerIds: ReadonlySet<string>): Promise<number>;
}
