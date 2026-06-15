// The in-memory engine model: Instance (a shard = one agent activation's thread tree), Thread (a
// running block), and Scope (a lexical-binding node). See docs/2026-06-15-runtime-domain-model.md.
//
// Persistence mirror: an `Instance`'s threads persist row-per-thread (`threads`, with the
// variant-specific state in `payload`); scopes are CORE-global per project and persist row-per-scope
// (`scopes`) with their variables row-per-variable (`scope_variables`). The per-thread execution
// state below is the engine's working set; its exact fields will firm up in the engine phase.

import type { BlockId } from "@katari-lang/types";
import type { DelegateTarget } from "../event/types.js";
import type { CallId, DelegationId, EscalationId, InstanceId, ScopeId, ThreadId } from "../ids.js";
import type { GenericSubstitution, Value } from "../value/types.js";

// ─── Scope ──────────────────────────────────────────────────────────────────────────────────────

/**
 * A lexical-binding tree node. CORE-global (one store per project, shared across instances) and
 * owned by an instance for cascade / ascent / intra-instance GC. `owner` is the instance that
 * created it; it rises to an ancestor when an escaping value carries it up, or to `null` while
 * in-transit mid-ascent (mirrors a blob's owner). Variables are kept inline here in memory; at rest
 * they are rows in `scope_variables`.
 */
export type Scope = {
  id: ScopeId;
  parentId: ScopeId | null;
  owner: InstanceId | null;
  /** VariableId -> Value. */
  values: Record<number, Value>;
  /** The ambient generic substitution of the enclosing activation; inner scopes inherit it. */
  ambientGenerics?: GenericSubstitution;
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

export type Thread =
  | SequenceThread
  | MatchThread
  | ForThread
  | HandleThread
  | ParallelThread
  | DelegateThread;

/** Runs a `sequence` block's operations one at a time, awaiting any spawning op before advancing. */
export type SequenceThread = ThreadBase & {
  kind: "sequence";
  /** Index of the next operation to run. */
  cursor: number;
  /** The child currently awaited (a `call` into a structural node), or `null` if none in flight. */
  pending: PendingCall | null;
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
  /** Mapped next-values in source order (sparse until all iterations land, for the parallel case). */
  collected: Value[];
  /** Current state-var values (sequential `var s = ...`): VariableId -> Value. */
  states: Record<number, Value>;
  /** Iteration index -> the child call running it (one for sequential, many concurrent for parallel). */
  pending: Record<number, CallId>;
};

/** Runs a `handle` body, dispatching escalations to its handlers and resuming via `next`. */
export type HandleThread = ThreadBase & {
  kind: "handle";
  parallel: boolean;
  /** Current state-var values: VariableId -> Value. */
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
  /** Outbound escalations awaiting an `escalateAck`, to route the reply back to the callee. */
  inboundEscalations: Record<string, EscalationId>;
};

// ─── Instance (= shard) ─────────────────────────────────────────────────────────────────────────

export type InstanceStatus = "running" | "cancelling" | "completed";

/**
 * One agent activation: a thread tree plus the bookkeeping to route inbound external events to the
 * right waiting thread. This is the unit of ownership and of load/persist (a shard). Scopes are NOT
 * here — they live in the per-project store (`ProjectStore.scopes`); this instance owns a subset of
 * them via `Scope.owner`.
 */
export type Instance = {
  id: InstanceId;
  parentId: InstanceId | null;
  /** The delegation that summoned this instance (`null` only for the project root). */
  delegationId: DelegationId | null;
  /** What this instance runs — `(name, snapshot)` or a closure; the snapshot lives here, not as a
   *  standalone instance attribute. */
  target: DelegateTarget;
  status: InstanceStatus;
  rootThreadId: ThreadId;
  /** ThreadId -> Thread (instance-local). */
  threads: Record<number, Thread>;
  /** Outbound delegate -> the DelegateThread awaiting its ack (sender side). */
  pendingDelegations: Record<DelegationId, ThreadId>;
  /** Outbound escalate -> the thread that issued it, for O(1) `escalateAck` routing. */
  escalationOwners: Record<EscalationId, ThreadId>;
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
