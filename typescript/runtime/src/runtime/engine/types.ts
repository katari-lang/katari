// The in-memory engine model: Instance (a shard = one agent activation's thread tree), Thread (a
// running block), and Scope (a lexical-binding node). See docs/2026-06-15-runtime-domain-model.md.
//
// Persistence mirror: an `Instance`'s threads persist row-per-thread (`threads`, with the
// variant-specific state in `payload`); scopes are CORE-global per project and persist row-per-scope
// (`scopes`), each scope's variables riding inline in its `scopes.values` JSON column (see the
// `engine.ts` header for why they are not their own table). The per-thread execution state below is
// the engine's working set; its exact fields will firm up in the engine phase.

import type { BlockId, QualifiedName } from "@katari-lang/types";
import type { DelegateTarget, ReactorName } from "../event/types.js";
import type {
  AskId,
  BlobId,
  CallId,
  DelegationId,
  EscalationId,
  InstanceId,
  ScopeId,
  ThreadId,
} from "../ids.js";
import type { GenericSubstitution, SemanticKind, Value } from "../value/types.js";

// ─── Scope ──────────────────────────────────────────────────────────────────────────────────────

/**
 * A lexical-binding tree node. CORE-global (one store per project, shared across instances) and
 * owned by an instance for cascade / ascent / intra-instance GC. `owner` is the instance that
 * created it; it rises to an ancestor when an escaping value carries it up, or to `null` while
 * in-transit mid-ascent (mirrors a blob's owner). Variables ride inline both in memory and at rest
 * (the `scopes.values` JSON column).
 */
export type Scope = {
  id: ScopeId;
  parentId: ScopeId | null;
  owner: InstanceId | null;
  /** VariableId -> Value. */
  values: Record<number, Value>;
};

// ─── Thread ──────────────────────────────────────────────────────────────────────────────────────

export type ThreadStatus = "running" | "cancelling";

/** Fields every thread carries regardless of which block it runs. */
export type ThreadBase = {
  id: ThreadId;
  /** Parent thread within this instance (`null` for the instance root). */
  parent: ThreadId | null;
  /** The parent's call slot that spawned this thread (`null` for the instance root). */
  parentCallId: CallId | null;
  /** The scope this thread evaluates in. */
  scopeId: ScopeId;
  /** The block this thread runs. */
  blockId: BlockId;
  status: ThreadStatus;
  /**
   * For each ask this thread bubbled up under its own local `askId`, the child `(thread, askId)` to send
   * the answer back to — one hop down. When a thread receives an ask it does not consume, it re-raises a
   * fresh ask to its parent and records this; the answer then reverses the bubble path one step at a time,
   * with no instance-global continuation table. Because the routes live on the thread, a cancelled thread
   * drops its pending routes for free — every outstanding ask either gets answered (its route fires) or is
   * cancelled (its route dies with the thread), so no ask kind needs special "is it answered?" bookkeeping.
   * (Forwarding *out* across an instance boundary is not here: that is the `DelegateThread`'s job — see
   * its `relays` — and the `AgentThread`'s escape bridge — see its `escalations`.)
   */
  forwardRoutes: Record<number, { thread: ThreadId; askId: AskId }>;
};

/** Tracks one outstanding child a thread spawned and is awaiting (callAck) and where to bind its value. */
export type PendingCall = { callId: CallId; output: number | null };

/**
 * The uniform invocation model (the user chose this over collapsing leaves): EVERY `OperationDelegate`
 * — to a user agent, a closure, a primitive, a data constructor, a request, OR an external (FFI) agent
 * — summons a child instance. The child instance's root thread is always an `AgentThread` (the wrapping
 * `BlockAgent` that lowering puts over every callable); it applies `defaults`, spawns the body block as
 * its single child, and on the body's completion (or a `return` ask) emits the `delegateAck`. The body
 * thread's kind mirrors the body block:
 *
 *   sequence (user code) | primitive | construct | request | external (FFI)
 *
 * Only `OperationCall` (the structural nodes match / for / handle / parallel) spawns an in-instance
 * thread. `DelegateThread` is the sole non-block thread: the sender-side proxy a caller keeps for each
 * outbound delegate (it owns the cross-instance delegate/escalate plumbing for that one child).
 */
export type Thread =
  | AgentThread
  | SequenceThread
  | PrimitiveThread
  | ConstructThread
  | RequestThread
  | MatchThread
  | ForThread
  | HandleThread
  | ParallelThread
  | DelegateThread
  | ExternalThread;

/**
 * The instance root: one `BlockAgent` activation. On entry it applies the agent's `defaults` to the
 * incoming argument, seeds the body block's `parameter`, and spawns the body as its single child. It is
 * the instance's control boundary in two ways:
 *   - it catches the `return` ask (which lexically targets this agent block) and completes the instance
 *     with that value;
 *   - it is the escalation boundary — any other ask that bubbles up to it (a `request`, or a control
 *     ask targeting a lexical ancestor in a *parent* instance) escapes as an outbound `escalate`.
 * On the body's completion (callAck) or a caught `return`, it emits the instance's `delegateAck`.
 */
export type AgentThread = ThreadBase & {
  kind: "agent";
  /** The body call in flight (the agent body always runs as exactly one child). */
  pending: PendingCall | null;
  /**
   * The escalation boundary's external↔internal bridge: for each `escalate` this root emitted, the local
   * `askId` it escaped under. It exists only so the cross-instance events stay in pure external vocabulary
   * (an `escalation` id, no inner thread / askId): when an `escalateAck` returns, this Agent thread maps
   * its `escalation` back to that `askId` and re-enters it as an ordinary internal `askAck` to itself —
   * whence its own `forwardRoutes` carry the answer on down, like any bubbled answer. No thread id here.
   */
  escalations: Record<EscalationId, AskId>;
};

/** Runs a `sequence` block's operations one at a time, awaiting any spawning op before advancing. */
export type SequenceThread = ThreadBase & {
  kind: "sequence";
  /** Index of the next operation to run. */
  cursor: number;
  /** The child currently awaited (a `call` into a structural node), or `null` if none in flight. */
  pending: PendingCall | null;
};

// The leaf bodies (primitive / construct / request) carry no extra state: their name / input variable
// live on the block (resolved from `blockId`), and they hold at most one outstanding interaction, so the
// answering event identifies it without a stored handle. The external (FFI) leaf is the exception — it
// tracks its dispatch lifecycle (below).

/**
 * A primitive leaf body: runs the prim named on its block against its `input` variable and acks the
 * value. The run may be async (a bounded env / blob fetch), awaited inline within the turn; the prim has
 * no children, so it completes within its instance's turn.
 */
export type PrimitiveThread = ThreadBase & { kind: "primitive" };

/** A data-constructor leaf body: builds the tagged value of its constructor from `input` and acks it. */
export type ConstructThread = ThreadBase & { kind: "construct" };

/**
 * A request leaf body: raises its request as an ask carrying `input`. Its instance has no handler of its
 * own, so the ask immediately escapes (via the root `AgentThread`) as an outbound `escalate`; the thread
 * suspends until the matching `escalateAck` (relayed back as its `askAck`) resumes it, then acks the value.
 */
export type RequestThread = ThreadBase & { kind: "request" };

/** Runs the arm body chosen by matching `subject`; forwards the arm's value as its own result. */
export type MatchThread = ThreadBase & {
  kind: "match";
  pending: PendingCall | null;
};

/** Drives a `for` loop, collecting each iteration's `next` value into `collected` in source order. A
 *  `for` is, structurally, the handler of a per-element `go` effect: an iteration body's `next` (or its
 *  fall-through tail) is the resume value for that element, and a `break-for` aborts the whole map. So it
 *  uses the same cancel-then-act machinery as `handle` — `next-for` cancels just that iteration's subtree
 *  and `break-for` cancels them all (mirroring a handler's `next` / `break`). */
export type ForThread = ThreadBase & {
  kind: "for";
  parallel: boolean;
  /** Sequential: the current iteration index. */
  cursor: number;
  /** Mapped next-values by iteration index (sparse until all land, in the parallel case); the dense
   *  source-ordered array is materialised at completion. Mirrors `ParallelThread.collected`. */
  collected: Record<number, Value>;
  /** Current state values, keyed by each state's body variable id (so a `with (s = …)` modifier — which
   *  names that variable — updates it directly). Re-seeded into the body's `state_N` each iteration. */
  states: Record<number, Value>;
  /** Iteration index -> the child call running it (one for sequential, many concurrent for parallel). */
  pending: Record<number, CallId>;
  /** An iteration body's call -> the `next` value/modifiers to collect once its targeted `next`-cancel
   *  completes (the for analogue of a handle's `postCancelActions`). */
  postCancelCollect: Record<number, { value: Value; modifiers: Record<number, Value> }>;
  /** Once the source is exhausted, the then-clause's call (if any): its value is the loop's value. */
  thenPending: CallId | null;
};

/**
 * Runs a `handle` body, dispatching the requests it owns to handlers and resuming the asker via `next`
 * (or exiting the whole handle via `break`). A handler that falls through to its tail implicitly `next`s
 * with that tail value (resuming the asker) — like a `for` body's implicit next; only an explicit `break`
 * exits the handle. Sequential mode runs one handler / then-clause at a time (others queue in
 * `pendingRequests`); parallel mode runs them concurrently. States are seeded into each child's `state_N`
 * and updated by a `next … with (…)`.
 */
export type HandleThread = ThreadBase & {
  kind: "handle";
  parallel: boolean;
  /** Current state values, keyed by each state's body variable id (re-seeded into `state_N` per child,
   *  updated by a `with` modifier). */
  states: Record<number, Value>;
  /** The protected body's call (the handled block / the `k()` continuation). */
  bodyCall: CallId | null;
  /** Handler invocations in flight, keyed by their call -> the request ask each answers on `next`. One at
   *  a time in sequential mode, possibly many in parallel mode. */
  handlers: Record<number, { answerThread: ThreadId; answerAskId: AskId }>;
  /** Requests that arrived while busy (sequential mode FIFO). */
  pendingRequests: Array<{
    from: ThreadId;
    askId: AskId;
    request: QualifiedName;
    argument: Value | null;
  }>;
  /** A handler body's call -> the request answer to fire once its targeted `next`-cancel completes. */
  postCancelActions: Record<number, { answerThread: ThreadId; answerAskId: AskId; value: Value }>;
  /** The then-clause's call (run after the body completes); its value is the handle's value. */
  thenPending: CallId | null;
};

/** Runs `par [...]` elements concurrently, collecting results by element index. */
export type ParallelThread = ThreadBase & {
  kind: "parallel";
  /** Element index -> its child call. */
  pending: Record<number, CallId>;
  /** Element index -> its result value (filled as children complete). */
  collected: Record<number, Value>;
};

/**
 * Sender-side waiter for an `OperationDelegate`: it emitted an outbound `delegate` and awaits the
 * `delegateAck`. Always a cross-instance call now (named or closure alike); it has no in-instance
 * child. An inbound `escalate` from the callee is turned into an upward `ask` by the engine.
 */
export type DelegateThread = ThreadBase & {
  kind: "delegate";
  /** The cross-instance child this proxies; both the `delegateAck` correlation and (with the
   *  `delegations` row) the recovery handle. The result binds via the spawning thread's pending slot,
   *  so no separate output is kept here; `target` / `argument` live in the `delegations` row. */
  delegationId: DelegationId;
  /** Inbound escalations this proxy is relaying inward, keyed by the local `askId` it re-raised each
   *  under. When that ask is answered, the proxy sends the value back out as the `escalateAck` of
   *  `(delegationId, escalation)`. A delegate proxy has no in-instance children, so its pending answers
   *  live here — the outbound counterpart of every other thread's downward `forwardRoutes`. */
  relays: Record<number, EscalationId>;
};

/**
 * The thread running an `ExternalBlock` body. It behaves exactly like a `DelegateThread`, but its callee is
 * the `ffi` reactor instead of another core instance: on `create` it emits a `delegate` to ffi (target
 * `{ external, key }`) and suspends as the caller-side proxy, resuming on the `delegateAck` (its result), an
 * `escalate` (an FFI error → a panic it relays inward), or a `terminateAck` (its abort confirmed). The engine
 * drives it through the same proxy machinery as `DelegateThread`: `delegationId` is the ffi delegation it
 * proxies, `relays` carries an inbound escalation it is relaying inward.
 */
export type ExternalThread = ThreadBase & {
  kind: "external";
  delegationId: DelegationId;
  relays: Record<number, EscalationId>;
  /** The reactor this proxy's callee runs in — `ffi` (a sidecar handler) or `http` (the built-in fetch).
   *  Copied from the external block's `reactor` marker at spawn, so the proxy's downward legs (its
   *  `delegate` / `terminate`) route to the right reactor without re-reading the block. */
  reactor: "ffi" | "http" | "webhook" | "mcp";
};

// ─── Cancel exits ─────────────────────────────────────────────────────────────────────────────

/**
 * What a thread does once its cancel cascade clears (its whole subtree — across instance boundaries via
 * terminate — has confirmed teardown). This is the graceful-barrier post-action: an unwinding `return` /
 * `break` performs its exit only after the cancelled subtree is gone, never before. A plain cascade
 * member just acks its parent.
 */
export type CancelExit =
  /** A cascade member: emit `cancelAck` to its parent (then retire). */
  | { kind: "ackParent" }
  /** An agent's `return`: emit the instance's `delegateAck` with `value` and retire the instance. */
  | { kind: "returnInstance"; value: Value }
  /** An agent being terminated: emit `terminateAck` and retire the instance (no delegateAck). */
  | { kind: "terminateInstance" }
  /** A `handle`'s `break` or a `for`'s `break-for`: cancel the subtree, then complete the thread (ack its
   *  parent) with the break `value` — bypassing any then-clause. */
  | { kind: "completeWith"; value: Value };

// ─── Instance (= shard) ─────────────────────────────────────────────────────────────────────────

export type InstanceStatus = "running" | "cancelling";

/** Which structure a Layer 1 instance *entity* carries: `core` runs IR; `api` is the project's permanent
 *  management root. This is a durable, persistence-level distinction (the `instances.kind` column). The
 *  *engine* only ever holds `core` instances in its warm store — the api root runs no IR, so it is a Layer 1
 *  entity + a sentinel id (`apiRootIdOf(project)`), never an in-memory engine instance. Api-targeted events
 *  route to the `ApiReactor` by the substrate's `event.to`, not by any caller-id comparison here; that is
 *  why there is no `ApiInstance` in the engine model below. */
export type InstanceKind = "core" | "api" | "ffi" | "http" | "webhook" | "mcp";

/**
 * The `core` activation: a thread tree plus the bookkeeping to route inbound external events to the right
 * waiting thread. The unit of ownership and of load/persist (a shard). Scopes live in the per-project
 * store (`ProjectStore.scopes`); this instance owns a subset via `Scope.owner`. Its parent is recovered
 * through `delegationId` (→ the issuing instance). `ambientGenerics` is this activation's generic
 * substitution (carried in on the spawning `delegate`); inner scopes look it up here.
 */
export type CoreInstance = {
  kind: "core";
  id: InstanceId;
  /** The delegation that summoned this instance; the parent is recovered from it. Also the correlation id
   *  of this instance's `delegateAck`. (`null` only defensively — a real core instance is always summoned.) */
  delegationId: DelegationId | null;
  /** The reactor that summoned this instance (the summoning `delegate`'s `from`): `core` for a sub-call,
   *  `api` for a run root. This is the callee-side record of the handled delegation's *summoner*: the engine
   *  never reads it; the reactor base class seeds its handled-delegation routing from it (on accept and on
   *  load) so the replies this instance emits route back to the summoner. Persisted on the generic instance
   *  *envelope* (`instances.caller_reactor`, base-owned) — the callee's ambient, uniform across reactor kinds
   *  — and seeded back onto this in-memory field on load. */
  callerReactor: ReactorName;
  /** The run (its permanent api-side run instance's id) this activation runs under — the trace context,
   *  recorded from the summoning `delegate`'s `run` exactly like `callerReactor` from its `from`. Every
   *  external event this instance emits is stamped with it (the emit edge in `StepContext.emit`), so the
   *  event journal attributes each event to its run without a tree walk. Persisted on the generic envelope
   *  (`instances.run_id`). */
  runId: InstanceId;
  /** What this instance runs — `(name, snapshot)` or a closure; the snapshot lives here. */
  target: DelegateTarget;
  /** The argument this activation was summoned with (the spawning `delegate.argument`). */
  argument: Value | null;
  status: InstanceStatus;
  /** The ambient generic substitution for this activation (from the spawning `delegate.generics`). */
  ambientGenerics?: GenericSubstitution;
  rootThreadId: ThreadId;
  /** ThreadId -> Thread (instance-local). */
  threads: Record<number, Thread>;
  // No outbound-delegation map: the `DelegateThread` proxying an outbound delegate already carries its
  // `delegationId`, so an outbound delegation's proxy (and its caller, on reactivation) is found by that
  // back-reference — never duplicated in a separate `pendingDelegations` map.
  // No escalation routing map: an escape uses the root thread's ordinary `forwardRoutes` (it proxies to
  // the outside instead of to a parent), and the returning `escalateAck` re-enters as a plain `askAck` to
  // that root thread. The actor routes the round trip by `delegation` (→ `delegationChild` = the raiser).
  /** A cancelling thread's id -> the exit it performs once its subtree's teardown is confirmed. */
  cancelExits: Record<number, CancelExit>;
  // Instance-local id counters.
  nextThreadId: number;
  nextCallId: number;
  nextAskId: number;
};

/**
 * The warm in-memory state of one project (held by its ProjectActor). Instances load on demand;
 * scopes are the CORE-global store shared across them. The engine holds only `core` instances — the api
 * management root is a Layer 1 entity + a sentinel id, not an engine instance (see `InstanceKind`).
 */
export type ProjectStore = {
  instances: Record<InstanceId, CoreInstance>;
  /** ScopeId -> Scope (CORE-global per project). */
  scopes: Record<number, Scope>;
  /** A derived index over `scopes[].owner`: the scopes each instance currently owns. Maintained on every
   *  owner change (allocate / re-own / free) through the `scope.ts` helpers, so the per-owner sweeps
   *  (`ResourcePool.markOwnedDirty`, the GC sweep, an instance teardown) iterate only that instance's scopes
   *  instead of scanning the whole store. An in-transit scope (`owner = null`) sits in no bucket. */
  scopesByOwner: Map<InstanceId, Set<ScopeId>>;
  nextScopeId: number;
  /** BlobId -> the blob's ownership + metadata. The bytes live in the `BlobStore` (S3); this holds only the
   *  owner (`null` while in-transit mid-ascent — drives blob GC / ascent symmetrically to a scope's `owner`)
   *  and the descriptor a `ref` value / download needs. The warm SoT for blob ownership; persisted to the
   *  `blobs` table as a snapshot (like scopes) by the `ResourcePool`. */
  blobs: Record<BlobId, BlobEntry>;
};

/** A blob's warm-store entry: who owns its bytes, plus the content descriptor (the bytes themselves are in
 *  the `BlobStore`). Mirrors the `blobs` table row. */
export type BlobEntry = {
  owner: InstanceId | null;
  hash: string;
  size: number;
  contentType?: string;
  semanticKind: SemanticKind;
};

/**
 * The instance bookkeeping that has no dedicated `instances` column — persisted as the row's
 * `engine_state` JSON (its threads ride in the `threads` table). On load the actor's routing maps are
 * rebuilt from the instances' threads: a `DelegateThread`'s `delegationId` names the caller of an
 * outbound delegation, and an instance's `delegationId` names its child (which doubles as an escalation's
 * raiser) — so no separate delegation/escalation rows are needed for engine recovery.
 */
export type EngineState = {
  rootThreadId: ThreadId;
  // The summoner (`callerReactor`) is NOT here: it is the instance's ambient, persisted on the generic
  // envelope (`instances.caller_reactor`, base-owned) uniformly for every reactor kind — not in this core-
  // only payload. Outbound-delegation routing no longer lives here either: a `DelegateThread`'s
  // `delegationId` is its source of truth. Answer routing rides per-thread in `Thread.forwardRoutes`. The
  // actor needs no escalation mirror (a returning `escalateAck` routes to the raiser via `delegationChild`).
  cancelExits: Record<number, CancelExit>;
  nextThreadId: number;
  nextCallId: number;
  nextAskId: number;
};
