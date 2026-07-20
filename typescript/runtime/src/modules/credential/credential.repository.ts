// Persistence for the `credentials` table — the single source of truth for OAuth token material
// (docs/2026-07-14-credentials-core.md §1). The repository speaks in SEALED values (the AES-GCM envelope);
// sealing and decoding stay with the callers, so this layer stays a pure row store.
//
// The `generation` column carries two distinct write intents:
//   - `upsert` (the authorization flow's completion) writes unconditionally and bumps the generation —
//     a new authorization always wins over whatever was stored;
//   - `saveWithGeneration` (a token-refresh write-back) is a compare-and-set — it lands only while the
//     row still holds the generation the caller read, so a rotation computed from a credential a
//     re-authorization has since replaced is refused instead of clobbering the newer grant.
//
// One rule keeps the compare-and-set sound across the row's whole LIFETIME, not just its current
// incarnation: every write stamps a generation strictly greater than any generation previously minted
// for this (project, name). A fresh insert seeds at the epoch-millisecond clock and an in-place write
// takes `max(current + 1, epoch ms)` — so after a `forget` + re-authorization the new row's generation
// still exceeds everything handed out before the delete, and a refresh write-back holding a pre-delete
// generation can never match the new account's row (the ABA that a fixed seed like 1 would reintroduce).

import { and, eq, sql } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { credentials } from "../../db/tables/credentials.js";

/** The next-generation expression for an in-place write: strictly above the current value AND at or
 *  above the wall clock, so it also stays above anything a deleted predecessor row ever handed out. */
function bumpedGeneration() {
  return sql`greatest(${credentials.generation} + 1, ${Date.now()})`;
}

export const credentialRepository = {
  /** One credential's sealed value + the generation it currently holds, or null when none is stored. */
  async load(
    executor: Executor,
    projectId: string,
    name: string,
  ): Promise<{ value: string; generation: number } | null> {
    const [row] = await executor
      .select({ value: credentials.value, generation: credentials.generation })
      .from(credentials)
      .where(and(eq(credentials.projectId, projectId), eq(credentials.name, name)))
      .limit(1);
    return row ?? null;
  },

  /** The refresh write-back: update the row only while it still holds `expectedGeneration`, bumping the
   *  generation so any other reader of the old version loses in turn. One atomic statement — the compare
   *  and the write cannot interleave with a concurrent authorization. Returns whether the write landed;
   *  an absent row also refuses (false), so a stale rotation never resurrects a deleted credential. */
  async saveWithGeneration(
    executor: Executor,
    projectId: string,
    name: string,
    value: string,
    expectedGeneration: number,
  ): Promise<boolean> {
    const updated = await executor
      .update(credentials)
      .set({ value, generation: bumpedGeneration() })
      .where(
        and(
          eq(credentials.projectId, projectId),
          eq(credentials.name, name),
          eq(credentials.generation, expectedGeneration),
        ),
      )
      .returning({ name: credentials.name });
    return updated.length > 0;
  },

  /** The authorization flow's deposit: insert or replace unconditionally, bumping the generation so any
   *  in-flight refresh that read the previous version is refused by its own compare-and-set. A fresh row
   *  seeds at the epoch-millisecond clock (not a constant), so it also outranks every generation a
   *  deleted predecessor row handed out — see the lifetime rule in the header. `profile` mirrors the
   *  sealed value's own tag onto the plaintext discriminant column (a re-authorization may switch it —
   *  the same name deposited through the other acquisition path replaces profile and value together). */
  async upsert(
    executor: Executor,
    projectId: string,
    name: string,
    value: string,
    profile: "mcp" | "configured",
  ): Promise<void> {
    await executor
      .insert(credentials)
      .values({ projectId, name, profile, value, generation: Date.now() })
      .onConflictDoUpdate({
        target: [credentials.projectId, credentials.name],
        // `updatedAt` must be set explicitly: the column's `$onUpdate` callback fires only for `.update()`
        // statements, not for an `onConflictDoUpdate` set-clause.
        set: {
          profile,
          value,
          generation: bumpedGeneration(),
          updatedAt: new Date(),
        },
      });
  },

  /** The stored credentials as metadata (name / profile / updatedAt). The sealed value is withheld: a
   *  credential is write-only over the API — deposited by the flow, only ever read by the runtime's own
   *  transport. The profile IS returned: it is the acquisition discriminant the admin dispatches on (a
   *  configured credential re-authorizes without a server URL), never token material. */
  async list(
    executor: Executor,
    projectId: string,
  ): Promise<Array<{ name: string; profile: "mcp" | "configured"; updatedAt: Date }>> {
    return executor
      .select({
        name: credentials.name,
        profile: credentials.profile,
        updatedAt: credentials.updatedAt,
      })
      .from(credentials)
      .where(eq(credentials.projectId, projectId))
      .orderBy(credentials.name);
  },

  /** Forget a credential (the operator's forced re-authorization). Returns whether a row existed. */
  async delete(executor: Executor, projectId: string, name: string): Promise<boolean> {
    const deleted = await executor
      .delete(credentials)
      .where(and(eq(credentials.projectId, projectId), eq(credentials.name, name)))
      .returning({ name: credentials.name });
    return deleted.length > 0;
  },
};
