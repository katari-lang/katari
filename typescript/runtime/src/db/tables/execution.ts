// The execution layer: the instance envelope + its per-kind extensions (`core_instances` / `ffi_instances`),
// the request/capability edges (delegations, escalations), and the API's per-run management record (runs +
// escalations audit). The instance is class-table inheritance — a generic envelope (the ownership / cascade /
// load unit) plus a kind-specific extension keyed by it; an in-flight external (FFI) call is an `ffi`-kind
// instance (`ffi_instances`), not a separate `ffi_calls` table.
//
// An instance is ephemeral: it self-deletes at its terminal (the project cascade is only a crash
// backstop), and terminal outcomes live on `runs`, not here. The parent→child edge is the `delegations`
// row, not a column on the instance — a child carries only its `delegation_id` (which correlates its
// `delegateAck`, e.g. when one parent runs several delegates in parallel), and the parent is recovered
// through `delegations.caller_instance_id`. A `core` instance's `target` holds the agent reference
// `(qname, snapshot) | closure`; its `snapshotId` is the version denormalised out of it for the FK.
//
// Snapshot retention: a *running* version is pinned by an extension's `snapshotId` (`core_instances` /
// `ffi_instances`, ON DELETE NO ACTION) — that, plus `projects.head_snapshot_id`, is what keeps a live
// snapshot undeletable. A finished run's `runs.snapshotId` is only audit, so it is ON DELETE SET NULL: it
// must NOT keep every version a run ever touched alive forever, or future snapshot GC could never reclaim
// anything.

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
  uniqueIndex,
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
// kind-specific state lives in a per-kind extension table (`core_instances`, `ffi_instances`) keyed by this
// id — class-table inheritance, so the envelope carries no nullable subtype columns and a new reactor kind is
// a new extension table, not an `instances` ALTER. The `api` management root is a bare envelope row (no
// extension). Each reactor persists this through the base class uniformly (kind = its own reactor name).
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
      sql`${table.kind} in ('core', 'api', 'ffi', 'http', 'webhook', 'mcp')`,
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

// The `ffi` instance extension: an in-flight external call (what was `ffi_calls`). Cascades with its
// envelope; pins its snapshot (the compiled sidecar bundle hosting the handler). The delegation it handles
// is its envelope's `delegation_id`. Like `http_instances` it stores no argument: recovery is at-most-once
// (a handler is never re-run — a call whose process died fails as a panic), so nothing reads it back.
export const ffiInstances = pgTable("ffi_instances", {
  instanceId: uuid("instance_id")
    .primaryKey()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** The snapshot whose compiled sidecar bundle hosts this handler — pins the version (no cascade). */
  snapshotId: uuid("snapshot_id")
    .notNull()
    .references(() => snapshots.id),
  /** The handler dispatch key (the external block's `key`). */
  key: text("key").notNull(),
  /** running (transport in flight) | cancelling (aborting) | awaitingAnswer (errored, the panic escalated,
   *  awaiting a caught-panic answer or the run's terminate). The caller reactor its reply routes to is on the
   *  generic envelope (`instances.caller_reactor`), not repeated here. */
  status: text("status").$type<"running" | "cancelling" | "awaitingAnswer">().notNull(),
  /** The escalations this call is proxying upward for its inner delegations (outer id → the child leg the
   *  answer descends to) — so an in-flight answer still routes down after a restart. */
  relays: jsonb("relays")
    .$type<Array<{ escalation: string; child: string; childEscalation: string }>>()
    .notNull()
    .default([]),
  /** The call's open inner delegations and the sidecar `call` token each settles under — so a result landing
   *  after a warm reset still reaches its consumer in the (still-running) sidecar process. */
  innerCalls: jsonb("inner_calls")
    .$type<Array<{ delegation: string; call: string }>>()
    .notNull()
    .default([]),
});

// The `http` instance extension: an in-flight http call. Cascades with its envelope. Unlike `ffi`, it pins no
// snapshot and stores no request (recovery never re-sends an http request — see `HttpReactor`), so it carries
// only the call-specific `status` the envelope cannot (the envelope collapses `awaitingAnswer` to `running`).
// Its caller reactor (reply-to) and the delegation it handles are both on the generic envelope.
export const httpInstances = pgTable("http_instances", {
  instanceId: uuid("instance_id")
    .primaryKey()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** running (request in flight) | cancelling (aborting) | awaitingAnswer (errored, the panic escalated,
   *  awaiting a caught-panic answer or the run's terminate). On recovery a running call is reconciled with
   *  the transport (at-most-once: a surviving request is left alone, a gone one fails), a cancelling call
   *  is aborted, an awaitingAnswer one waits. */
  status: text("status").$type<"running" | "cancelling" | "awaitingAnswer">().notNull(),
});

// The `mcp` instance extension: an in-flight mcp call. Like `http` it pins no snapshot and stores no
// request for the TRANSPORT-backed shapes (a minted tool's call, a direct `prelude.mcp.call`; a
// `prelude.mcp.provide` listing rides an internal side delegation, never a call of its own) — recovery
// never re-sends (gone work fails as a typed `mcp.server_error`, and a katari-level retry reconnects
// through the transport's descriptor cache) — so it carries only the call-specific `status` the envelope
// cannot (the envelope collapses `awaitingAnswer` to `running`). A `serve` / `provide` endpoint's durable
// state is NOT here: it lives in the `mcp_serve_instances` / `mcp_provide_instances` SUBTYPE tables, so an
// mcp call is a transport|serve|provide union discriminated by those tables' presence, NOT by nullable
// columns on this one (class-table inheritance — the "no nullable subtype columns" doctrine this schema
// preaches).
export const mcpInstances = pgTable("mcp_instances", {
  instanceId: uuid("instance_id")
    .primaryKey()
    .references(() => instances.id, { onDelete: "cascade" }),
  /** running (request in flight / endpoint serving) | cancelling (aborting) | awaitingAnswer (errored,
   *  the throw escalated, awaiting a caught answer or the run's terminate). */
  status: text("status").$type<"running" | "cancelling" | "awaitingAnswer">().notNull(),
});

// The `mcp` SERVE extension: a `prelude.mcp.serve` endpoint's durable state — the subtype half of an mcp
// call, keyed by (and cascading with) its `mcp_instances` row, so serve state is a table, not a nullable
// column set. Pins its snapshot (the version the served agents dispatch against), like `webhook_instances`.
// Persists its payload, unlike the transport shapes: the `serve_token` must survive a restart (the URL is
// the capability an MCP caller holds) and the served `serve_tools` record must too (future tool calls
// dispatch its agents) — the subscriber does not (dispatched exactly once; its inner delegation is durable
// core work). Its inner-delegation bridges (`relays` / `inner_calls`) live here because only a serve call
// opens inner delegations.
export const mcpServeInstances = pgTable(
  "mcp_serve_instances",
  {
    instanceId: uuid("instance_id")
      .primaryKey()
      .references(() => mcpInstances.instanceId, { onDelete: "cascade" }),
    /** The snapshot the served tools / subscriber dispatch against — pins the version (no cascade), like
     *  `webhook_instances.snapshot_id`. */
    snapshotId: uuid("snapshot_id")
      .notNull()
      .references(() => snapshots.id),
    /** The unguessable URL token (`POST /mcp/<token>`) — the endpoint's capability. Globally unique, so the
     *  public route resolves a token to its project without any other key. */
    serveToken: text("serve_token").notNull(),
    /** The served tools record each MCP `tools/call` dispatches (key = tool name, value = an agent /
     *  closure / tool reference). Sealed like every stored value. */
    serveTools: jsonb("serve_tools").$type<Value>().notNull(),
    /** The escalations this call is proxying upward for its inner delegations (see `ffi_instances.relays`). */
    relays: jsonb("relays")
      .$type<Array<{ escalation: string; child: string; childEscalation: string }>>()
      .notNull()
      .default([]),
    /** The call's open inner delegations (the subscriber, in-flight served tool calls) and the local
     *  token each settles under — so a call landing after a warm reset still finds its consumer. */
    innerCalls: jsonb("inner_calls")
      .$type<Array<{ delegation: string; call: string }>>()
      .notNull()
      .default([]),
  },
  (table) => [uniqueIndex("mcp_serve_instances_serve_token_idx").on(table.serveToken)],
);

// The `mcp` PROVIDE extension: a `prelude.mcp.provide` scope's durable state — the sibling subtype of
// `mcp_serve_instances` (an mcp call is a transport|serve|provide union, discriminated by WHICH subtype
// table holds a row, never by nullable columns on `mcp_instances`). A `provide` lists a server, hands its
// continuation a `toolbox[URL]`, and lives for the extent of that continuation, gating tool calls by a
// runtime `scope_id`. Persists its payload, like serve: the `scope_id` must survive a restart (minted tool
// values carry it, so a stored tool re-resolves to the re-registered scope) and the `descriptor` too (the
// url + auth the scope connects and evicts under). The `continuation` is stored ONLY while the provide is
// still listing (not yet dispatched into the block) — null once active, so a restart mid-listing re-lists
// and a restart mid-block resumes the durable continuation delegation. Its inner-delegation bridges
// (`relays` / `inner_calls`) live here because only a serve/provide call opens inner delegations.
export const mcpProvideInstances = pgTable(
  "mcp_provide_instances",
  {
    instanceId: uuid("instance_id")
      .primaryKey()
      .references(() => mcpInstances.instanceId, { onDelete: "cascade" }),
    /** The snapshot the minted tools / continuation dispatch against — pins the version (no cascade), like
     *  `mcp_serve_instances.snapshot_id`. */
    snapshotId: uuid("snapshot_id")
      .notNull()
      .references(() => snapshots.id),
    /** The runtime scope identity minted at provide open — the token minted tool values carry in their
     *  context, checked live at each tool call. Globally unique, so a restart re-registers exactly it. */
    scopeId: text("scope_id").notNull(),
    /** The server descriptor (`{ url, auth }`) the scope connects under: the transport cache key to evict on
     *  scope close, and the descriptor `directCall` matches a live scope against. Sealed (auth may be secret). */
    descriptor: jsonb("descriptor").$type<Value>().notNull(),
    /** The continuation dispatched once the listing lands, stored ONLY until then (null once active — the
     *  dispatched continuation is durable core work). A reload with a non-null continuation is a
     *  listing-phase interruption: re-list; a null one is an active scope: re-register and resume. Sealed. */
    continuation: jsonb("continuation").$type<Value | null>(),
    /** The escalations this call is proxying upward for its inner delegations (see `ffi_instances.relays`). */
    relays: jsonb("relays")
      .$type<Array<{ escalation: string; child: string; childEscalation: string }>>()
      .notNull()
      .default([]),
    /** The call's open inner delegations (the continuation, resolved through the bridge on reload) and the
     *  local token each settles under. */
    innerCalls: jsonb("inner_calls")
      .$type<Array<{ delegation: string; call: string }>>()
      .notNull()
      .default([]),
  },
  (table) => [uniqueIndex("mcp_provide_instances_scope_id_idx").on(table.scopeId)],
);

// The `webhook` instance extension: an in-flight `webhook.inbound` call — a dynamically generated public
// endpoint serving for the extent of its subscriber. Cascades with its envelope; pins its snapshot (the
// version the callback / subscriber dispatch against). Unlike `ffi` / `http` it persists its payload: the
// `token` must survive a restart (the URL is the capability an external caller holds) and the `callback`
// must too (future deliveries dispatch it) — the subscriber does not (dispatched exactly once; its inner
// delegation is durable core work that resumes on its own).
export const webhookInstances = pgTable(
  "webhook_instances",
  {
    instanceId: uuid("instance_id")
      .primaryKey()
      .references(() => instances.id, { onDelete: "cascade" }),
    /** The snapshot the call was dispatched against — the callback / subscriber delegations pin it. */
    snapshotId: uuid("snapshot_id")
      .notNull()
      .references(() => snapshots.id),
    /** The unguessable URL token (`POST /inbound/<token>`) — the endpoint's capability. Globally unique, so
     *  the public route resolves a token to its project without any other key. */
    token: text("token").notNull(),
    /** The callback value each delivery dispatches (an agent / closure / tool reference). Sealed like every
     *  stored value; a closure's captured scope is durable core state, so the reference stays resolvable. */
    callback: jsonb("callback").$type<Value>().notNull(),
    /** running (serving) | cancelling (tearing down) | awaitingAnswer (the subscriber failed, its panic /
     *  throw escalated, awaiting an answer or the run's terminate). */
    status: text("status").$type<"running" | "cancelling" | "awaitingAnswer">().notNull(),
    /** The escalations this call is proxying upward for its inner delegations (see `ffi_instances.relays`). */
    relays: jsonb("relays")
      .$type<Array<{ escalation: string; child: string; childEscalation: string }>>()
      .notNull()
      .default([]),
    /** The call's open inner delegations (the subscriber, in-flight deliveries) and the local token each
     *  settles under — so a delivery landing after a warm reset still finds its consumer. */
    innerCalls: jsonb("inner_calls")
      .$type<Array<{ delegation: string; call: string }>>()
      .notNull()
      .default([]),
  },
  (table) => [uniqueIndex("webhook_instances_token_idx").on(table.token)],
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
    /** The reactors this escalation runs between: `from` = the raiser's reactor (always `core` today — only
     *  core instances raise), `to` = the reactor the escalate was addressed to (`api` ⟺ the raiser is a run
     *  root, i.e. a user-facing escalation). The api root self-selects its answerable set by `to_reactor`. */
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
 *  calls from its own `ffi_instances` rows on recovery.) */
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
