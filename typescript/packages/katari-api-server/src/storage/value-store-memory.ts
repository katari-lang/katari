// In-memory `ValueStore`. Used by tests and the memory `Storage` backend.
//
// Models the 3 layers as plain Maps: ephemeral `refs`, persistent `files`, and
// content-addressed `blobs` (the dedup unit, with a refcount). Bytes are held
// whole (chunking is a Postgres storage detail); `fetchRange` slices. See the
// Postgres impl (`value-store-pg.ts`) for the on-disk chunked layout.

import {
  type CreateFileInput,
  type EphemeralOwner,
  type FileRecord,
  hashBytes,
  MAX_PRODUCE_BYTES,
  type OpenInput,
  type ProduceHandle,
  type ProduceResult,
  type PutInput,
  type RefModule,
  type RefState,
  type ValueRefState,
  type ValueSemanticKind,
  type ValueStore,
} from "@katari-lang/runtime";
import { v7 as uuidv7 } from "uuid";

type RefRow = {
  projectId: string;
  owner: EphemeralOwner;
  id: string;
  state: ValueRefState;
  semanticKind: ValueSemanticKind;
  ownerInstanceId?: string;
  hash: string | null;
  size: number | null;
  contentType?: string;
  errorMessage?: string;
  createdAt: string;
};

type FileRow = {
  projectId: string;
  id: string;
  hash: string;
  size: number;
  contentType?: string;
  displayName?: string;
  createdAt: string;
};

type BlobRow = {
  totalSize: number;
  refCount: number;
  bytes: Uint8Array;
};

const refKey = (projectId: string, owner: string, id: string): string =>
  `${projectId}|${owner}|${id}`;
const fileKey = (projectId: string, id: string): string => `${projectId}|${id}`;
const blobKey = (projectId: string, hash: string): string => `${projectId}|${hash}`;

function toFileRecord(row: FileRow): FileRecord {
  return {
    id: row.id,
    hash: row.hash,
    size: row.size,
    contentType: row.contentType,
    displayName: row.displayName,
    createdAt: row.createdAt,
  };
}

export class InMemoryValueStore implements ValueStore {
  // Public so the `Storage` facade can snapshot/restore for `withTransaction`.
  refs = new Map<string, RefRow>();
  files = new Map<string, FileRow>();
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

  /** Decrement a blob's refcount; delete it at zero. */
  private releaseBlobRef(projectId: string, hash: string): void {
    const key = blobKey(projectId, hash);
    const existing = this.blobs.get(key);
    if (existing === undefined) return;
    if (existing.refCount <= 1) {
      this.blobs.delete(key);
      return;
    }
    this.blobs.set(key, { ...existing, refCount: existing.refCount - 1 });
  }

  private resolveBytes(projectId: string, hash: string): Uint8Array | null {
    const blob = this.blobs.get(blobKey(projectId, hash));
    return blob !== undefined ? blob.bytes.slice() : null;
  }

  // ── produce (ephemeral) ───────────────────────────────────────────────────

  async putComplete(input: PutInput): Promise<ProduceResult> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`value too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    const size = input.bytes.length;
    this.addBlobRef(input.projectId, hash, input.bytes);
    this.refs.set(refKey(input.projectId, input.owner, id), {
      projectId: input.projectId,
      owner: input.owner,
      id,
      state: "complete",
      semanticKind: input.semanticKind,
      ownerInstanceId: input.ownerInstanceId,
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
        store.refs.set(refKey(input.projectId, input.owner, id), {
          projectId: input.projectId,
          owner: input.owner,
          id,
          state: "complete",
          semanticKind: input.semanticKind,
          ownerInstanceId: input.ownerInstanceId,
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
        store.refs.set(refKey(input.projectId, input.owner, id), {
          projectId: input.projectId,
          owner: input.owner,
          id,
          state: "errored",
          semanticKind: input.semanticKind,
          ownerInstanceId: input.ownerInstanceId,
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
    if (module === "api") {
      const file = this.files.get(fileKey(projectId, id));
      if (file === undefined) return null;
      return {
        module,
        id,
        state: "complete",
        semanticKind: "file",
        hash: file.hash,
        size: file.size,
        contentType: file.contentType,
      };
    }
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
    if (module === "api") {
      return this.files.get(fileKey(projectId, id))?.hash ?? null;
    }
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

  // ── persistent files ──────────────────────────────────────────────────────

  async createFile(input: CreateFileInput): Promise<FileRecord> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`file too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    this.addBlobRef(input.projectId, hash, input.bytes);
    const row: FileRow = {
      projectId: input.projectId,
      id,
      hash,
      size: input.bytes.length,
      contentType: input.contentType,
      displayName: input.displayName,
      createdAt: new Date().toISOString(),
    };
    this.files.set(fileKey(input.projectId, id), row);
    return toFileRecord(row);
  }

  async getFile(projectId: string, id: string): Promise<FileRecord | null> {
    const row = this.files.get(fileKey(projectId, id));
    return row !== undefined ? toFileRecord(row) : null;
  }

  async listFiles(projectId: string): Promise<FileRecord[]> {
    return [...this.files.values()]
      .filter((r) => r.projectId === projectId)
      .sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0))
      .map(toFileRecord);
  }

  async deleteFile(projectId: string, id: string): Promise<boolean> {
    const key = fileKey(projectId, id);
    const row = this.files.get(key);
    if (row === undefined) return false;
    this.files.delete(key);
    this.releaseBlobRef(projectId, row.hash);
    return true;
  }

  async persistRef(input: {
    projectId: string;
    module: EphemeralOwner;
    id: string;
    displayName?: string;
  }): Promise<FileRecord | null> {
    const ref = this.refs.get(refKey(input.projectId, input.module, input.id));
    if (ref === undefined || ref.state !== "complete" || ref.hash === null || ref.size === null) {
      return null;
    }
    const id = uuidv7();
    // Share the existing blob (refcount += 1) — no byte copy needed.
    const blob = this.blobs.get(blobKey(input.projectId, ref.hash));
    if (blob === undefined) return null;
    this.blobs.set(blobKey(input.projectId, ref.hash), {
      ...blob,
      refCount: blob.refCount + 1,
    });
    const row: FileRow = {
      projectId: input.projectId,
      id,
      hash: ref.hash,
      size: ref.size,
      contentType: ref.contentType,
      displayName: input.displayName,
      createdAt: new Date().toISOString(),
    };
    this.files.set(fileKey(input.projectId, id), row);
    return toFileRecord(row);
  }

  // ── GC primitives ─────────────────────────────────────────────────────────

  async sweepUnreachable(
    projectId: string,
    reachable: ReadonlyArray<{ owner: EphemeralOwner; id: string }>,
  ): Promise<number> {
    const keep = new Set(reachable.map((r) => refKey(projectId, r.owner, r.id)));
    let removed = 0;
    for (const [key, row] of [...this.refs.entries()]) {
      if (row.projectId !== projectId) continue;
      if (keep.has(key)) continue;
      this.refs.delete(key);
      if (row.hash !== null) this.releaseBlobRef(projectId, row.hash);
      removed += 1;
    }
    return removed;
  }

  async sweepInstance(projectId: string, ownerInstanceId: string): Promise<number> {
    let removed = 0;
    for (const [key, row] of [...this.refs.entries()]) {
      if (row.projectId !== projectId) continue;
      if (row.ownerInstanceId !== ownerInstanceId) continue;
      this.refs.delete(key);
      if (row.hash !== null) this.releaseBlobRef(projectId, row.hash);
      removed += 1;
    }
    return removed;
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
