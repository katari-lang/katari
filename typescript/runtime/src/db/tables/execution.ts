// The execution layer: instances (the ownership / cascade / load unit), the request/capability edges
// (delegations, escalations), and the API's per-run management record (runs + escalations audit).
// In-flight external (FFI) calls live as `ExternalThread` rows in `threads`, not a separate table.
//
// An instance is ephemeral: it self-deletes at its terminal (the project cascade is only a crash
// backstop), and terminal outcomes live on `runs`, not here. The parent→child edge is the `delegations`
// row, not a column on the instance — a child carries only its `delegation_id` (which correlates its
// `delegateAck`, e.g. when one parent runs several delegates in parallel), and the parent is recovered
// through `delegations.caller_instance_id`. `target` holds the agent reference `(qname, snapshot) |
// closure`; `snapshotId` is the version denormalised out of it for the FK.
//
// Snapshot retention: a *running* version is pinned by `instances.snapshotId` (ON DELETE NO ACTION) —
// that, plus `projects.head_snapshot_id`, is what keeps a live snapshot undeletable. A finished run's
// `runs.snapshotId` is only audit, so it is ON DELETE SET NULL: it must NOT keep every version a run
// ever touched alive forever, or future snapshot GC could never reclaim anything.

import { sql } from "drizzle-orm";
import type { AnyPgColumn } from "drizzle-orm/pg-core";
import {
  check,
  index,
  jsonb,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uuid,
} from "drizzle-orm/pg-core";
import type { EngineState, InstanceKind, InstanceStatus } from "../../runtime/engine/types.js";
import type { DelegateTarget, ExternalEvent } from "../../runtime/event/types.js";
import type { GenericSubstitution, Value } from "../../runtime/value/types.js";
import { projects, snapshots } from "./projects.js";

// Persisted lifecycle states of the Layer 1 entities, enforced both at the type level (`$type`) and by
// the DB CHECK constraints below so recovery can trust the stored value. The terminal states are kept
// in place (the row is not deleted on completion) so a delegation / escalation row is its own durable
// history — `runs` and the escalations audit are projections of these, not separate sources of truth.
export type DelegationState = "running" | "cancelling" | "done" | "gone" | "failed";
export type EscalationState = "open" | "answered";
export type RunState = "running" | "cancelling" | "done" | "error" | "cancelled";

/** The non-terminal delegation states — the ones that still carry routing and still accept a transition.
 *  `done` / `gone` / `failed` are terminal and sticky. This is the single source of truth for "is this
 *  delegation still live": every persistence backend (the in-memory twin's read-modify-write and the DB's
 *  conditional `WHERE state IN (…)`) and the recovery load filter to exactly these. */
export const LIVE_DELEGATION_STATES = [
  "running",
  "cancelling",
] as const satisfies readonly DelegationState[];

/** Whether a delegation is still live (running / cancelling) — i.e. not yet `done` / `gone` / `failed`. */
export function isLiveDelegationState(state: DelegationState): boolean {
  return LIVE_DELEGATION_STATES.some((live) => live === state);
}

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
    /** Which structure this instance carries: `core` runs IR (target / snapshot / engine_state below);
     *  `api` is the project's management root (none of those — its runs / escalations are the normalised
     *  edge tables). */
    kind: text("kind").$type<InstanceKind>().notNull(),
    /** What a `core` instance runs: `(qname, snapshot)` or a closure reference. `null` for the `api` root. */
    target: jsonb("target").$type<DelegateTarget>(),
    /** Version denormalised from `target`, for the FK (NO ACTION; running versions are undeletable). `null`
     *  for the `api` root, which is not pinned to a version. */
    snapshotId: uuid("snapshot_id").references(() => snapshots.id),
    /** running | cancelling — an instance is ephemeral, so it has no terminal state (that lives on `runs`). */
    status: text("status").$type<InstanceStatus>().notNull(),
    /** The generic substitution this activation was summoned with (from the spawning `delegate.generics`).
     *  Inner scopes inherit it implicitly; not stored on `scopes`. */
    ambientGenerics: jsonb("ambient_generics").$type<GenericSubstitution>(),
    /** The engine bookkeeping with no dedicated column (routing maps, cancel exits, id counters); its
     *  threads ride in `threads`. The actor's routing maps are rebuilt from these on load. */
    engineState: jsonb("engine_state").$type<EngineState>(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("instances_project_id_idx").on(table.projectId),
    // `set null` on delegation delete must find the referencing instances without scanning the table.
    index("instances_delegation_id_idx").on(table.delegationId),
    check("instances_status_check", sql`${table.status} in ('running', 'cancelling')`),
    check("instances_kind_check", sql`${table.kind} in ('core', 'api')`),
  ],
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
    /** running → done (delegateAck'd, `result` set) | cancelling → gone (terminateAck'd) | failed (a panic
     *  / unhandled escape reached the run root, `error_message` set). Terminal rows are retained as history
     *  (the parent's record of what it summoned and how it ended), and terminal states are sticky. */
    state: text("state").$type<DelegationState>().notNull(),
    /** The `delegateAck` value once the child completed (state `done`); `null` otherwise. */
    result: jsonb("result").$type<Value | null>(),
    /** The failure message when the run failed (state `failed`); `null` otherwise. */
    errorMessage: text("error_message"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("delegations_caller_instance_id_idx").on(table.callerInstanceId),
    check(
      "delegations_state_check",
      sql`${table.state} in ('running', 'cancelling', 'done', 'gone', 'failed')`,
    ),
  ],
);

/** A capability request raised by an instance; owned by (and cascades with) the raiser. State is `open` only. */
export const escalations = pgTable(
  "escalations",
  {
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
    /** open → answered (`answer` set). Answered rows are retained as history; the escalations audit is a
     *  projection of these, not a separate record. */
    state: text("state").$type<EscalationState>().notNull(),
    /** The `escalateAck` value once answered (state `answered`); `null` while open. */
    answer: jsonb("answer").$type<Value | null>(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    // `GET /projects/:projectId/escalations` lists open escalations by project.
    index("escalations_project_id_idx").on(table.projectId),
    // Cascade on raiser delete must find these rows by owner without a table scan (parity with
    // `scopes`/`blobs`, which index `owner_instance_id` for the same reason).
    index("escalations_raiser_instance_id_idx").on(table.raiserInstanceId),
    check("escalations_state_check", sql`${table.state} in ('open', 'answered')`),
  ],
);

/** Layer 3 — the transactional outbox: external events produced by a turn but not yet consumed. The turn
 *  that *produces* events and the turn that *consumes* one commit in a single tx alongside their Layer 1/2
 *  writes (transactional outbox / consumer), so a crash neither loses an in-flight event nor double-delivers
 *  it. The actor drains this into its mailbox; on recovery the undrained rows are replayed. (FFI completions
 *  are NOT here — they are an ephemeral side channel re-derived from the `ExternalThread` rows on recovery.) */
export const outbox = pgTable(
  "outbox",
  {
    seq: uuid("seq").primaryKey().defaultRandom(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The instance that produced this event (the api root for an api operation). On replay it
     *  re-establishes a `delegate`'s caller, which the event payload does not itself carry. NOT a foreign
     *  key: the api root has no `instances` row, and an in-flight event must outlive its issuer's drop. */
    instanceId: uuid("instance_id").notNull(),
    /** The external event payload. */
    event: jsonb("event").$type<ExternalEvent>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    // Recovery and per-turn drain both read the project's pending events in insertion order.
    index("outbox_project_id_idx").on(table.projectId),
  ],
);

/** The API's per-run metadata sidecar. A run *is* the api root's delegation (`delegations` where
 *  `caller_instance_id = apiRootIdOf(projectId)`), and that Layer 1 row is the single source of truth for
 *  the run's outcome — state (running / cancelling / done→done / gone→cancelled / failed→error), result,
 *  and error. This table holds only what the delegation does not: the run's `id` (= the run delegation id),
 *  the human `name` label, the immediately-known launch metadata (so a run lists the instant it starts, even
 *  before its delegation row is created asynchronously), and the user's cancel reason. The API projects the
 *  two together (this row LEFT JOIN its delegation) — see `run.repository`. */
export const runs = pgTable(
  "runs",
  {
    /** The run delegation id — the join key to its Layer 1 outcome row. */
    id: uuid("id").primaryKey(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The version this run was launched against (denormalised launch metadata). Nullable + set-null so a
     *  snapshot GC after the run finishes does not pin it forever. */
    snapshotId: uuid("snapshot_id").references(() => snapshots.id, { onDelete: "set null" }),
    name: text("name").notNull(),
    qualifiedName: text("qualified_name").notNull(),
    argument: jsonb("argument").$type<Value | null>(),
    /** The reason a user gave when cancelling (the delegation records the `gone` state, not the reason). */
    cancelReason: text("cancel_reason"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    // `GET /projects/:projectId/runs` lists runs by project.
    index("runs_project_id_idx").on(table.projectId),
  ],
);

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
