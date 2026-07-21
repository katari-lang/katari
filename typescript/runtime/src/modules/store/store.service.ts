// The store resource: the project's durable key-value store backed by `store_entries` — the runtime
// half of `prelude.store`. Two callers: the api reactor's store responder (the `storeRows` port below,
// which machine-answers an unhandled `prelude.store.*` request) and the admin HTTP API (browse / edit the
// same tree). Values are Katari `Value` trees; `sealForStorage` turns every `private` node into ciphertext
// at this seam, so a stored secret is at rest exactly like a secret env entry, and the admin read path
// renders values through the redacting wire codec so a secret never crosses the API.
//
// A stored `file` reference points at an api-root-owned blob (the project's file library): a program's
// stored file is reassigned onto the api root as its request lands, and an uploaded file is api-root-owned
// from the start. So the store only ever forgets a reference — overwriting or deleting an entry never frees
// a file; a file is removed by an explicit delete through the file API / Files page (a stored reference to a
// file so deleted reads as `gone`, `prelude.files`' contract). The admin write path therefore accepts a
// `$katari_ref` value directly (it references a library file the api root already owns).

import { and, eq, like } from "drizzle-orm";
import { db } from "../../db/client.js";
import { storeEntries } from "../../db/tables/projects.js";
import { BadRequestError, NotFoundError } from "../../lib/errors.js";
import { sealForStorage, unsealFromStorage } from "../../runtime/actor/seal.js";
import type { StoreRows } from "../../runtime/actor/store-responder.js";
import type { ProjectId } from "../../runtime/ids.js";
import { jsonToValue, valueToJson } from "../../runtime/value/codec.js";
import type { Value } from "../../runtime/value/types.js";

/** The store responder's rows port (`store.get` / `set` / `delete` / `list`): the api reactor answers an
 *  unhandled `prelude.store.*` request through it, sealing / unsealing a `private` node at this seam. */
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

  /** Create / replace one entry from wire JSON. A `$katari_ref` is accepted: it references a library file
   *  the api root already owns (an upload, or a program's stored file), so writing the reference takes no
   *  blob ownership. */
  async set(projectId: string, key: string, wireValue: unknown) {
    if (key === "" || key.startsWith("/") || key.endsWith("/") || key.includes("//")) {
      throw new BadRequestError("a store key is a /-separated path with non-empty segments");
    }
    const value = jsonToValue(wireValue as never);
    await storeRows.upsert(projectId as ProjectId, key, value);
    return { key };
  },

  /** Delete one entry (idempotent). A file the entry referenced stays in the project's file library —
   *  removing it is the file API / Files page's job (see the module note). */
  async delete(projectId: string, key: string) {
    await storeRows.remove(projectId as ProjectId, key);
  },
};
