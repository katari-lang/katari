// Postgres-backed `ValueStore`. Mirrors the in-memory impl's semantics over
// the 3-layer schema (`value_refs` / `api_files` / `value_blobs` + chunks).
//
// Blobs are content-addressed and deduped: producing the same bytes twice
// stores one blob with `ref_count = 2`. Bytes live in fixed-size `bytea`
// chunks so large files stream and `fetchRange` reads only the spanned
// chunks. Each produce / file / sweep wraps its multi-statement write in a
// (possibly nested = savepoint) transaction so a blob never leaks a refcount
// without its referrer.

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
import type postgres from "postgres";
import { v7 as uuidv7 } from "uuid";

type Sql = ReturnType<typeof postgres>;

/** On-disk chunk size. Independent of how a producer pushed (re-chunked at close). */
const CHUNK_SIZE = 256 * 1024;

function splitChunks(bytes: Uint8Array): Buffer[] {
  const chunks: Buffer[] = [];
  for (let offset = 0; offset < bytes.length; offset += CHUNK_SIZE) {
    chunks.push(Buffer.from(bytes.subarray(offset, Math.min(offset + CHUNK_SIZE, bytes.length))));
  }
  return chunks;
}

export class PgValueStore implements ValueStore {
  constructor(private readonly sql: Sql) {}

  // ── blob refcount lifecycle ───────────────────────────────────────────────

  /**
   * Create-or-increment the blob for `hash`. On first insert, writes the
   * chunked bytes. Caller MUST run this inside a transaction together with
   * inserting the referring row.
   */
  private async addBlobRef(sql: Sql, projectId: string, hash: string, bytes: Uint8Array) {
    const rows = await sql<{ inserted: boolean }[]>`
      INSERT INTO value_blobs (project_id, hash, total_size, ref_count)
      VALUES (${projectId}, ${hash}, ${bytes.length}, 1)
      ON CONFLICT (project_id, hash) DO UPDATE
        SET ref_count = value_blobs.ref_count + 1,
            last_accessed_at = now()
      RETURNING (xmax = 0) AS inserted
    `;
    const inserted = rows[0]?.inserted === true;
    if (!inserted) return;
    const chunks = splitChunks(bytes);
    if (chunks.length === 0) return;
    const chunkRows = chunks.map((chunkBytes, chunkIndex) => ({
      project_id: projectId,
      hash,
      chunk_index: chunkIndex,
      bytes: chunkBytes,
    }));
    await sql`
      INSERT INTO value_blob_chunks ${sql(chunkRows, "project_id", "hash", "chunk_index", "bytes")}
    `;
  }

  /**
   * Decrement refcounts for the given hashes (with multiplicity), then sweep
   * any blob whose count fell to zero (rows + chunks). Caller supplies a map
   * of hash → how many referrers were just removed.
   */
  private async releaseBlobs(sql: Sql, projectId: string, hashCounts: Map<string, number>) {
    for (const [hash, count] of hashCounts) {
      await sql`
        UPDATE value_blobs SET ref_count = ref_count - ${count}
        WHERE project_id = ${projectId} AND hash = ${hash}
      `;
    }
    const swept = await sql<{ hash: string }[]>`
      DELETE FROM value_blobs
      WHERE project_id = ${projectId} AND ref_count <= 0
      RETURNING hash
    `;
    if (swept.length > 0) {
      const hashes = swept.map((r) => r.hash);
      await sql`
        DELETE FROM value_blob_chunks
        WHERE project_id = ${projectId} AND hash IN ${sql(hashes)}
      `;
    }
  }

  // ── produce (ephemeral) ───────────────────────────────────────────────────

  async putComplete(input: PutInput): Promise<ProduceResult> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`value too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    const size = input.bytes.length;
    await this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      await this.addBlobRef(sql, input.projectId, hash, input.bytes);
      await this.insertRefRow(sql, {
        projectId: input.projectId,
        owner: input.owner,
        id,
        state: "complete",
        semanticKind: input.semanticKind,
        ownerInstanceId: input.ownerInstanceId,
        hash,
        size,
        contentType: input.contentType,
      });
    });
    return { id, hash, size };
  }

  async open(input: OpenInput): Promise<ProduceHandle> {
    const id = uuidv7();
    const self = this;
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
        await self.sql.begin(async (tx) => {
          const sql = tx as unknown as Sql;
          await self.addBlobRef(sql, input.projectId, hash, bytes);
          await self.insertRefRow(sql, {
            projectId: input.projectId,
            owner: input.owner,
            id,
            state: "complete",
            semanticKind: input.semanticKind,
            ownerInstanceId: input.ownerInstanceId,
            hash,
            size: total,
            contentType: input.contentType,
          });
        });
        return { id, hash, size: total };
      },
      async abort(errorMessage: string): Promise<void> {
        if (settled) return;
        settled = true;
        await self.insertRefRow(self.sql, {
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
        });
      },
    };
  }

  private async insertRefRow(
    sql: Sql,
    row: {
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
    },
  ): Promise<void> {
    await sql`
      INSERT INTO value_refs
        (project_id, owner_module, id, state, semantic_kind, owner_instance_id,
         hash, size, content_type, error_message)
      VALUES
        (${row.projectId}, ${row.owner}, ${row.id}, ${row.state}, ${row.semanticKind},
         ${row.ownerInstanceId ?? null}, ${row.hash}, ${row.size}, ${row.contentType ?? null},
         ${row.errorMessage ?? null})
    `;
  }

  // ── consume ───────────────────────────────────────────────────────────────

  async getState(projectId: string, module: RefModule, id: string): Promise<RefState | null> {
    if (module === "api") {
      const rows = await this.sql<{ hash: string; size: string; content_type: string | null }[]>`
        SELECT hash, size, content_type FROM api_files
        WHERE project_id = ${projectId} AND id = ${id}
      `;
      const row = rows[0];
      if (row === undefined) return null;
      return {
        module,
        id,
        state: "complete",
        semanticKind: "file",
        hash: row.hash,
        size: Number(row.size),
        contentType: row.content_type ?? undefined,
      };
    }
    const rows = await this.sql<
      {
        state: ValueRefState;
        semantic_kind: ValueSemanticKind;
        hash: string | null;
        size: string | null;
        content_type: string | null;
        error_message: string | null;
      }[]
    >`
      SELECT state, semantic_kind, hash, size, content_type, error_message
      FROM value_refs
      WHERE project_id = ${projectId} AND owner_module = ${module} AND id = ${id}
    `;
    const row = rows[0];
    if (row === undefined) return null;
    return {
      module,
      id,
      state: row.state,
      semanticKind: row.semantic_kind,
      hash: row.hash,
      size: row.size === null ? null : Number(row.size),
      contentType: row.content_type ?? undefined,
      errorMessage: row.error_message ?? undefined,
    };
  }

  private async hashOf(projectId: string, module: RefModule, id: string): Promise<string | null> {
    if (module === "api") {
      const rows = await this.sql<{ hash: string }[]>`
        SELECT hash FROM api_files WHERE project_id = ${projectId} AND id = ${id}
      `;
      return rows[0]?.hash ?? null;
    }
    const rows = await this.sql<{ hash: string | null }[]>`
      SELECT hash FROM value_refs
      WHERE project_id = ${projectId} AND owner_module = ${module} AND id = ${id}
        AND state = 'complete'
    `;
    return rows[0]?.hash ?? null;
  }

  async fetch(projectId: string, module: RefModule, id: string): Promise<Uint8Array | null> {
    const hash = await this.hashOf(projectId, module, id);
    if (hash === null) return null;
    const rows = await this.sql<{ bytes: Buffer }[]>`
      SELECT bytes FROM value_blob_chunks
      WHERE project_id = ${projectId} AND hash = ${hash}
      ORDER BY chunk_index
    `;
    return Buffer.concat(rows.map((r) => r.bytes));
  }

  async fetchRange(
    projectId: string,
    module: RefModule,
    id: string,
    offset: number,
    length: number,
  ): Promise<Uint8Array | null> {
    const hash = await this.hashOf(projectId, module, id);
    if (hash === null) return null;
    const start = Math.max(0, offset);
    const end = start + Math.max(0, length);
    const startChunk = Math.floor(start / CHUNK_SIZE);
    const endChunk = Math.floor(Math.max(start, end - 1) / CHUNK_SIZE);
    const rows = await this.sql<{ chunk_index: number; bytes: Buffer }[]>`
      SELECT chunk_index, bytes FROM value_blob_chunks
      WHERE project_id = ${projectId} AND hash = ${hash}
        AND chunk_index BETWEEN ${startChunk} AND ${endChunk}
      ORDER BY chunk_index
    `;
    if (rows.length === 0) return new Uint8Array(0);
    const spanned = Buffer.concat(rows.map((r) => r.bytes));
    const spanStart = startChunk * CHUNK_SIZE;
    return spanned.subarray(start - spanStart, Math.min(spanned.length, end - spanStart));
  }

  // ── persistent files ──────────────────────────────────────────────────────

  async createFile(input: CreateFileInput): Promise<FileRecord> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`file too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    const size = input.bytes.length;
    const createdAt = await this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      await this.addBlobRef(sql, input.projectId, hash, input.bytes);
      const rows = await sql<{ created_at: Date }[]>`
        INSERT INTO api_files (project_id, id, hash, size, content_type, display_name)
        VALUES (${input.projectId}, ${id}, ${hash}, ${size}, ${input.contentType ?? null},
                ${input.displayName ?? null})
        RETURNING created_at
      `;
      return rows[0]?.created_at ?? new Date();
    });
    return {
      id,
      hash,
      size,
      contentType: input.contentType,
      displayName: input.displayName,
      createdAt: createdAt.toISOString(),
    };
  }

  async getFile(projectId: string, id: string): Promise<FileRecord | null> {
    const rows = await this.sql<DbFileRow[]>`
      SELECT id, hash, size, content_type, display_name, created_at
      FROM api_files WHERE project_id = ${projectId} AND id = ${id}
    `;
    return rows[0] !== undefined ? dbToFileRecord(rows[0]) : null;
  }

  async listFiles(projectId: string): Promise<FileRecord[]> {
    const rows = await this.sql<DbFileRow[]>`
      SELECT id, hash, size, content_type, display_name, created_at
      FROM api_files WHERE project_id = ${projectId}
      ORDER BY created_at DESC, id DESC
    `;
    return rows.map(dbToFileRecord);
  }

  async deleteFile(projectId: string, id: string): Promise<boolean> {
    return this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const deleted = await sql<{ hash: string }[]>`
        DELETE FROM api_files WHERE project_id = ${projectId} AND id = ${id}
        RETURNING hash
      `;
      const hash = deleted[0]?.hash;
      if (hash === undefined) return false;
      await this.releaseBlobs(sql, projectId, new Map([[hash, 1]]));
      return true;
    });
  }

  async persistRef(input: {
    projectId: string;
    module: EphemeralOwner;
    id: string;
    displayName?: string;
  }): Promise<FileRecord | null> {
    return this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const refRows = await sql<
        { hash: string | null; size: string | null; content_type: string | null }[]
      >`
        SELECT hash, size, content_type FROM value_refs
        WHERE project_id = ${input.projectId} AND owner_module = ${input.module}
          AND id = ${input.id} AND state = 'complete'
      `;
      const ref = refRows[0];
      if (ref === undefined || ref.hash === null || ref.size === null) return null;
      const fileId = uuidv7();
      // Share the existing blob (refcount += 1) — no chunk rewrite.
      await sql`
        UPDATE value_blobs SET ref_count = ref_count + 1, last_accessed_at = now()
        WHERE project_id = ${input.projectId} AND hash = ${ref.hash}
      `;
      const rows = await sql<{ created_at: Date }[]>`
        INSERT INTO api_files (project_id, id, hash, size, content_type, display_name)
        VALUES (${input.projectId}, ${fileId}, ${ref.hash}, ${ref.size}, ${ref.content_type},
                ${input.displayName ?? null})
        RETURNING created_at
      `;
      return {
        id: fileId,
        hash: ref.hash,
        size: Number(ref.size),
        contentType: ref.content_type ?? undefined,
        displayName: input.displayName,
        createdAt: (rows[0]?.created_at ?? new Date()).toISOString(),
      };
    });
  }

  // ── GC primitives ─────────────────────────────────────────────────────────

  async sweepUnreachable(
    projectId: string,
    reachable: ReadonlyArray<{ owner: EphemeralOwner; id: string }>,
  ): Promise<number> {
    const keep = new Set(reachable.map((r) => `${r.owner}|${r.id}`));
    return this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const all = await sql<{ owner_module: string; id: string; hash: string | null }[]>`
        SELECT owner_module, id, hash FROM value_refs WHERE project_id = ${projectId}
      `;
      const toDelete = all.filter((r) => !keep.has(`${r.owner_module}|${r.id}`));
      if (toDelete.length === 0) return 0;
      const hashCounts = new Map<string, number>();
      for (const row of toDelete) {
        await sql`
          DELETE FROM value_refs
          WHERE project_id = ${projectId} AND owner_module = ${row.owner_module} AND id = ${row.id}
        `;
        if (row.hash !== null) hashCounts.set(row.hash, (hashCounts.get(row.hash) ?? 0) + 1);
      }
      await this.releaseBlobs(sql, projectId, hashCounts);
      return toDelete.length;
    });
  }

  async sweepInstance(projectId: string, ownerInstanceId: string): Promise<number> {
    return this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const deleted = await sql<{ hash: string | null }[]>`
        DELETE FROM value_refs
        WHERE project_id = ${projectId} AND owner_instance_id = ${ownerInstanceId}
        RETURNING hash
      `;
      if (deleted.length === 0) return 0;
      const hashCounts = new Map<string, number>();
      for (const row of deleted) {
        if (row.hash !== null) hashCounts.set(row.hash, (hashCounts.get(row.hash) ?? 0) + 1);
      }
      await this.releaseBlobs(sql, projectId, hashCounts);
      return deleted.length;
    });
  }
}

type DbFileRow = {
  id: string;
  hash: string;
  size: string;
  content_type: string | null;
  display_name: string | null;
  created_at: Date;
};

function dbToFileRecord(row: DbFileRow): FileRecord {
  return {
    id: row.id,
    hash: row.hash,
    size: Number(row.size),
    contentType: row.content_type ?? undefined,
    displayName: row.display_name ?? undefined,
    createdAt: row.created_at.toISOString(),
  };
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
