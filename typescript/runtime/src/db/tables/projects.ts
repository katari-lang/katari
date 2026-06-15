// Hierarchy root: projects, snapshots (code versions), and ENV entries. A snapshot stores the whole
// IR as one structured blob (`modules`) — the IR is immutable code, read wholesale, so it is the one
// deliberate exception to row-wise normalisation.

import type { IRModule } from "@katari-lang/types";
import { boolean, jsonb, pgTable, primaryKey, text, timestamp, uuid } from "drizzle-orm/pg-core";

export const projects = pgTable("projects", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull().unique(),
  description: text("description"),
  readme: text("readme"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const snapshots = pgTable("snapshots", {
  id: uuid("id").primaryKey().defaultRandom(),
  projectId: uuid("project_id")
    .notNull()
    .references(() => projects.id, { onDelete: "cascade" }),
  /** The deployed IR, keyed by module name. Schemas live inside each `IRModule.schemas`. */
  modules: jsonb("modules").$type<Record<string, IRModule>>().notNull(),
  /** The bundled FFI/sidecar code for this version, if any. */
  sidecarBundle: jsonb("sidecar_bundle"),
  message: text("message").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const envEntries = pgTable(
  "env_entries",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    key: text("key").notNull(),
    /** Plaintext, or AES-GCM ciphertext when `isSecret`. */
    value: text("value").notNull(),
    isSecret: boolean("is_secret").notNull().default(false),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.key] })],
);
