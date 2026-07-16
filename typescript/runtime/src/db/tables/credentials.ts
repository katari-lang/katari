// The credential store: the single source of truth for the OAuth token material a workflow authenticates
// through (docs/2026-07-14-credentials-core.md §1). It generalizes the prototype's `mcp_credentials` table
// into a profile-tagged store — the sealed `value` carries a `profile` discriminator ("mcp" today), so the
// acquisition path (mcp discovery + dynamic client registration) is one variant of a common
// store / expiry / refresh / bearer-injection machinery. A dedicated table (not an env secret) so a
// credential carries its own compare-and-set `generation` column rather than a content hash, and so it
// never mingles with the user's real env keys.
//
// The `value` is the sealed `StoredCredential` JSON (see `runtime/external/credentials.ts`), AES-GCM sealed
// at rest exactly like an env secret (via `lib/crypto`); it is write-only over the admin API (a credential
// is deposited by the OAuth flow, listed and deleted by an operator, but never read back in plaintext). Two
// writers touch `generation` with different intent: the runtime-hosted flow's completion upserts
// unconditionally and bumps it ("a new authorization always wins"), while a token refresh writes back only
// when the generation still matches the one it read (a stale rotation loses to a fresh re-authorization).

import { bigint, pgTable, primaryKey, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { projects } from "./projects.js";

export const credentials = pgTable(
  "credentials",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The credential's name — what an `mcp.oauth(name = ...)` descriptor (and, in Phase 2, an
     *  `oauth.token(name)` request) references. */
    name: text("name").notNull(),
    /** The AES-GCM sealed `StoredCredential` JSON. Write-only over the API. */
    value: text("value").notNull(),
    /** The compare-and-set marker. The rule: every write stamps a generation strictly greater than any
     *  generation previously minted for this (project, name) — INCLUDING across a delete and a later
     *  re-creation of the row, or a stale refresh that captured its generation before a `forget` could
     *  match the re-authorized row and clobber the new account's tokens. A fresh row therefore seeds at
     *  the epoch-millisecond clock and an in-place write takes `max(current + 1, epoch ms)` (see the
     *  repository); epoch milliseconds need an int8, hence `bigint` (read back as a JS number — epoch
     *  scale sits far below 2^53). */
    generation: bigint("generation", { mode: "number" }).notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.name] })],
);
