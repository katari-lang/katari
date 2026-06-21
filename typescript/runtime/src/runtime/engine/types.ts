// The in-memory engine model: Instance (a shard = one agent activation's thread tree), Thread (a
// running block), and Scope (a lexical-binding node). See docs/2026-06-15-runtime-domain-model.md.
//
// Persistence mirror: an `Instance`'s threads persist row-per-thread (`threads`, with the
// variant-specific state in `payload`); scopes are CORE-global per project and persist row-per-scope
// (`scopes`), each scope's variables riding inline in its `scopes.values` JSON column (see the
// `engine.ts` header for why they are not their own table). The per-thread execution state below is
// the engine's working set; its exact fields will firm up in the engine phase.

import type { BlockId, QualifiedName } from "@katari-lang/types";
import type { DelegateTarget } from "../event/types.js";
import type {
  AskId,
  CallId,
  DelegationId,
  EscalationId,
  InstanceId,
  ScopeId,
  ThreadId,
} from "../ids.js";
import type { GenericSubstitution, Value } from "../value/types.js";

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
type ThreadBase = {
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
};

/** Runs a `sequence` block's operations one at a time, awaiting any spawning op before advancing. */
export type SequenceThread = ThreadBase & {
  kind: "sequence";
  /** Index of the next operation to run. */
  cursor: number;
  /** The child currently awaited (a `call` into a structural node), or `null` if none in flight. */
  pending: PendingCall | null;
};

/**
 * A primitive leaf body: runs the named prim against its `input` variable and acks the value. The run
 * may be async (a bounded env / blob fetch), which the internal consumer awaits inline within the turn;
 * the prim has no children, so it completes within its instance's turn.
 */
export type PrimitiveThread = ThreadBase & {
  kind: "primitive";
  /** The prim registry key (e.g. `primitive.add`); kept on the thread so a recovered turn can re-run it. */
  name: string;
  /** The in-scope variable holding the argument (seeded as `parameter` by the wrapping `AgentThread`). */
  input: number;
};

/** A data-constructor leaf body: builds the tagged value of `name` from `input` and acks it (synchronous). */
export type ConstructThread = ThreadBase & {
  kind: "construct";
  name: QualifiedName;
  input: number;
};

/**
 * A request leaf body: raises `name` as a `request` ask carrying `input`. Its instance has no handler of
 * its own, so the ask immediately escapes (via the root `AgentThread`) as an outbound `escalate`; the
 * thread suspends until the matching `escalateAck` resumes it, then acks the answered value.
 */
export type RequestThread = ThreadBase & {
  kind: "request";
  name: QualifiedName;
  input: number;
  /** The ask id this request raised, awaiting its answer (`askAck`); `null` before it has run. */
  askId: AskId | null;
};

/** Runs the arm body chosen by matching `subject`; forwards the arm's value as its own result. */
export type MatchThread = ThreadBase & {
  kind: "match";
  pending: PendingCall | null;
};

/** Drives a `for` loop, collecting each iteration's `next` value into `collected` in source order. */
export type ForThread = ThreadBase & {
  kind: "for";
  parallel: boolean;
  /** Sequential: the current iteration index. */
  cursor: number;
  /** Mapped next-values by iteration index (sparse until all land, in the parallel case); the dense
   *  source-ordered array is materialised at completion. Mirrors `ParallelThread.collected`. */
  collected: Record<number, Value>;
  /** Current state values (sequential `var s = ...`): index N -> the current value of `state_N`. */
  states: Record<number, Value>;
  /** Iteration index -> the child call running it (one for sequential, many concurrent for parallel). */
  pending: Record<number, CallId>;
};

/** Runs a `handle` body, dispatching escalations to its handlers and resuming via `next`. */
export type HandleThread = ThreadBase & {
  kind: "handle";
  parallel: boolean;
  /** Current state values: index N -> the current value of `state_N`. */
  states: Record<number, Value>;
  /** The body / a handler body currently in flight. */
  pending: PendingCall | null;
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
  delegationId: DelegationId;
  /** Where to bind the result when the `delegateAck` lands. */
  output: number | null;
};

/**
 * The thread running an `ExternalBlock` body: suspended on the external handler (FFI / sidecar).
 * This replaces the separate `external_calls` table — recovery scans `threads where kind='external'`.
 */
export type ExternalThread = ThreadBase & {
  kind: "external";
  /** The dispatch key the handler interprets. */
  key: string;
  /** The argument value passed to the handler (after `defaults` were applied). */
  argument: Value | null;
  /** open | done — the lifecycle of this external dispatch (acknowledgement still pending vs landed). */
  externalState: "open" | "done";
};

// ─── Ask / escalation routing ─────────────────────────────────────────────────────────────────

/**
 * What to do when a *resuming* ask is answered — either its internal `askAck`, or the `escalateAck` of
 * the outbound escalation it became. This is the single mechanism behind request and `next` routing,
 * both as it bubbles up the thread tree (each proxying thread records one) and as it crosses instance
 * boundaries (the root `AgentThread` records one when it escalates; a `DelegateThread` records one when
 * it relays a child's escalation inward). Unwinding asks (`return` / `break`) carry no continuation —
 * they terminate their asker rather than resume it.
 */
export type AnswerContinuation =
  /** Resume an internal asker: emit `askAck(thread, askId, value)`. */
  | { kind: "resumeThread"; thread: ThreadId; askId: AskId }
  /** Relay the answer back out to a child instance: emit `escalateAck(escalation, value)`. */
  | { kind: "relayEscalateAck"; escalation: EscalationId };

// ─── Instance (= shard) ─────────────────────────────────────────────────────────────────────────

export type InstanceStatus = "running" | "cancelling";

/**
 * One agent activation: a thread tree plus the bookkeeping to route inbound external events to the
 * right waiting thread. This is the unit of ownership and of load/persist (a shard). Scopes are NOT
 * here — they live in the per-project store (`ProjectStore.scopes`); this instance owns a subset of
 * them via `Scope.owner`. An instance is ephemeral (no terminal status — that lives on the run record);
 * its parent is not a field but is recovered through its `delegationId` (→ `delegations.callerInstanceId`).
 *
 * `ambientGenerics` is this activation's generic substitution (carried in on the spawning `delegate`
 * event). Inner scopes do not store it; they look it up on the instance.
 */
export type Instance = {
  id: InstanceId;
  /** The delegation that summoned this instance (`null` only for the project root); the parent is
   *  recovered from it. Also the correlation id of this instance's `delegateAck`. */
  delegationId: DelegationId | null;
  /** What this instance runs — `(name, snapshot)` or a closure; the snapshot lives here, not as a
   *  standalone instance attribute. */
  target: DelegateTarget;
  status: InstanceStatus;
  /** The ambient generic substitution for this activation (from the spawning `delegate.generics`). */
  ambientGenerics?: GenericSubstitution;
  rootThreadId: ThreadId;
  /** ThreadId -> Thread (instance-local). */
  threads: Record<number, Thread>;
  /** Outbound delegate -> the DelegateThread awaiting its ack (sender side). */
  pendingDelegations: Record<DelegationId, ThreadId>;
  /** A pending ask's id -> what to do when its `askAck` lands (resume an asker / relay an escalateAck). */
  askRoutes: Record<AskId, AnswerContinuation>;
  /** An outbound escalation's id -> what to do when its `escalateAck` lands. Replaces a bare owner map:
   *  routing the answer needs the full continuation, not just the issuing thread. */
  escalationContinuations: Record<EscalationId, AnswerContinuation>;
  // Instance-local id counters.
  nextThreadId: number;
  nextCallId: number;
  nextAskId: number;
};

/**
 * The warm in-memory state of one project (held by its ProjectActor). Instances load on demand;
 * scopes are the CORE-global store shared across them.
 */
export type ProjectStore = {
  instances: Record<InstanceId, Instance>;
  /** ScopeId -> Scope (CORE-global per project). */
  scopes: Record<number, Scope>;
  nextScopeId: number;
};
