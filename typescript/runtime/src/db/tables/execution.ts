// The execution layer: the instance envelope + its kind extensions (`core_instances` /
// `external_call_instances`), the request/capability edges (delegations, escalations), and the API's
// per-run management record (runs + escalations audit). The instance is class-table inheritance — a
// generic envelope (the ownership / cascade / load unit) plus a kind-specific extension keyed by it; an
// in-flight external call is an external-kind instance with an `external_call_instances` row, not a
// per-kind `*_calls` table.
//
// An instance is ephemeral: it self-deletes at its terminal (the project cascade is only a crash
// backstop), and terminal outcomes live on `runs`, not here. The parent→child edge is the `delegations`
// row, not a column on the instance — a child carries only its `delegation_id` (which correlates its
// `delegateAck`, e.g. when one parent runs several delegates in parallel), and the parent is recovered
// through `delegations.caller_instance_id`. A `core` instance's `target` holds the agent reference
// `(qname, snapshot) | closure`; its `snapshotId` is the version denormalised out of it for the FK.
//
// Snapshot retention: a *running* core activation pins its version by FK (`core_instances.snapshot_id`,
// ON DELETE NO ACTION) — that, plus `projects.head_snapshot_id`, is what keeps a live snapshot
// undeletable. An external call's snapshot id rides inside its extension document as plain data (a future
// snapshot GC must consult live external calls, not just FKs). A finished run's `runs.snapshotId` is only
// audit, so it is ON DELETE SET NULL: it must NOT keep every version a run ever touched alive forever, or
// future snapshot GC could never reclaim anything.

import type { Json } from "@katari-lang/types";
import { sql } from "drizzle-orm";
import type { AnyPgColumn } from "drizzle-orm/pg-core";
import {
  bigserial,
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
import type { DelegateTarget, ExternalEvent, ReactorName } from "../../runtime/event/types.js";
import type { GenericSubstitution, Value } from "../../runtime/value/types.js";
import { projects, snapshots } from "./projects.js";

// Persisted lifecycle states of the Layer 1 entities. A delegation / escalation row is pure live routing: the
// row exists ONLY while live — a delegation is `running` or `cancelling` (a terminal one is deleted, its
// outcome living on `runs`), an escalation is open (answering deletes it, the Q&A living in the audit). So
// there are no terminal / answered states here: presence ⟺ live, absence ⟺ done. A run, by contrast, keeps its
// terminal outcome on `runs` (below), so `RunState` still carries the terminal values.
export type DelegationState = "running" | "cancelling";
export type RunState = "running" | "cancelling" | "done" | "error" | "cancelled";

/** The lifecycle of an in-flight external call, one union for every call reactor: `running` (transport in
 *  flight / endpoint serving), `cancelling` (aborting, awaiting the transport's stop and the children's
 *  drain), or `awaitingAnswer` (the transport errored, the failure escalated, awaiting a caught answer or
 *  the run's terminate). Persisted on `external_call_instances.status` because the envelope collapses
 *  `awaitingAnswer` to the `running` instance lifecycle (alive, waiting). */
export type ExternalCallStatus = "running" | "cancelling" | "awaitingAnswer";

/** The terminal run states — a run that reached one of these is finished (its `completedAt` is set). */
export const TERMINAL_RUN_STATES = [
  "done",
  "error",
  "cancelled",
] as const satisfies readonly RunState[];

/** Whether a run state is terminal (done / error / cancelled). */
export function isTerminalRunState(state: RunState): boolean {
  return TERMINAL_RUN_STATES.some((terminal) => terminal === state);
}

// The instance *envelope*: the generic columns every kind shares (the ownership / cascade / load unit). The
// kind-specific state lives in an extension table keyed by this id (`core_instances` for an engine
// activation, `external_call_instances` for every call reactor's in-flight call) — class-table
// inheritance, so the envelope carries no nullable subtype columns. The `api` management root is a bare
// envelope row (no extension). Each reactor persists this through the base class uniformly (kind = its
// own reactor name).
export const instances = pgTable(
  "instances",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The delegation that summoned this instance; `null` for the `api` root. It both correlates this
     *  instance's `delegateAck` and, via `delegations.caller_instance_id`, recovers the parent. Set null
     *  if its delegation row is dropped (which only happens after this instance has already self-deleted).
     *  This reference and `delegations.caller_instance_id` form a cycle, and a batched commit can carry a
     *  whole causal chain (caller instance, its delegation, the callee instance), so both constraints are
     *  DEFERRABLE INITIALLY DEFERRED (migration 0003 — the DSL cannot express deferral). */
    delegationId: uuid("delegation_id").references((): AnyPgColumn => delegations.id, {
      onDelete: "set null",
    }),
    /** Which reactor owns this instance (= the reactor's own name): `core` runs IR, `ffi` runs an external
     *  handler, `api` is the management root. Its kind-specific state is the matching extension table. */
    kind: text("kind").$type<InstanceKind>().notNull(),
    /** The reactor that summoned this instance (its reply-to) — the instance's ambient, base-owned and uniform
     *  across kinds. `null` only for the `api` management root, which nothing delegates to. A callee's reply
     *  (`delegateAck` / `escalate`) routes back here; recovered from this column, never re-inferred. */
    callerReactor: text("caller_reactor").$type<ReactorName>(),
    /** The run (its permanent run instance's id) this instance runs under — the trace context stamped on
     *  every event it emits, recorded from the summoning `delegate`'s `run` like `caller_reactor` from its
     *  `from`. A run instance carries its own id; `null` only for the `api` management root. No FK: it is
     *  ambient routing metadata, exactly like `caller_reactor`. */
    runId: uuid("run_id"),
    /** running | cancelling — an instance is ephemeral, so it has no terminal state (that lives on `runs`). */
    status: text("status").$type<InstanceStatus>().notNull(),
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
    check(
      "instances_kind_check",
      sql`${table.kind} in ('core', 'api', 'ffi', 'http', 'webhook', 'mcp', 'time', 'oauth', 'region')`,
    ),
  ],
);

// The `core` instance extension: what a CORE activation runs (its IR target + version) and its engine
// bookkeeping. Cascades with its envelope; pins its snapshot (NO ACTION — a running version is undeletable).
export const coreInstances = pgTable("core_instances", {
  instanceId: uuid("instance_id")
    .primaryKey()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** What this instance runs: `(qname, snapshot)` or a closure reference. */
  target: jsonb("target").$type<DelegateTarget>().notNull(),
  /** Version denormalised from `target`, for the FK (NO ACTION; running versions are undeletable). */
  snapshotId: uuid("snapshot_id")
    .notNull()
    .references(() => snapshots.id),
  /** The generic substitution this activation was summoned with (from the spawning `delegate.generics`). */
  ambientGenerics: jsonb("ambient_generics").$type<GenericSubstitution>(),
  /** The engine bookkeeping with no dedicated column (the summoner reactor, cancel exits, id counters); its
   *  threads ride in `threads`. The actor's routing maps are rebuilt from these on load. */
  engineState: jsonb("engine_state").$type<EngineState>().notNull(),
});

// The external-call extension: ONE table for every call reactor's in-flight calls (ffi / http / webhook /
// mcp / time), because the persistence unit is the same shape for all of them — the envelope (above), the
// precise call `status`, and a kind-specific `extension` document holding whatever the reactor needs to
// reconstruct the call on reload. The reactor self-selects its rows by joining the envelope's `kind` (the
// SoT for which reactor owns a call), so no reactor column is repeated here; the extension's TypeScript
// shape lives in the owning reactor's pure codec (`encode…Extension` / `decode…Extension`), never in SQL.
// The whole document seals uniformly (private Value nodes anywhere in it become `$katari_sealed` — one rule,
// not a per-kind column enumeration). Cascades with its envelope.
export const externalCallInstances = pgTable("external_call_instances", {
  instanceId: uuid("instance_id")
    .primaryKey()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** The call's precise lifecycle — the envelope collapses `awaitingAnswer` to `running`, so it lives here. */
  status: text("status").$type<ExternalCallStatus>().notNull(),
  /** The kind-specific reconstruction material, written and read only through the owning reactor's codec.
   *  What rides here is exactly what must survive a restart: a webhook's token + callback, a time call's
   *  operation, an mcp call's serve/provide/parked sum, an ffi call's snapshot + key — and the
   *  inner-delegation bridges (relays / innerCalls) for the kinds that open inner delegations. What must
   *  NOT survive is exactly what is absent: no argument for the at-most-once kinds (recovery never
   *  re-runs external work, and an argument may carry secrets). */
  extension: jsonb("extension").$type<Json>().notNull(),
});

// The capability-token routing index: `token` → the (project, instance) serving it, for the public
// endpoints an external caller reaches with NOTHING but the token (`POST /inbound/<token>`,
// `POST /mcp/<token>`). The SoT for the token is the call's extension document (warm re-registration
// reads it from there on reload); this row is a projection maintained in the SAME commit as the call row
// by the minting reactor, existing only so a cold inbound POST can find its project before any actor is
// warm. Teardown is the FK cascade — the route dies with its instance, never by an explicit delete.
export const capabilityRoutes = pgTable(
  "capability_routes",
  {
    /** The unguessable URL token — the capability itself, globally unique across kinds. Plaintext, as the
     *  per-kind unique token indexes it replaces were: the token is a public-facing capability, not a
     *  secret value. */
    token: text("token").primaryKey(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    instanceId: uuid("instance_id")
      .notNull()
      .references(() => instances.id, { onDelete: "cascade" }),
  },
  (table) => [
    // Instances delete constantly (every call resolution); the cascade must find a dying instance's
    // routes without scanning (parity with `escalations_raiser_instance_id_idx`).
    index("capability_routes_instance_id_idx").on(table.instanceId),
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
    /** The parent that issued this delegation — the recovered parent→child link. Checked at commit
     *  time, not statement time (DEFERRABLE INITIALLY DEFERRED, migration 0003): see
     *  `instances.delegation_id` for the cycle this breaks under batched commits. */
    callerInstanceId: uuid("caller_instance_id").references(() => instances.id, {
      onDelete: "cascade",
    }),
    /** The reactors this delegation runs between: `from` = the caller's reactor (the owner — `core` for a
     *  sub-call, `api` for a run), `to` = the callee's. Each reactor reloads its own delegations by
     *  `from_reactor` on restart (no caller-identity classification). */
    fromReactor: text("from_reactor").$type<ReactorName>().notNull(),
    toReactor: text("to_reactor").$type<ReactorName>().notNull(),
    /** running | cancelling — pure live routing. The row exists only while live; a terminal delegation is
     *  deleted (its outcome lives on `runs`). The target / argument are NOT stored here (they ride on the
     *  undelivered `delegate` in the outbox), nor is the result (it flows on the `delegateAck` event). */
    state: text("state").$type<DelegationState>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (table) => [
    index("delegations_caller_instance_id_idx").on(table.callerInstanceId),
    check("delegations_state_check", sql`${table.state} in ('running', 'cancelling')`),
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
    /** The raiser's delegation — the leg the answering `escalateAck` descends. */
    delegationId: uuid("delegation_id").notNull(),
    /** The run (its run instance's id) this escalation belongs to — its attribution, from the escalate
     *  event's `run` stamp, so the api reactor rebuilds its answerable list (run + question) from the row
     *  alone and the API lists escalations by run without inferring it from routing. */
    runId: uuid("run_id").notNull(),
    /** The reactors this escalation runs between: `from` = the raiser's reactor (`core` for an
     *  instance-raised or relayed ask; a parking call reactor — `mcp` or `oauth` — for its parked call's
     *  `prelude.oauth.authorize`, and `mcp` also for a provide relaying its child's — each reactor
     *  reloads its own rows by this column), `to` = the reactor the escalate was addressed to (`api` ⟺
     *  the raiser is a run root, i.e. a user-facing escalation). The api root self-selects its
     *  answerable set by `to_reactor`. */
    fromReactor: text("from_reactor").$type<ReactorName>().notNull(),
    toReactor: text("to_reactor").$type<ReactorName>().notNull(),
    /** The requested capability (the `request` qualified name). */
    request: text("request").notNull(),
    argument: jsonb("argument").$type<Value | null>(),
    // No state / answer columns: an escalation row exists only while OPEN — answering it deletes the row (the
    // answered Q&A lives in `run_escalations_audit`). So presence ⟺ open.
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
  ],
);

/** Layer 3 — the transactional outbox: external events produced by a turn but not yet consumed. The turn
 *  that *produces* events and the turn that *consumes* one commit in a single tx alongside their Layer 1/2
 *  writes (transactional outbox / consumer), so a crash neither loses an in-flight event nor double-delivers
 *  it. The actor drains this into its mailbox; on recovery the undrained rows are replayed. (FFI completions
 *  are NOT here — they are an ephemeral transport side channel; the ffi reactor reconciles its in-flight
 *  calls from its own `external_call_instances` rows on recovery.) */
export const outbox = pgTable(
  "outbox",
  {
    seq: uuid("seq").primaryKey().defaultRandom(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The external event payload — self-routing (`from` / `to`), so no separate issuer is stored. */
    event: jsonb("event").$type<ExternalEvent>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    // Recovery and per-turn drain both read the project's pending events in insertion order.
    index("outbox_project_id_idx").on(table.projectId),
  ],
);

/** The run's metadata / outcome record — the `runs` extension of the run's permanent api-side *run
 *  instance* (class-table inheritance, exactly like `core_instances` extends a core envelope): `id` IS that
 *  instance's id and cascades with it, so a future run deletion is one instance drop that reclaims the
 *  run's record, its trace (`run_events`), and the resources the instance owns (result scopes / blobs)
 *  together. The api reactor writes this row on launch (atomically with the instance envelope and the run's
 *  `delegate`) and updates its outcome (`state` / `result` / `errorMessage` / `completedAt`) and cancel
 *  reason as it progresses — the run delegation row is pure live routing (deleted on terminal), so this is
 *  the run's durable source of truth. The API reads it directly — see `run.repository`. */
export const runs = pgTable(
  "runs",
  {
    /** The run instance's id (the run's identity — permanent, unlike the launch delegation). */
    id: uuid("id")
      .primaryKey()
      .references(() => instances.id, { onDelete: "cascade" }),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The version this run was launched against (denormalised launch metadata). Nullable + set-null so a
     *  snapshot GC after the run finishes does not pin it forever. */
    snapshotId: uuid("snapshot_id").references(() => snapshots.id, { onDelete: "set null" }),
    name: text("name").notNull(),
    qualifiedName: text("qualified_name").notNull(),
    argument: jsonb("argument").$type<Value | null>(),
    /** running → cancelling → done / cancelled / error. The api root advances it (start / cancel / terminal). */
    state: text("state").$type<RunState>().notNull().default("running"),
    /** The run's result value once `done`; `null` otherwise. */
    result: jsonb("result").$type<Value | null>(),
    /** The failure message once `error`; `null` otherwise. */
    errorMessage: text("error_message"),
    /** The reason a user gave when cancelling. */
    cancelReason: text("cancel_reason"),
    /** When the run reached a terminal state; `null` while still live. */
    completedAt: timestamp("completed_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    // `GET /projects/:projectId/runs` lists runs by project.
    index("runs_project_id_idx").on(table.projectId),
    check(
      "runs_state_check",
      sql`${table.state} in ('running', 'cancelling', 'done', 'error', 'cancelled')`,
    ),
  ],
);

/** The run's execution trace: every external event ever produced under a run, in production order — the
 *  permanent, append-only twin of the `outbox` (which is transient delivery: a row is deleted once
 *  consumed). Appended by the substrate in the same commit as `produceOutbox`, so an event is journaled
 *  exactly iff it was durably sent (a failed commit rolls both back), exactly once. `run_id` is the event's
 *  own `run` stamp denormalised for the query; the `event` JSON is the source of truth (sealed like the
 *  outbox — private values are encrypted at rest). Rows live as long as their run (the FK cascade is the
 *  retention policy: deleting a run deletes its trace). */
export const runEvents = pgTable(
  "run_events",
  {
    /** Append order. Per project the substrate is serial (one commit at a time), so within one run the
     *  sequence is the causal production order. */
    seq: bigserial("seq", { mode: "number" }).primaryKey(),
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    runId: uuid("run_id")
      .notNull()
      .references(() => runs.id, { onDelete: "cascade" }),
    event: jsonb("event").$type<ExternalEvent>().notNull(),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [
    // `GET /projects/:projectId/runs/:runId/events` tails a run's trace by (run, seq > after).
    index("run_events_run_id_seq_idx").on(table.runId, table.seq),
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
