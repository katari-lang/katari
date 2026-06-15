// The CORE engine graph, persisted row-wise (3NF): one row per thread, scope, and scope variable;
// blobs are a ledger (bytes live in the BlobStore). All cascade with their owner instance.
//
//   - threads: instance-local; cascade with the instance.
//   - scopes / blobs: CORE-global per project, owned by an instance (mutable on ascent → nullable);
//     cascade with the owner instance.
//   - scope_variables: cascade with their scope via a composite FK.
//
// The irreducibly-recursive leaves (a `Value`, a thread's variant state) stay as typed JSON columns —
// the structure is normalised, the leaves are not (a `Value` is a record/array/ref tree).

import type { Json } from "@katari-lang/types";
import {
  bigint,
  foreignKey,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uuid,
} from "drizzle-orm/pg-core";
import type { Thread, ThreadStatus } from "../../runtime/engine/types.js";
import type { GenericSubstitution, SemanticKind, Value } from "../../runtime/value/types.js";
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
    ambientGenerics: jsonb("ambient_generics").$type<GenericSubstitution>(),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.scopeId] })],
);

export const scopeVariables = pgTable(
  "scope_variables",
  {
    projectId: uuid("project_id").notNull(),
    scopeId: integer("scope_id").notNull(),
    varId: integer("var_id").notNull(),
    value: jsonb("value").$type<Value>().notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.projectId, table.scopeId, table.varId] }),
    // A variable lives exactly as long as its scope.
    foreignKey({
      columns: [table.projectId, table.scopeId],
      foreignColumns: [scopes.projectId, scopes.scopeId],
    }).onDelete("cascade"),
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
  (table) => [primaryKey({ columns: [table.projectId, table.blobId] })],
);
