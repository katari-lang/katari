// The store resource: the project's durable key-value store backed by `store_entries` — the runtime
// half of `prelude.store`. Two callers: the engine's store primitives (the `storeRows` port below,
// wired into the `PrimRegistry`) and the admin HTTP API (browse / edit the same tree). Values are
// Katari `Value` trees; `sealForStorage` turns every `private` node into ciphertext at this seam, so
// a stored secret is at rest exactly like a secret env entry, and the admin read path renders values
// through the redacting wire codec so a secret never crosses the API.
//
// Admin writes are plain values only: a wire value carrying a `$katari_ref` is rejected, because
// taking a blob's ownership is the project actor's business (the engine prims go through
// `storeEffects`; an admin path onto the actor is a later step). Admin deletes drop the row and
// leave a referenced blob on the store sentinel — a bounded leak the project cascade reclaims —
// rather than freeing bytes behind the running actor's warm catalog.

import { and, eq, like, ne, sql } from "drizzle-orm";
import { db } from "../../db/client.js";
import { instances } from "../../db/tables/execution.js";
import { storeEntries } from "../../db/tables/projects.js";
import { BadRequestError, NotFoundError } from "../../lib/errors.js";
import { sealForStorage, unsealFromStorage } from "../../runtime/actor/seal.js";
import type { StoreRows } from "../../runtime/engine/host-prims.js";
import type { BlobId, ProjectId } from "../../runtime/ids.js";
import { storeRootIdOf } from "../../runtime/ids.js";
import { jsonToValue, valueToJson } from "../../runtime/value/codec.js";
import type { Value } from "../../runtime/value/types.js";

/** Ensure the project's store sentinel instance row exists — the owner every stored blob's FK points
 *  at. Idempotent; kind `store` is loaded by no reactor, so the row is pure ownership anchor. */
async function ensureStoreRoot(projectId: ProjectId): Promise<void> {
  await db
    .insert(instances)
    .values({
      id: storeRootIdOf(projectId),
      projectId,
      kind: "store",
      status: "running",
    })
    .onConflictDoNothing();
}

/** The engine-facing rows port the host wires into the `PrimRegistry` (`store.get` / `set` / ...). */
export const storeRows: StoreRows = {
  async read(projectId: ProjectId, key: string) {
    const [row] = await db
      .select({ value: storeEntries.value })
      .from(storeEntries)
      .where(and(eq(storeEntries.projectId, projectId), eq(storeEntries.key, key)))
      .limit(1);
    if (row === undefined) return undefined;
    return unsealFromStorage(row.value as Value);
  },

  async upsert(projectId: ProjectId, key: string, value: Value) {
    await ensureStoreRoot(projectId);
    const sealed = sealForStorage(value);
    await db
      .insert(storeEntries)
      .values({ projectId, key, value: sealed })
      .onConflictDoUpdate({
        target: [storeEntries.projectId, storeEntries.key],
        set: { value: sealed, updatedAt: new Date() },
      });
  },

  async remove(projectId: ProjectId, key: string) {
    await db
      .delete(storeEntries)
      .where(and(eq(storeEntries.projectId, projectId), eq(storeEntries.key, key)));
  },

  async listKeys(projectId: ProjectId, prefix: string) {
    const under =
      prefix === ""
        ? eq(storeEntries.projectId, projectId)
        : and(
            eq(storeEntries.projectId, projectId),
            like(storeEntries.key, `${escapeLikePattern(prefix)}/%`),
          );
    const rows = await db
      .select({ key: storeEntries.key })
      .from(storeEntries)
      .where(under)
      .orderBy(storeEntries.key);
    return rows.map((row) => row.key);
  },

  async isBlobReferenced(projectId: ProjectId, blobId: BlobId, exceptKey: string) {
    // A blob reference is a `"blobId": "<uuid>"` leaf in the stored JSON; the id is a UUID, so a
    // plain text containment probe cannot false-positive on user content shaped like one only by
    // guessing the exact id — and a false positive merely keeps a blob alive.
    const [row] = await db
      .select({ key: storeEntries.key })
      .from(storeEntries)
      .where(
        and(
          eq(storeEntries.projectId, projectId),
          ne(storeEntries.key, exceptKey),
          sql`${storeEntries.value}::text like ${`%"blobId":"${blobId}"%`}`,
        ),
      )
      .limit(1);
    return row !== undefined;
  },
};

/** LIKE-escape a key prefix so `%` / `_` in a key name match literally. */
function escapeLikePattern(prefix: string): string {
  return prefix.replace(/[\\%_]/g, (match) => `\\${match}`);
}

export const storeService = {
  /** Every entry's key + timestamp (values withheld — an entry may be large or secret; `get` reads one). */
  async list(projectId: string) {
    return db
      .select({ key: storeEntries.key, updatedAt: storeEntries.updatedAt })
      .from(storeEntries)
      .where(eq(storeEntries.projectId, projectId))
      .orderBy(storeEntries.key);
  },

  /** One entry's value as redacting wire JSON (a `private` node reads as `$katari_redacted`). */
  async get(projectId: string, key: string) {
    const value = await storeRows.read(projectId as ProjectId, key);
    if (value === undefined) throw new NotFoundError(`no store entry at "${key}"`);
    return { key, value: valueToJson(value, "redact") };
  },

  /** Create / replace one entry from wire JSON. Plain values only: a `$katari_ref` needs the actor
   *  to take blob ownership, which the admin path does not do — store a file from a program. */
  async set(projectId: string, key: string, wireValue: unknown) {
    if (key === "" || key.startsWith("/") || key.endsWith("/") || key.includes("//")) {
      throw new BadRequestError("a store key is a /-separated path with non-empty segments");
    }
    const value = jsonToValue(wireValue as never);
    if (referencesBlob(value)) {
      throw new BadRequestError(
        "a file handle cannot be stored through the admin API — store it from a program (`store.set`)",
      );
    }
    await storeRows.upsert(projectId as ProjectId, key, value);
    return { key };
  },

  /** Delete one entry (idempotent). A blob only this entry referenced stays on the store sentinel
   *  (reclaimed with the project) — see the module note. */
  async delete(projectId: string, key: string) {
    await storeRows.remove(projectId as ProjectId, key);
  },
};

function referencesBlob(value: Value): boolean {
  switch (value.kind) {
    case "ref":
      return true;
    case "record":
      return Object.values(value.fields).some(referencesBlob);
    case "array":
      return value.elements.some(referencesBlob);
    default:
      return false;
  }
}
