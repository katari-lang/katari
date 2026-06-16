// The CORE engine graph, persisted row-wise (3NF): one row per thread and per scope; blobs are a
// ledger (bytes live in the BlobStore). All cascade with their owner instance.
//
//   - threads: instance-local; cascade with the instance.
//   - scopes / blobs: CORE-global per project, owned by an instance (mutable on ascent → nullable);
//     cascade with the owner instance.
//
// A scope's variables are not their own table: nothing fetches a single variable across scopes, and a
// `Value` is already an irreducible JSON leaf, so decomposing the map into rows buys no relational
// structure — the whole variable map rides inline in `scopes.values` (the engine holds it as one inline
// map too). The other recursive leaf (a thread's variant state) likewise stays a typed JSON column.

import type { Json } from "@katari-lang/types";
import {
  bigint,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uuid,
} from "drizzle-orm/pg-core";
import type { Thread, ThreadStatus } from "../../runtime/engine/types.js";
import type { SemanticKind, Value } from "../../runtime/value/types.js";
import { instances } from "./execution.js";
import { projects } from "./projects.js";

export const threads = pgTable(
  "threads",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    instanceId: uuid("instance_id")
      .notNull()
      .references(() => instances.id, { onDelete: "cascade" }),
    threadId: integer("thread_id").notNull(),
    kind: text("kind").$type<Thread["kind"]>().notNull(),
    parentThreadId: integer("parent_thread_id"),
    parentCallId: integer("parent_call_id"),
    scopeId: integer("scope_id").notNull(),
    blockId: integer("block_id").notNull(),
    status: text("status").$type<ThreadStatus>().notNull(),
    /** The kind-specific execution state (the `Thread` variant minus the columns above). */
    payload: jsonb("payload").$type<Json>().notNull(),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.instanceId, table.threadId] })],
);

export const scopes = pgTable(
  "scopes",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    scopeId: integer("scope_id").notNull(),
    parentScopeId: integer("parent_scope_id"),
    /** The owning instance; `null` while in-transit mid-ascent. Cascades on owner delete. */
    ownerInstanceId: uuid("owner_instance_id").references(() => instances.id, {
      onDelete: "cascade",
    }),
    /** This scope's variable slots, `VariableId -> Value`, inline (see the file header). */
    values: jsonb("values").$type<Record<number, Value>>().notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.projectId, table.scopeId] }),
    // The engine loads / ascends scopes by owner, so the partial-load and ascent paths need this.
    index("scopes_owner_instance_id_idx").on(table.ownerInstanceId),
  ],
);

export const blobs = pgTable(
  "blobs",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    blobId: uuid("blob_id").notNull(),
    /** The owning instance; `null` while in-transit mid-ascent. Cascades on owner delete. */
    ownerInstanceId: uuid("owner_instance_id").references(() => instances.id, {
      onDelete: "cascade",
    }),
    /** Content hash (for `string == string` content comparison); the BlobStore is keyed by `blobId`. */
    hash: text("hash").notNull(),
    size: bigint("size", { mode: "number" }).notNull(),
    contentType: text("content_type"),
    semanticKind: text("semantic_kind").$type<SemanticKind>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    primaryKey({ columns: [table.projectId, table.blobId] }),
    // Loaded / ascended by owner, like scopes.
    index("blobs_owner_instance_id_idx").on(table.ownerInstanceId),
  ],
);
