// In-memory `ValueStore` (Entity model). Used by tests and the memory `Storage`
// backend.
//
// Models the layers as plain Maps: `refs` (entity-owned blob handles, including
// `module = "api"` files) and `blobs` (the content-addressed dedup unit, with a
// refcount). Mirrors the Postgres impl's semantics; here the refcount is
// maintained in code and a blob is freed inline the moment its last ref goes
// (so `reapFreedBlobs` is a no-op). Entity CASCADE is simulated by
// `deleteRefsOwnedBy`, which the memory `EntityRepo.delete` calls.

import {
  type CreateFileInput,
  type FileRecord,
  hashBytes,
  MAX_PRODUCE_BYTES,
  type OpenInput,
  type ProduceHandle,
  type ProduceModule,
  type ProduceResult,
  type PutInput,
  type RefHandle,
  type RefModule,
  type RefOrigin,
  type RefState,
  type ValueRefState,
  type ValueSemanticKind,
  type ValueStore,
} from "@katari-lang/runtime";
import { v7 as uuidv7 } from "uuid";

type RefRow = {
  projectId: string;
  module: RefModule;
  id: string;
  ownerEntityId?: string; // undefined = in-transit (NULL owner)
  state: ValueRefState;
  semanticKind: ValueSemanticKind;
  origin: RefOrigin;
  refsTo: RefHandle[];
  hash: string | null;
  size: number | null;
  contentType?: string;
  displayName?: string;
  errorMessage?: string;
  createdAt: string;
};

type BlobRow = {
  totalSize: number;
  refCount: number;
  bytes: Uint8Array;
};

const refKey = (projectId: string, module: string, id: string): string =>
  `${projectId}|${module}|${id}`;
const blobKey = (projectId: string, hash: string): string => `${projectId}|${hash}`;

function toFileRecord(row: RefRow): FileRecord {
  return {
    id: row.id,
    hash: row.hash ?? "",
    size: row.size ?? 0,
    contentType: row.contentType,
    displayName: row.displayName,
    createdAt: row.createdAt,
  };
}

export class InMemoryValueStore implements ValueStore {
  // Public so the `Storage` facade can snapshot/restore for `withTransaction`.
  refs = new Map<string, RefRow>();
  blobs = new Map<string, BlobRow>();

  // ── blob refcount lifecycle ───────────────────────────────────────────────

  /** Create-or-increment a blob's refcount. `bytes` only used on first ref. */
  private addBlobRef(projectId: string, hash: string, bytes: Uint8Array): void {
    const key = blobKey(projectId, hash);
    const existing = this.blobs.get(key);
    if (existing !== undefined) {
      this.blobs.set(key, { ...existing, refCount: existing.refCount + 1 });
      return;
    }
    this.blobs.set(key, { totalSize: bytes.length, refCount: 1, bytes: bytes.slice() });
  }

  /** Decrement a blob's refcount; free it inline at zero. */
  private releaseBlobRef(projectId: string, hash: string | null): void {
    if (hash === null) return;
    const key = blobKey(projectId, hash);
    const existing = this.blobs.get(key);
    if (existing === undefined) return;
    if (existing.refCount <= 1) this.blobs.delete(key);
    else this.blobs.set(key, { ...existing, refCount: existing.refCount - 1 });
  }

  /** Delete a ref row and decrement its blob (the trigger's job, done in code). */
  private deleteRef(row: RefRow): void {
    this.refs.delete(refKey(row.projectId, row.module, row.id));
    this.releaseBlobRef(row.projectId, row.hash);
  }

  private resolveBytes(projectId: string, hash: string): Uint8Array | null {
    const blob = this.blobs.get(blobKey(projectId, hash));
    return blob !== undefined ? blob.bytes.slice() : null;
  }

  private insertRefRow(row: RefRow): void {
    this.refs.set(refKey(row.projectId, row.module, row.id), row);
  }

  // ── produce ───────────────────────────────────────────────────────────────

  async putComplete(input: PutInput): Promise<ProduceResult> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`value too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    const size = input.bytes.length;
    this.addBlobRef(input.projectId, hash, input.bytes);
    this.insertRefRow({
      projectId: input.projectId,
      module: input.owner,
      id,
      ownerEntityId: input.ownerEntityId,
      state: "complete",
      semanticKind: input.semanticKind,
      origin: input.origin ?? "intermediate",
      refsTo: [...(input.refsTo ?? [])],
      hash,
      size,
      contentType: input.contentType,
      createdAt: new Date().toISOString(),
    });
    return { id, hash, size };
  }

  async open(input: OpenInput): Promise<ProduceHandle> {
    const id = uuidv7();
    const store = this;
    const chunks: Uint8Array[] = [];
    let total = 0;
    let settled = false;
    return {
      id,
      async pushChunk(bytes: Uint8Array): Promise<void> {
        if (settled) throw new Error("pushChunk after close/abort");
        total += bytes.length;
        if (total > MAX_PRODUCE_BYTES) {
          throw new Error(`value too large: ${total} > ${MAX_PRODUCE_BYTES}`);
        }
        chunks.push(bytes.slice());
      },
      async close(): Promise<ProduceResult> {
        if (settled) throw new Error("close after close/abort");
        settled = true;
        const bytes = concatChunks(chunks, total);
        const hash = hashBytes(bytes);
        store.addBlobRef(input.projectId, hash, bytes);
        store.insertRefRow({
          projectId: input.projectId,
          module: input.owner,
          id,
          ownerEntityId: input.ownerEntityId,
          state: "complete",
          semanticKind: input.semanticKind,
          origin: input.origin ?? "intermediate",
          refsTo: [...(input.refsTo ?? [])],
          hash,
          size: total,
          contentType: input.contentType,
          createdAt: new Date().toISOString(),
        });
        return { id, hash, size: total };
      },
      async abort(errorMessage: string): Promise<void> {
        if (settled) return;
        settled = true;
        store.insertRefRow({
          projectId: input.projectId,
          module: input.owner,
          id,
          ownerEntityId: input.ownerEntityId,
          state: "errored",
          semanticKind: input.semanticKind,
          origin: input.origin ?? "intermediate",
          refsTo: [...(input.refsTo ?? [])],
          hash: null,
          size: null,
          contentType: input.contentType,
          errorMessage,
          createdAt: new Date().toISOString(),
        });
      },
    };
  }

  // ── consume ───────────────────────────────────────────────────────────────

  async getState(projectId: string, module: RefModule, id: string): Promise<RefState | null> {
    const row = this.refs.get(refKey(projectId, module, id));
    if (row === undefined) return null;
    return {
      module,
      id,
      state: row.state,
      semanticKind: row.semanticKind,
      hash: row.hash,
      size: row.size,
      contentType: row.contentType,
      errorMessage: row.errorMessage,
    };
  }

  private hashOf(projectId: string, module: RefModule, id: string): string | null {
    const row = this.refs.get(refKey(projectId, module, id));
    return row !== undefined && row.state === "complete" ? row.hash : null;
  }

  async fetch(projectId: string, module: RefModule, id: string): Promise<Uint8Array | null> {
    const hash = this.hashOf(projectId, module, id);
    return hash !== null ? this.resolveBytes(projectId, hash) : null;
  }

  async fetchRange(
    projectId: string,
    module: RefModule,
    id: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null> {
    const bytes = await this.fetch(projectId, module, id);
    if (bytes === null) return null;
    const start = Math.max(0, offset);
    const end = Math.min(bytes.length, start + Math.max(0, length));
    return bytes.slice(start, end);
  }

  // ── durable files (module = "api" refs) ─────────────────────────────────────

  async createFile(input: CreateFileInput): Promise<FileRecord> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`file too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    this.addBlobRef(input.projectId, hash, input.bytes);
    const row: RefRow = {
      projectId: input.projectId,
      module: "api",
      id,
      ownerEntityId: input.ownerEntityId,
      state: "complete",
      semanticKind: "file",
      origin: "user",
      refsTo: [],
      hash,
      size: input.bytes.length,
      contentType: input.contentType,
      displayName: input.displayName,
      createdAt: new Date().toISOString(),
    };
    this.insertRefRow(row);
    return toFileRecord(row);
  }

  async getFile(projectId: string, id: string): Promise<FileRecord | null> {
    const row = this.refs.get(refKey(projectId, "api", id));
    return row !== undefined && row.state === "complete" ? toFileRecord(row) : null;
  }

  async listFiles(projectId: string): Promise<FileRecord[]> {
    return [...this.refs.values()]
      .filter(
        (r) =>
          r.projectId === projectId &&
          r.module === "api" &&
          r.origin === "user" &&
          r.state === "complete",
      )
      .sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0))
      .map(toFileRecord);
  }

  async deleteFile(projectId: string, id: string): Promise<boolean> {
    const row = this.refs.get(refKey(projectId, "api", id));
    if (row === undefined) return false;
    this.deleteRef(row);
    return true;
  }

  async persistRef(input: {
    projectId: string;
    module: ProduceModule;
    id: string;
    ownerEntityId: string;
    displayName?: string;
  }): Promise<FileRecord | null> {
    const ref = this.refs.get(refKey(input.projectId, input.module, input.id));
    if (ref === undefined || ref.state !== "complete" || ref.hash === null || ref.size === null) {
      return null;
    }
    const id = uuidv7();
    const blob = this.blobs.get(blobKey(input.projectId, ref.hash));
    if (blob === undefined) return null;
    this.blobs.set(blobKey(input.projectId, ref.hash), { ...blob, refCount: blob.refCount + 1 });
    const row: RefRow = {
      projectId: input.projectId,
      module: "api",
      id,
      ownerEntityId: input.ownerEntityId,
      state: "complete",
      semanticKind: "file",
      origin: "user",
      refsTo: [],
      hash: ref.hash,
      size: ref.size,
      contentType: ref.contentType,
      displayName: input.displayName,
      createdAt: new Date().toISOString(),
    };
    this.insertRefRow(row);
    return toFileRecord(row);
  }

  // ── ownership: value-driven ascent ───────────────────────────────────────

  /** Transitive closure of `seed` via `refs_to`, restricted to refs owned by
   *  `fromOwner` (undefined for in-transit). Returns the refKeys to move. */
  private expandOwned(
    projectId: string,
    fromOwner: string | undefined,
    seed: ReadonlyArray<RefHandle>,
  ): Set<string> {
    const keep = new Set<string>();
    const worklist = [...seed];
    while (worklist.length > 0) {
      const handle = worklist.pop()!;
      const key = refKey(projectId, handle.module, handle.id);
      if (keep.has(key)) continue;
      const row = this.refs.get(key);
      if (row === undefined || row.ownerEntityId !== fromOwner) continue;
      keep.add(key);
      for (const child of row.refsTo) worklist.push(child);
    }
    return keep;
  }

  async reownRefs(
    projectId: string,
    fromOwner: string | null,
    toOwner: string | null,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<void> {
    if (seed.length === 0) return;
    const move = this.expandOwned(projectId, fromOwner ?? undefined, seed);
    for (const key of move) {
      const row = this.refs.get(key);
      if (row !== undefined) this.refs.set(key, { ...row, ownerEntityId: toOwner ?? undefined });
    }
  }

  /** Memory frees blobs inline on ref delete, so there is nothing to reap. */
  async reapFreedBlobs(_projectId: string): Promise<number> {
    return 0;
  }

  async sweepDetachedRefs(projectId: string): Promise<number> {
    let freed = 0;
    for (const row of [...this.refs.values()]) {
      if (row.projectId !== projectId || row.ownerEntityId !== undefined) continue;
      const had = row.hash !== null && this.blobs.get(blobKey(projectId, row.hash))?.refCount === 1;
      this.deleteRef(row);
      if (had) freed += 1;
    }
    return freed;
  }

  // ── entity CASCADE (called by memory EntityRepo.delete) ──────────────────

  /** Delete every ref owned by `ownerEntityId` (the FK CASCADE, in code). */
  deleteRefsOwnedBy(projectId: string, ownerEntityId: string): void {
    for (const row of [...this.refs.values()]) {
      if (row.projectId === projectId && row.ownerEntityId === ownerEntityId) this.deleteRef(row);
    }
  }
}

function concatChunks(chunks: Uint8Array[], total: number): Uint8Array {
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}
