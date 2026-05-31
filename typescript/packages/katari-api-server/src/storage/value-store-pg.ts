// Postgres-backed `ValueStore`. Metadata (`value_refs` / `api_files` /
// `value_blobs` refcount) lives in Postgres; the blob BYTES are delegated to a
// pluggable `BlobStore` (local FS / S3 / memory — see blob-store.ts). Postgres
// is a poor home for large binaries, so only the refcount ledger stays here.
//
// Blobs are content-addressed and deduped: producing the same bytes twice
// keeps one blob with `ref_count = 2` (and one physical object). The bytes are
// written to the BlobStore on the FIRST ref and physically deleted only after
// the refcount sweep drops the ledger row to zero.
//
// Ordering / crash-safety (v0.1.0, single POST ≤ 10 MB):
//   - produce: the BlobStore.put runs inside the producing transaction (on
//     first ref). A rollback after the put leaves an orphan blob, reclaimed by
//     GC — never a dangling ref (the ref row rolls back with it).
//   - release: the refcount decrement + ledger-row delete commit FIRST; the
//     physical BlobStore.delete runs AFTER commit. A crash in between leaves an
//     orphan blob (reclaimed by GC), never bytes deleted out from under a live
//     ref.

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
  type RefHandle,
  type RefModule,
  type RefState,
  type ValueRefState,
  type ValueSemanticKind,
  type ValueStore,
} from "@katari-lang/runtime";
import type postgres from "postgres";
import { v7 as uuidv7 } from "uuid";
import type { BlobStore } from "./blob-store.js";

type Sql = ReturnType<typeof postgres>;

export class PgValueStore implements ValueStore {
  constructor(
    private readonly sql: Sql,
    private readonly blobStore: BlobStore,
  ) {}

  // ── blob refcount lifecycle ───────────────────────────────────────────────

  /**
   * Create-or-increment the blob ledger row for `hash`. On the FIRST insert,
   * writes the bytes to the BlobStore. Caller MUST run this inside a
   * transaction together with inserting the referring row.
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
    if (!inserted) return; // dedup: bytes already stored under this hash
    await this.blobStore.put(projectId, hash, bytes);
  }

  /**
   * Decrement refcounts (with multiplicity), delete any ledger row that fell
   * to zero, and RETURN those swept hashes. Pure Postgres work — the physical
   * `BlobStore.delete` is the caller's job, AFTER the surrounding tx commits.
   */
  private async releaseBlobs(
    sql: Sql,
    projectId: string,
    hashCounts: Map<string, number>,
  ): Promise<string[]> {
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
    return swept.map((r) => r.hash);
  }

  /** Physically remove swept blobs from the BlobStore (post-commit). */
  private async deleteBlobBytes(projectId: string, hashes: string[]): Promise<void> {
    for (const hash of hashes) {
      await this.blobStore.delete(projectId, hash);
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
        ownerDelegationId: input.ownerDelegationId,
        refsTo: input.refsTo ?? [],
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
            ownerDelegationId: input.ownerDelegationId,
            refsTo: input.refsTo ?? [],
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
          ownerDelegationId: input.ownerDelegationId,
          refsTo: input.refsTo ?? [],
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
      ownerDelegationId?: string;
      refsTo: ReadonlyArray<RefHandle>;
      hash: string | null;
      size: number | null;
      contentType?: string;
      errorMessage?: string;
    },
  ): Promise<void> {
    await sql`
      INSERT INTO value_refs
        (project_id, owner_module, id, state, semantic_kind, owner_delegation_id, refs_to,
         hash, size, content_type, error_message)
      VALUES
        (${row.projectId}, ${row.owner}, ${row.id}, ${row.state}, ${row.semanticKind},
         ${row.ownerDelegationId ?? null}, ${this.sql.json([...row.refsTo]) as never},
         ${row.hash}, ${row.size}, ${row.contentType ?? null}, ${row.errorMessage ?? null})
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
    return this.blobStore.get(projectId, hash);
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
    return this.blobStore.getRange(projectId, hash, offset, length);
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
    const swept = await this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const deleted = await sql<{ hash: string }[]>`
        DELETE FROM api_files WHERE project_id = ${projectId} AND id = ${id}
        RETURNING hash
      `;
      const hash = deleted[0]?.hash;
      if (hash === undefined) return null;
      return this.releaseBlobs(sql, projectId, new Map([[hash, 1]]));
    });
    if (swept === null) return false;
    await this.deleteBlobBytes(projectId, swept);
    return true;
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
      // Share the existing blob (refcount += 1) — no byte rewrite.
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

  // ── ownership transitions (single-owner GC) ─────────────────────────────

  /**
   * Load all refs owned by `ownerId`, then BFS from `seed` through `refs_to`
   * (staying within this owner's refs) to compute the keep/move set + the rows
   * to drop. Pure read; the caller applies the writes in its tx.
   */
  private async expandOwned(
    sql: Sql,
    projectId: string,
    ownerId: string,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<{ owned: OwnedRefRow[]; keep: Set<string> }> {
    const owned = await sql<OwnedRefRow[]>`
      SELECT owner_module, id, hash, refs_to FROM value_refs
      WHERE project_id = ${projectId} AND owner_delegation_id = ${ownerId}
    `;
    const byKey = new Map(owned.map((r) => [`${r.owner_module}|${r.id}`, r]));
    const keep = new Set<string>();
    const worklist = seed.map((h) => `${h.module}|${h.id}`);
    while (worklist.length > 0) {
      const key = worklist.pop()!;
      if (keep.has(key)) continue;
      const row = byKey.get(key);
      if (row === undefined) continue; // owned by someone higher / unknown
      keep.add(key);
      for (const child of row.refs_to) worklist.push(`${child.module}|${child.id}`);
    }
    return { owned, keep };
  }

  async releaseOwner(
    projectId: string,
    ownerId: string,
    toOwnerId: string,
    escapeSeed: ReadonlyArray<RefHandle>,
  ): Promise<number> {
    const swept = await this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const { owned, keep } = await this.expandOwned(sql, projectId, ownerId, escapeSeed);
      const hashCounts = new Map<string, number>();
      for (const row of owned) {
        const key = `${row.owner_module}|${row.id}`;
        if (keep.has(key)) {
          await sql`
            UPDATE value_refs SET owner_delegation_id = ${toOwnerId}
            WHERE project_id = ${projectId} AND owner_module = ${row.owner_module} AND id = ${row.id}
          `;
        } else {
          await sql`
            DELETE FROM value_refs
            WHERE project_id = ${projectId} AND owner_module = ${row.owner_module} AND id = ${row.id}
          `;
          if (row.hash !== null) hashCounts.set(row.hash, (hashCounts.get(row.hash) ?? 0) + 1);
        }
      }
      return this.releaseBlobs(sql, projectId, hashCounts);
    });
    await this.deleteBlobBytes(projectId, swept);
    return swept.length;
  }

  async transferOwnership(
    projectId: string,
    fromOwnerId: string,
    toOwnerId: string,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<void> {
    await this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const { keep } = await this.expandOwned(sql, projectId, fromOwnerId, seed);
      for (const key of keep) {
        const [owner_module, id] = key.split("|");
        await sql`
          UPDATE value_refs SET owner_delegation_id = ${toOwnerId}
          WHERE project_id = ${projectId} AND owner_module = ${owner_module!} AND id = ${id!}
        `;
      }
    });
  }

  async sweepRefsWithDeadOwners(
    projectId: string,
    liveOwnerIds: ReadonlySet<string>,
  ): Promise<number> {
    const swept = await this.sql.begin(async (tx) => {
      const sql = tx as unknown as Sql;
      const live = [...liveOwnerIds];
      // Drop owned refs whose owner is gone. `= ANY` with an empty array is
      // false, so when nothing is live every owned ref is swept.
      const deleted = await sql<{ hash: string | null }[]>`
        DELETE FROM value_refs
        WHERE project_id = ${projectId}
          AND owner_delegation_id IS NOT NULL
          AND NOT (owner_delegation_id = ANY(${live as never}))
        RETURNING hash
      `;
      if (deleted.length === 0) return [] as string[];
      const hashCounts = new Map<string, number>();
      for (const row of deleted) {
        if (row.hash !== null) hashCounts.set(row.hash, (hashCounts.get(row.hash) ?? 0) + 1);
      }
      return this.releaseBlobs(sql, projectId, hashCounts);
    });
    await this.deleteBlobBytes(projectId, swept);
    return swept.length;
  }
}

type OwnedRefRow = {
  owner_module: EphemeralOwner;
  id: string;
  hash: string | null;
  refs_to: RefHandle[];
};

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
