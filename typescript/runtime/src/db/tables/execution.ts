// The execution layer: instances (the ownership / cascade / load unit), the request/capability edges
// (delegations, escalations), the API's per-run management record (runs + escalations audit), and
// the durable record of in-flight external calls for crash recovery.
//
// An instance is ephemeral: it self-deletes at its terminal (the project cascade is only a crash
// backstop), and terminal outcomes live on `runs`, not here. The parent→child edge is the `delegations`
// row, not a column on the instance — a child carries only its `delegation_id` (which correlates its
// `delegateAck`, e.g. when one parent runs several delegates in parallel), and the parent is recovered
// through `delegations.caller_instance_id`. `target` holds the agent reference `(qname, snapshot) |
// closure`; `snapshotId` is the version denormalised out of it for the FK / RESTRICT (a running version
// cannot be deleted).

import type { AnyPgColumn } from "drizzle-orm/pg-core";
import {
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uuid,
} from "drizzle-orm/pg-core";
import type { InstanceStatus } from "../../runtime/engine/types.js";
import type { DelegateTarget } from "../../runtime/event/types.js";
import type { Value } from "../../runtime/value/types.js";
import { projects, snapshots } from "./projects.js";

export const instances = pgTable(
  "instances",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The delegation that summoned this instance; `null` for the project root. It both correlates this
     *  instance's `delegateAck` and, via `delegations.caller_instance_id`, recovers the parent. Set null
     *  if its delegation row is dropped (which only happens after this instance has already self-deleted). */
    delegationId: uuid("delegation_id").references((): AnyPgColumn => delegations.id, {
      onDelete: "set null",
    }),
    /** What this instance runs: `(qname, snapshot)` or a closure reference. Snapshot is its property. */
    target: jsonb("target").$type<DelegateTarget>().notNull(),
    /** Version denormalised from `target`, for the FK / RESTRICT (running versions are undeletable). */
    snapshotId: uuid("snapshot_id")
      .notNull()
      .references(() => snapshots.id),
    /** running | cancelling — an instance is ephemeral, so it has no terminal state (that lives on `runs`). */
    status: text("status").$type<InstanceStatus>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [index("instances_project_id_idx").on(table.projectId)],
);

/** The parent→child edge and recovery outbox: the issuer's durable record of a child it summoned, and
 *  the correlation id its `delegateAck` carries. Cascades with the caller (it is meaningless without it). */
export const delegations = pgTable(
  "delegations",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The parent that issued this delegation — the recovered parent→child link. */
    callerInstanceId: uuid("caller_instance_id").references(() => instances.id, {
      onDelete: "cascade",
    }),
    target: jsonb("target").$type<DelegateTarget>().notNull(),
    argument: jsonb("argument").$type<Value | null>(),
    /** running | cancelling. */
    state: text("state").notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [index("delegations_caller_instance_id_idx").on(table.callerInstanceId)],
);

/** A capability request raised by an instance; owned by (and cascades with) the raiser. State is `open` only. */
export const escalations = pgTable("escalations", {
  id: uuid("id").primaryKey().defaultRandom(),
  projectId: uuid("project_id")
    .notNull()
    .references(() => projects.id, { onDelete: "cascade" }),
  raiserInstanceId: uuid("raiser_instance_id")
    .notNull()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** The requested capability (the `request` qualified name). */
  request: text("request").notNull(),
  argument: jsonb("argument").$type<Value | null>(),
  state: text("state").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

/** The API module's per-run management record (1:1 with a run's instance). Reflects the run's outcome. */
export const runs = pgTable("runs", {
  id: uuid("id").primaryKey().defaultRandom(),
  projectId: uuid("project_id")
    .notNull()
    .references(() => projects.id, { onDelete: "cascade" }),
  /** The run's CORE instance; nullable + set-null because that instance self-deletes at its terminal
   *  while this durable run record survives to hold the outcome. */
  instanceId: uuid("instance_id").references(() => instances.id, { onDelete: "set null" }),
  snapshotId: uuid("snapshot_id")
    .notNull()
    .references(() => snapshots.id),
  name: text("name").notNull(),
  qualifiedName: text("qualified_name").notNull(),
  argument: jsonb("argument").$type<Value | null>(),
  /** running | cancelling | done | error (reflects the run's CORE instance child). */
  state: text("state").notNull(),
  result: jsonb("result").$type<Value | null>(),
  errorMessage: text("error_message"),
  cancelReason: text("cancel_reason"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  completedAt: timestamp("completed_at", { withTimezone: true }),
});

/** History of a run's answered, user-facing escalations (live `escalations` are open-only, raiser-owned). */
export const runEscalationsAudit = pgTable(
  "run_escalations_audit",
  {
    runId: uuid("run_id")
      .notNull()
      .references(() => runs.id, { onDelete: "cascade" }),
    escalationId: uuid("escalation_id").notNull(),
    question: jsonb("question").$type<Value | null>(),
    answer: jsonb("answer").$type<Value | null>(),
    answeredAt: timestamp("answered_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.runId, table.escalationId] })],
);

/** In-flight external (FFI) call: a suspended `external` thread awaiting the sidecar, for crash recovery. */
export const externalCalls = pgTable("external_calls", {
  id: uuid("id").primaryKey().defaultRandom(),
  projectId: uuid("project_id")
    .notNull()
    .references(() => projects.id, { onDelete: "cascade" }),
  instanceId: uuid("instance_id")
    .notNull()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** The engine-local thread (within the instance) that is suspended on this call. */
  threadId: integer("thread_id").notNull(),
  /** The external dispatch key the handler interprets. */
  key: text("key").notNull(),
  argument: jsonb("argument").$type<Value | null>(),
  state: text("state").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});
