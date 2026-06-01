// Postgres-backed `ValueStore` (Entity model). Metadata (`refs` + `value_blobs`
// refcount ledger) lives in Postgres; the blob BYTES are delegated to a
// pluggable `BlobStore` (local FS / S3 / memory — see blob-store.ts).
//
// Blobs are content-addressed + deduped: producing the same bytes twice keeps
// one blob with `ref_count = 2` (one physical object). The refcount is
// maintained by the `AFTER DELETE ON refs` trigger (schema.sql) — so deleting a
// ref (explicitly, or by entity CASCADE) decrements automatically; this code
// never decrements by hand. Bytes are written on the first ref and physically
// deleted by `reapFreedBlobs` once the ledger row hits 0.
//
// Ownership (docs/2026-06-01-entity-model.md): a ref is owned by exactly one
// ENTITY (`owner_entity_id`), or transiently by NULL mid-ascent. `reownRefs` is
// the one primitive behind detach / claim / persist; a delegation never owns a
// ref. `reapFreedBlobs` reclaims zero-refcount blob bytes; `sweepDetachedRefs`
// is the boot crash-backstop for in-transit (NULL-owner) leftovers.

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

  /**
   * Run `fn` atomically. postgres.js exposes `.begin` on the ROOT sql but NOT on
   * a transaction-scoped one (the callback arg of an outer `begin`) — calling
   * `this.sql.begin` there throws "is not a function". So: open a fresh tx when
   * we hold the root sql, otherwise run directly on `this.sql` (already inside
   * the caller's tx — e.g. CoreModule.feed or a route's `withTransaction`, which
   * provides the atomicity).
   */
  private inTx<T>(fn: (sql: Sql) => Promise<T>): Promise<T> {
    const begin = (
      this.sql as unknown as { begin?: (cb: (tx: unknown) => Promise<T>) => Promise<T> }
    ).begin;
    if (typeof begin === "function") {
      return begin.call(this.sql, (tx: unknown) => fn(tx as Sql));
    }
    return fn(this.sql);
  }

  // ── blob refcount lifecycle ───────────────────────────────────────────────

  /**
   * Create-or-increment the blob ledger row for `hash`. On the FIRST insert,
   * writes the bytes to the BlobStore. Caller MUST run this inside a transaction
   * together with inserting the referring ref row. (Decrement is the trigger's
   * job — never done here.)
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

  /** Increment an EXISTING blob's refcount (a new ref sharing stored bytes). */
  private async shareBlob(sql: Sql, projectId: string, hash: string) {
    await sql`
      UPDATE value_blobs SET ref_count = ref_count + 1, last_accessed_at = now()
      WHERE project_id = ${projectId} AND hash = ${hash}
    `;
  }

  // ── produce ───────────────────────────────────────────────────────────────

  async putComplete(input: PutInput): Promise<ProduceResult> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`value too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    const size = input.bytes.length;
    await this.inTx(async (sql) => {
      await this.addBlobRef(sql, input.projectId, hash, input.bytes);
      await this.insertRefRow(sql, {
        projectId: input.projectId,
        module: input.owner,
        id,
        ownerEntityId: input.ownerEntityId,
        state: "complete",
        semanticKind: input.semanticKind,
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
        await self.inTx(async (sql) => {
          await self.addBlobRef(sql, input.projectId, hash, bytes);
          await self.insertRefRow(sql, {
            projectId: input.projectId,
            module: input.owner,
            id,
            ownerEntityId: input.ownerEntityId,
            state: "complete",
            semanticKind: input.semanticKind,
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
          module: input.owner,
          id,
          ownerEntityId: input.ownerEntityId,
          state: "errored",
          semanticKind: input.semanticKind,
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
      module: RefModule;
      id: string;
      ownerEntityId?: string;
      state: ValueRefState;
      semanticKind: ValueSemanticKind;
      refsTo: ReadonlyArray<RefHandle>;
      hash: string | null;
      size: number | null;
      contentType?: string;
      displayName?: string;
      errorMessage?: string;
    },
  ): Promise<void> {
    await sql`
      INSERT INTO refs
        (project_id, module, id, owner_entity_id, state, semantic_kind, refs_to,
         hash, size, content_type, display_name, error_message)
      VALUES
        (${row.projectId}, ${row.module}, ${row.id}, ${row.ownerEntityId ?? null}, ${row.state},
         ${row.semanticKind}, ${this.sql.json([...row.refsTo]) as never},
         ${row.hash}, ${row.size}, ${row.contentType ?? null}, ${row.displayName ?? null},
         ${row.errorMessage ?? null})
    `;
  }

  // ── consume ───────────────────────────────────────────────────────────────

  async getState(projectId: string, module: RefModule, id: string): Promise<RefState | null> {
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
      FROM refs
      WHERE project_id = ${projectId} AND module = ${module} AND id = ${id}
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
    const rows = await this.sql<{ hash: string | null }[]>`
      SELECT hash FROM refs
      WHERE project_id = ${projectId} AND module = ${module} AND id = ${id}
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

  // ── durable files (module = "api" refs) ─────────────────────────────────────

  async createFile(input: CreateFileInput): Promise<FileRecord> {
    if (input.bytes.length > MAX_PRODUCE_BYTES) {
      throw new Error(`file too large: ${input.bytes.length} > ${MAX_PRODUCE_BYTES}`);
    }
    const id = uuidv7();
    const hash = hashBytes(input.bytes);
    const size = input.bytes.length;
    await this.inTx(async (sql) => {
      await this.addBlobRef(sql, input.projectId, hash, input.bytes);
      await this.insertRefRow(sql, {
        projectId: input.projectId,
        module: "api",
        id,
        ownerEntityId: input.ownerEntityId,
        state: "complete",
        semanticKind: "file",
        refsTo: [],
        hash,
        size,
        contentType: input.contentType,
        displayName: input.displayName,
      });
    });
    return {
      id,
      hash,
      size,
      contentType: input.contentType,
      displayName: input.displayName,
      createdAt: new Date().toISOString(),
    };
  }

  async getFile(projectId: string, id: string): Promise<FileRecord | null> {
    const rows = await this.sql<DbFileRow[]>`
      SELECT id, hash, size, content_type, display_name, created_at
      FROM refs WHERE project_id = ${projectId} AND module = 'api' AND id = ${id}
        AND state = 'complete'
    `;
    return rows[0] !== undefined ? dbToFileRecord(rows[0]) : null;
  }

  async listFiles(projectId: string): Promise<FileRecord[]> {
    // Durable project files = the `file` refs owned by the project-root entity
    // (whose id IS the project id; see entity-roots.ts). Ownership is the single
    // source of truth for lifetime — no separate durability flag.
    const rows = await this.sql<DbFileRow[]>`
      SELECT id, hash, size, content_type, display_name, created_at
      FROM refs WHERE project_id = ${projectId} AND owner_entity_id = ${projectId}
        AND semantic_kind = 'file' AND state = 'complete'
      ORDER BY created_at DESC, id DESC
    `;
    return rows.map(dbToFileRecord);
  }

  async deleteFile(projectId: string, id: string): Promise<boolean> {
    const swept = await this.inTx(async (sql) => {
      const deleted = await sql<{ id: string }[]>`
        DELETE FROM refs WHERE project_id = ${projectId} AND module = 'api' AND id = ${id}
        RETURNING id
      `;
      if (deleted.length === 0) return null;
      // The trigger decremented the blob; reap any that hit 0 (in this tx).
      return sql<{ hash: string }[]>`
        DELETE FROM value_blobs WHERE project_id = ${projectId} AND ref_count <= 0 RETURNING hash
      `;
    });
    if (swept === null) return false;
    await this.deleteBlobBytes(
      projectId,
      swept.map((r) => r.hash),
    );
    return true;
  }

  async persistRef(input: {
    projectId: string;
    module: ProduceModule;
    id: string;
    ownerEntityId: string;
    displayName?: string;
  }): Promise<FileRecord | null> {
    return this.inTx(async (sql) => {
      const refRows = await sql<
        { hash: string | null; size: string | null; content_type: string | null }[]
      >`
        SELECT hash, size, content_type FROM refs
        WHERE project_id = ${input.projectId} AND module = ${input.module}
          AND id = ${input.id} AND state = 'complete'
      `;
      const ref = refRows[0];
      if (ref === undefined || ref.hash === null || ref.size === null) return null;
      const fileId = uuidv7();
      await this.shareBlob(sql, input.projectId, ref.hash); // share the blob (refcount += 1)
      await this.insertRefRow(sql, {
        projectId: input.projectId,
        module: "api",
        id: fileId,
        ownerEntityId: input.ownerEntityId,
        state: "complete",
        semanticKind: "file",
        refsTo: [],
        hash: ref.hash,
        size: Number(ref.size),
        contentType: ref.content_type ?? undefined,
        displayName: input.displayName,
      });
      return {
        id: fileId,
        hash: ref.hash,
        size: Number(ref.size),
        contentType: ref.content_type ?? undefined,
        displayName: input.displayName,
        createdAt: new Date().toISOString(),
      };
    });
  }

  // ── ownership: value-driven ascent ───────────────────────────────────────

  /**
   * BFS from `seed` through `refs_to`, restricted to refs whose current owner is
   * `fromOwner` (an entity id, or `null` for in-transit refs). Returns the keys
   * `module|id` to move. Pure read; the caller applies the UPDATE in its tx.
   */
  private async expandOwned(
    sql: Sql,
    projectId: string,
    fromOwner: string | null,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<{ owned: Map<string, OwnedRefRow>; keep: Set<string> }> {
    const ownedRows = await sql<OwnedRefRow[]>`
      SELECT module, id, refs_to FROM refs
      WHERE project_id = ${projectId} AND owner_entity_id IS NOT DISTINCT FROM ${fromOwner}
    `;
    const owned = new Map(ownedRows.map((r) => [`${r.module}|${r.id}`, r]));
    const keep = new Set<string>();
    const worklist = seed.map((h) => `${h.module}|${h.id}`);
    while (worklist.length > 0) {
      const key = worklist.pop()!;
      if (keep.has(key)) continue;
      const row = owned.get(key);
      if (row === undefined) continue; // owned by someone else / unknown
      keep.add(key);
      for (const child of row.refs_to) worklist.push(`${child.module}|${child.id}`);
    }
    return { owned, keep };
  }

  async reownRefs(
    projectId: string,
    fromOwner: string | null,
    toOwner: string | null,
    seed: ReadonlyArray<RefHandle>,
  ): Promise<void> {
    if (seed.length === 0) return;
    await this.inTx(async (sql) => {
      const { keep } = await this.expandOwned(sql, projectId, fromOwner, seed);
      for (const key of keep) {
        const [module, id] = key.split("|");
        await sql`
          UPDATE refs SET owner_entity_id = ${toOwner}
          WHERE project_id = ${projectId} AND module = ${module!} AND id = ${id!}
        `;
      }
    });
  }

  async reapFreedBlobs(projectId: string): Promise<number> {
    const swept = await this.sql<{ hash: string }[]>`
      DELETE FROM value_blobs WHERE project_id = ${projectId} AND ref_count <= 0 RETURNING hash
    `;
    await this.deleteBlobBytes(
      projectId,
      swept.map((r) => r.hash),
    );
    return swept.length;
  }

  async sweepDetachedRefs(projectId: string): Promise<number> {
    const swept = await this.inTx(async (sql) => {
      // Drop in-transit (orphaned) refs; the trigger decrements their blobs.
      await sql`
        DELETE FROM refs WHERE project_id = ${projectId} AND owner_entity_id IS NULL
      `;
      return sql<{ hash: string }[]>`
        DELETE FROM value_blobs WHERE project_id = ${projectId} AND ref_count <= 0 RETURNING hash
      `;
    });
    await this.deleteBlobBytes(
      projectId,
      swept.map((r) => r.hash),
    );
    return swept.length;
  }

  /** Physically remove swept blobs from the BlobStore (post-commit). */
  private async deleteBlobBytes(projectId: string, hashes: string[]): Promise<void> {
    for (const hash of hashes) {
      await this.blobStore.delete(projectId, hash);
    }
  }
}

type OwnedRefRow = {
  module: RefModule;
  id: string;
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
