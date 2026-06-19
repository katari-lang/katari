// Hierarchy root: projects, the content-addressed module store, snapshots (code versions), and ENV
// entries. The IR is split across two tables: `modules` holds each module's lowered IR keyed by its
// content hash (immutable, deduplicated), and a `snapshot` is a manifest — module name -> the
// `modules.hash` holding that module's IR — plus the sidecar bundle. So a deploy uploads only the
// modules that changed, and unchanged modules are shared (one row) across versions.
// `projects.head_snapshot_id` tracks the currently-live version (see
// docs/2026-06-19-per-module-snapshot.md).

import type { IRModule } from "@katari-lang/types";
import type { AnyPgColumn } from "drizzle-orm/pg-core";
import {
  boolean,
  index,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uuid,
} from "drizzle-orm/pg-core";
import type { ModuleHash } from "../../runtime/ids.js";

export const projects = pgTable("projects", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name").notNull().unique(),
  description: text("description"),
  readme: text("readme"),
  /** The currently-live snapshot ("head"): new runs start against it, a deploy advances it, and a
   *  rollback re-points it. Null until the first deploy; set null if that snapshot is ever removed. */
  headSnapshotId: uuid("head_snapshot_id").references((): AnyPgColumn => snapshots.id, {
    onDelete: "set null",
  }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

/**
 * The content-addressed IR store: one row per distinct module IR, keyed by its content `hash`.
 * Immutable — a new version of a module is a new hash and a new row — so snapshots that share an
 * unchanged module share this row. Retention is by reachability from a live snapshot (GC is a later
 * concern; v0.1 keeps everything).
 */
export const modules = pgTable(
  "modules",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** Hex SHA-256 of the module's canonical IR serialisation; the store's address. */
    hash: text("hash").$type<ModuleHash>().notNull(),
    /** One module's lowered IR, stored verbatim. */
    ir: jsonb("ir").$type<IRModule>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.hash] })],
);

export const snapshots = pgTable(
  "snapshots",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** This version's manifest: module name -> the `modules.hash` holding that module's IR. Resolved
     *  through the module store at run time; the hashes are validated against `modules` on deploy. */
    modules: jsonb("modules").$type<Record<string, ModuleHash>>().notNull(),
    /** The bundled FFI/sidecar code for this version, if any. */
    sidecarBundle: jsonb("sidecar_bundle"),
    message: text("message").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    // Every read path (list / head / detail) filters by project; the PK is on `id` alone, so without
    // this an unindexed `project_id` scan grows with every deploy across all projects.
    index("snapshots_project_id_idx").on(table.projectId),
  ],
);

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
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.key] })],
);
