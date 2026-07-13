// The MCP OAuth credential store: the single source of truth for the token material an `mcp.oauth(name)`
// descriptor authenticates through. It replaces the reserved `mcp.oauth.<name>` env-secret namespace the
// prototype used (see docs/2026-07-13-oauth-escalation.md §2) — a dedicated table so a credential carries
// its own compare-and-set `generation` column rather than a content hash, and so it never mingles with the
// user's real env keys.
//
// The `value` is the credential triple `{ tokens, clientInformation, resourceUrl }` as JSON, AES-GCM sealed
// at rest exactly like an env secret (via `lib/crypto`); it is write-only over the admin API (a credential
// is deposited by the OAuth flow, listed and deleted by an operator, but never read back in plaintext). Two
// writers touch `generation` with different intent: the runtime-hosted flow's completion upserts
// unconditionally and bumps it ("a new authorization always wins"), while a token refresh writes back only
// when the generation still matches the one it read (a stale rotation loses to a fresh re-authorization).

import { bigint, pgTable, primaryKey, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { projects } from "./projects.js";

export const mcpCredentials = pgTable(
  "mcp_credentials",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The credential's name — what an `mcp.oauth(name = ...)` descriptor references. */
    name: text("name").notNull(),
    /** The AES-GCM sealed `{ tokens, clientInformation, resourceUrl }` JSON. Write-only over the API. */
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
