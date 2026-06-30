// The env resource: a project-scoped key/value store backed by the `env_entries` table. It serves two
// callers — the admin HTTP API (list / get / set / delete) and the engine's env primitives (the
// `envReader` below, which the host wires into the `PrimRegistry`). Secret entries are encrypted at rest
// (AES-GCM, via `lib/crypto`); non-secret entries are stored in plaintext.
//
// Read policy: a secret's plaintext never crosses the admin API — `list` returns metadata only and `get`
// redacts a secret's value. A program reads a secret through `env.get_secret`, which yields a tainted
// `string of private` that the user-facing boundary redacts.

import { and, eq } from "drizzle-orm";
import { db } from "../../db/client.js";
import { envEntries } from "../../db/tables/projects.js";
import { decryptSecret, encryptSecret } from "../../lib/crypto.js";
import { NotFoundError } from "../../lib/errors.js";
import type { EnvReader } from "../../runtime/engine/host-prims.js";
import type { ProjectId } from "../../runtime/ids.js";
import type { SetEnvBody } from "./env.schema.js";

export const envService = {
  /** List entries as metadata (key / isSecret / updatedAt). Values are withheld: listing is for
   *  management, and a secret must not be read back in plaintext. */
  async list(projectId: string) {
    return db
      .select({
        key: envEntries.key,
        isSecret: envEntries.isSecret,
        updatedAt: envEntries.updatedAt,
      })
      .from(envEntries)
      .where(eq(envEntries.projectId, projectId));
  },

  /** Read one entry. A non-secret entry returns its value; a secret entry returns metadata only — its
   *  value is write-only over the API (read it from a program via `env.get_secret`). */
  async get(projectId: string, key: string) {
    const [row] = await db
      .select()
      .from(envEntries)
      .where(and(eq(envEntries.projectId, projectId), eq(envEntries.key, key)))
      .limit(1);
    if (row === undefined) {
      throw new NotFoundError(`no env entry "${key}"`);
    }
    return row.isSecret
      ? { key: row.key, isSecret: true as const, updatedAt: row.updatedAt }
      : { key: row.key, isSecret: false as const, value: row.value, updatedAt: row.updatedAt };
  },

  /** Insert or replace an entry. A secret value is encrypted at rest; a non-secret value is stored in
   *  plaintext. Re-keying a secret as non-secret (or vice versa) overwrites both columns. */
  async set(projectId: string, key: string, body: SetEnvBody) {
    const isSecret = body.isSecret ?? false;
    const value = isSecret ? encryptSecret(body.value) : body.value;
    await db
      .insert(envEntries)
      .values({ projectId, key, value, isSecret })
      .onConflictDoUpdate({
        target: [envEntries.projectId, envEntries.key],
        set: { value, isSecret },
      });
  },

  async delete(projectId: string, key: string) {
    await db
      .delete(envEntries)
      .where(and(eq(envEntries.projectId, projectId), eq(envEntries.key, key)));
  },
};

/** The engine-facing reader the host wires into the `PrimRegistry` (`env.get_secret` / `env.get_all`). */
export const envReader: EnvReader = {
  async readSecret(projectId: ProjectId, key: string) {
    const [row] = await db
      .select({ value: envEntries.value, isSecret: envEntries.isSecret })
      .from(envEntries)
      .where(and(eq(envEntries.projectId, projectId), eq(envEntries.key, key)))
      .limit(1);
    if (row === undefined || !row.isSecret) {
      return null;
    }
    return decryptSecret(row.value);
  },

  async readPublic(projectId: ProjectId) {
    const rows = await db
      .select({ key: envEntries.key, value: envEntries.value })
      .from(envEntries)
      .where(and(eq(envEntries.projectId, projectId), eq(envEntries.isSecret, false)));
    const result: Record<string, string> = {};
    for (const row of rows) {
      result[row.key] = row.value;
    }
    return result;
  },
};
