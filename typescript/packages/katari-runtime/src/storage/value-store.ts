// ValueStore — the content-addressed byte-sequence storage abstraction.
//
// Design: docs/2026-06-01-entity-model.md (Ref / Blob), docs/2026-05-30-storage-
// schema-and-api.md §2 / §4.
//
// Two layers:
//   - ref (`refs`)        — a blob handle owned by exactly one ENTITY
//                           (`ownerEntityId`), or transiently by no one (NULL)
//                           mid-ascent. Unifies the old ephemeral refs AND
//                           persistent files: a `module = "api"` ref owned by an
//                           entity the API keeps (project / run root) is a
//                           durable file; a `module = "core" | "ffi"` ref owned
//                           by an ephemeral entity is an intermediate. A delegation
//                           never owns a ref — ascent is value-driven (the result
//                           value carries the ref ids; the parent claims them).
//   - blob (`value_blobs`) — project-wide content-addressed refcount ledger (the
//                           dedup unit). Bytes live in a pluggable BlobStore; an
//                           AFTER DELETE trigger on `refs` keeps the refcount
//                           correct under both explicit deletes and entity cascade.
//
// `ref = a module's handle, blob = the file's NAMELESS bytes`. The file name is
// `display_name` on the ref (set at user upload); blobs are nameless + deduped.
//
// This interface lives in the runtime (the lower layer) so engine modules can
// consume it; `katari-api-server` provides the Postgres / in-memory impls.
// `projectId` / `ownerEntityId` are plain strings here (ambient context / an
// opaque id) to keep the runtime decoupled from the api-server's branded ids.

import type { RefModule } from "../engine/value.js";

/** The module that produced a ref (its wire module). */
export type ProduceModule = "core" | "ffi";

/** Which byte-sequence kind a ref / blob carries. `closure` is a serialized
 *  closure env (an internal node holding nested refs — the ascent opens it via
 *  `refs_to` to drag captures; the others are leaves). */
export type ValueSemanticKind = "string" | "file" | "secret" | "closure";

/** Where a ref came from (display/filtering; derivable from its owner's role).
 *  `user` = an upload on the project root; `run` = a run result; `escalation` =
 *  persisted escalation arg; `intermediate` = program-/FFI-produced. */
export type RefOrigin = "user" | "run" | "escalation" | "intermediate";

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

/** A durable file (a `module = "api"` ref the API keeps). */
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
 * existing blobs, and persists. `abort` marks the ref `errored`. Single-use.
 */
export interface ProduceHandle {
  readonly id: string;
  pushChunk(bytes: Uint8Array): Promise<void>;
  close(): Promise<ProduceResult>;
  abort(errorMessage: string): Promise<void>;
}

/** A value-reference handle (wire module + id) — the closure adjacency unit. */
export type RefHandle = { module: RefModule; id: string };

export type PutInput = {
  projectId: string;
  owner: ProduceModule;
  bytes: Uint8Array;
  semanticKind: ValueSemanticKind;
  contentType?: string;
  /** The entity that owns this ref (the producing CORE/FFI entity `E`).
   *  `undefined` = unowned (test/legacy; not entity-GC-managed). */
  ownerEntityId?: string;
  /** Display/filtering origin. Defaults to `intermediate`. */
  origin?: RefOrigin;
  /** Refs this ref internally captures (closures). The detach/claim ascent
   *  follows these so a closure's captures travel with it. */
  refsTo?: ReadonlyArray<RefHandle>;
};

export type OpenInput = Omit<PutInput, "bytes">;

export type CreateFileInput = {
  projectId: string;
  /** The durable entity that owns this upload (normally the project root). */
  ownerEntityId: string;
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
  // ── produce: a ref owned by a producing entity (core / ffi) ──────────────
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

  // ── durable files (module = "api" refs the API keeps) ────────────────────
  /** Create an upload: a `module = "api"` ref owned by `ownerEntityId`,
   *  `origin = "user"`, carrying `displayName`. */
  createFile(input: CreateFileInput): Promise<FileRecord>;
  getFile(projectId: string, id: string): Promise<FileRecord | null>;
  /** User uploads (`module = "api"`, `origin = "user"`). */
  listFiles(projectId: string): Promise<FileRecord[]>;
  deleteFile(projectId: string, id: string): Promise<boolean>;

  /**
   * Promote a ref to a durable file (`katari.value.persist`): create a
   * `module = "api"` ref owned by `ownerEntityId` sharing the source ref's blob
   * (refcount += 1); the caller rewrites the value's rep to `module: "api", id:
   * <file id>`. The source ref is left for its owner's normal teardown. `null`
   * if the source ref is unknown or not yet `complete`.
   */
  persistRef(input: {
    projectId: string;
    module: ProduceModule;
    id: string;
    ownerEntityId: string;
    displayName?: string;
  }): Promise<FileRecord | null>;

  // ── ownership: value-driven ascent (entity model) ────────────────────────
  //
  // A ref is owned by exactly one entity, or transiently by NULL mid-ascent.
  // `reownRefs` is the one primitive behind every transition; `seed` is expanded
  // transitively through `refs_to` (closure captures), restricted to refs whose
  // current owner is `fromOwner`.
  //
  //   - detach (child terminal):  reownRefs(p, E_child, null, escapeSeed)
  //   - claim  (parent on ack):   reownRefs(p, null, E_parent, value's refs)
  //   - persist escalation arg:   reownRefs(p, E_raiser, E_run, arg refs)

  /**
   * Re-own the transitive closure (via `refs_to`) of `seed` from `fromOwner` to
   * `toOwner` (either may be `null` = unowned/in-transit). Only refs currently
   * owned by `fromOwner` move (so a stale or shared ref is never stolen).
   */
  reownRefs(
    projectId: string,
    fromOwner: string | null,
    toOwner: string | null,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<void>;

  /**
   * Delete blob-ledger rows that fell to refcount 0 (the trigger decrements on
   * every ref delete — explicit or entity cascade) and physically delete those
   * bytes from the BlobStore. Returns the number of blobs freed. Safe to call at
   * any point; run after teardown / on a timer / at boot.
   */
  reapFreedBlobs(projectId: string): Promise<number>;

  /**
   * Crash backstop. Delete every in-transit ref (`owner_entity_id IS NULL`) —
   * these are refs detached mid-ascent whose claim was lost to a crash — then
   * reap freed blobs. MUST run only when nothing is concurrently ascending (i.e.
   * at boot, before traffic), since a live in-transit ref would be wrongly
   * collected. Returns the number of blobs freed.
   */
  sweepDetachedRefs(projectId: string): Promise<number>;
}
