// Thread: the execution unit of the engine. Stored as plain data
// (tagged union) so Immer can update it structurally and the snapshot
// layer can serialize it without OO ceremony.
//
// Each variant carries:
//   - `kind`: discriminator
//   - common fields: id / parent / parentCallId / scopeId / status / children / askIdMap
//   - variant-specific fields (pc, blockId, etc.)
//
// All operations on threads live in `engine/thread/ops/`. Threads are
// **never** mutated in place after construction; engine code produces a
// new Thread record (via Immer or explicit spread) when state changes.

import type { BlockId, QualifiedName } from "../../ir/types.js";
import type { AskId, CallId, DelegationId, EscalationId, ScopeId, ThreadId } from "../id.js";
import type { Value } from "../value.js";

// ─── Common ────────────────────────────────────────────────────────────────

export type ThreadStatus = "running" | "cancelling";

/**
 * AskIdMap: proxy threads forward asks upwards by allocating *their own*
 * AskId and storing the (childCallId, childAskId) pair under it. When the
 * matching askAck comes back addressed to `own_askId`, the proxy looks up
 * the original sender and forwards the ack down.
 */
export type AskIdMap = Record<AskId, { childCallId: CallId; childAskId: AskId }>;

/** Common fields present on every thread variant. */
type Common = {
  id: ThreadId;
  parent: ThreadId | null;
  parentCallId: CallId | null;
  scopeId: ScopeId;
  status: ThreadStatus;
  /** Live children, keyed by the CallId allocated when each was spawned. */
  children: Record<CallId, ThreadId>;
  /** Per-thread next CallId allocator. */
  nextCallId: CallId;
  /** Per-thread next AskId allocator (for proxy forwarding). */
  nextAskId: AskId;
  /** Forwarding bookkeeping for asks bubbled through this thread. */
  askIdMap: AskIdMap;
};

// ─── Variant payloads ──────────────────────────────────────────────────────

/**
 * AgentThread: agent boundary (receiver side of a delegation). Wraps a
 * `BlockAgent` IR block.
 *
 * Spawned by an inbound `delegate` event (translateExternal) — creates a
 * root AgentThread for the entry block, registered under
 * `state.delegations[delegationId]`.
 *
 * Catches `return` asks bubbling up from descendants. Owns one body
 * thread spawned at create-time (callId 0). When the body completes
 * — naturally, via caught return, or via cancel — the AgentThread emits
 * `delegateAck` / `terminateAck` to the registered sender.
 *
 * Children's non-return asks are converted into outbound `escalate`
 * events to the delegation sender (= we are the sender of escalate, the
 * sender of the original delegate is the receiver of escalate). The
 * eventual `escalateAck` arrives inbound and is converted into an
 * `askAck` to the child via `outboundEscalations`.
 */
export type AgentThread<V = Value> = Common & {
  kind: "agent";
  /** BlockId of the BlockAgent we represent. */
  blockId: BlockId;
  /** Args this agent was called with (passed into the body's scope at create). */
  argument: V | undefined;
  /**
   * Delegation id that landed us here. Used to look up the sender in
   * `state.delegationSenders` when emitting delegateAck/terminateAck/escalate.
   */
  delegationId: DelegationId;
  /**
   * Set when a `return` ask (or natural body done) was caught. Drives the
   * eventual outbound `delegateAck` after children finish cancelling.
   */
  pendingReturn?: V;
  /**
   * Outstanding outbound escalations: escalationId → askId. Populated when
   * a non-return `ask` from a descendant reaches this root and is converted
   * into an outbound `escalate` event (we issue the escalationId). The
   * eventual inbound `escalateAck` carries the same escalationId and we
   * look up the original askId here to deliver the `askAck` back to the
   * descendant child. Direction is reversed compared to
   * `DelegateThread.inboundEscalations` because the lookup driver is
   * different (we receive ack by escalationId, not by askId).
   */
  outboundEscalations: Record<EscalationId, AskId>;
};

export type UserThread = Common & {
  kind: "user";
  blockId: BlockId;
  /** Statement program counter. */
  pc: number;
};

export type HandleThread<V = Value> = Common & {
  kind: "handle";
  blockId: BlockId;
  /**
   * Per-child role tracking. Encoded as a Record<CallId, ChildRole>.
   *
   * Roles:
   *   - "main"        — the body block (callId = 0)
   *   - "handlerBody" — a handler invocation (carries the asker chain)
   *   - "thenClause"  — the optional `then` clause spawned after main done
   */
  childRoles: Record<CallId, ChildRole<V>>;
  /**
   * Sequential-mode pending action queue. Empty when block.parallel === true.
   */
  pendingActions: PendingAction<V>[];
  /** Action to fire once a specific child finishes cancelling. */
  postCancelActions: Record<CallId, PostCancelAction<V>>;
  /**
   * Set when a `break` ask was caught (handle scope's done-terminating
   * exit). Drives the eventual `done` to parent after children finish
   * cancelling.
   */
  pendingReturn?: V;
};

export type ChildRole<V = Value> =
  | { kind: "main" }
  | {
      kind: "handlerBody";
      reqId: QualifiedName;
      /**
       * The askId we received on the inbound `request` ask, used to
       * address the eventual `askAck` back to the proxy chain.
       */
      askId: AskId;
      /**
       * Which child of the HandleThread the inbound `request` arrived
       * from — the ack travels back through this same proxy.
       */
      askerCallId: CallId;
    }
  | { kind: "thenClause"; mainResultValue: V };

export type PendingAction<V = Value> =
  | {
      kind: "ask";
      reqId: QualifiedName;
      argument: V | undefined;
      askId: AskId;
      askerCallId: CallId;
    }
  | { kind: "thenClause"; mainResultValue: V };

export type PostCancelAction<V = Value> =
  /** Pattern (i): general post-cancel cleanup, used by ForThread. */
  | { kind: "finish"; value?: V }
  /** Pattern (ii): targeted `next` resume — fire askAck after the cancel completes. */
  | {
      kind: "askComplete";
      askId: AskId;
      askerCallId: CallId;
      value: V;
    };

export type ForThread<V = Value> = Common & {
  kind: "for";
  blockId: BlockId;
  /** Sequential cursor: the index of the iteration currently running. */
  currentIndex: number;
  /** Total iteration count (Cartesian product of the iter sources). */
  total: number;
  /** Iter source array values resolved at construction. */
  iterableSnapshot: V[];
  /**
   * Mapped output accumulator: each iteration's `next v` value, keyed by its
   * iteration index so parallel completions stay in source order. Assembled
   * into an array (the loop's value, or the then-clause's input) on
   * completion.
   */
  collected: Record<number, V>;
  /** CallId → iteration index, so an inbound `next-for` knows which slot to fill. */
  iterIndexByCallId: Record<CallId, number>;
  postCancelActions: Record<CallId, PostCancelAction<V>>;
  /** Set when a `break-for` ask was caught (short-circuits to this value). */
  pendingReturn?: V;
  /**
   * CallId of the spawned then-block child, when one exists. Set in
   * `emitForResult` at the moment the then-block is spawned; consulted in
   * `done` to tell a then-block completion apart from an iteration
   * body completion. `null` when there is no then-block or it has not
   * yet been spawned.
   */
  thenCallId: CallId | null;
};

export type MatchThread = Common & {
  kind: "match";
  blockId: BlockId;
};

/**
 * GetFieldThread: reads one field out of a record value. Spawned inline by a
 * StatementCall targeting a `blockGetField`; reads its `source` var from the
 * inherited scope and `done`s the field value (or null) to its parent. A
 * thread (not an inline statement) so the read can grow an async path once
 * file / blob / stream sources need materialising.
 */
export type GetFieldThread = Common & {
  kind: "getField";
  blockId: BlockId;
};

export type RequestThread<V = Value> = Common & {
  kind: "request";
  reqId: QualifiedName;
  argument: V | undefined;
  /** Set after the initial ask has been emitted. */
  pendingAskId?: AskId;
};

/**
 * DelegateThread: sender side of a delegation. Spawned by `StatementCall`
 * to a `BlockDelegate` IR block. On create the thread emits an outbound
 * `delegate` event to the appropriate endpoint:
 *
 *   - target = `delegateTargetInternal`: selfEndpoint (CORE loopback).
 *   - target = `delegateTargetExternal`: ffiTargetEndpoint.
 *   - target = `delegateTargetValue`: resolves the runtime value at the
 *     given VarId (agentLiteral → check entries to decide internal vs
 *     external; closure → CORE loopback with captured scope).
 *
 * Has no children of its own. The inbound `delegateAck` is translated by
 * the runner into a `done` event addressed to this thread; cancel emits a
 * `terminate` to the peer and waits for the matching ack.
 *
 * Inbound `escalate` events from the receiver side are converted into
 * upward `ask` events to this thread's parent. The eventual `askAck`
 * from above is converted into an outbound `escalateAck` to the peer via
 * `inboundEscalations`.
 */
export type DelegateThread<V = Value> = Common & {
  kind: "delegate";
  /** BlockId of the BlockDelegate that spawned us (target lives in the block). */
  blockId: BlockId;
  /** Args passed in the delegate event. */
  argument: V | undefined;
  /** Delegation id issued by us at create time. */
  delegationId: DelegationId;
  /**
   * Outstanding inbound escalations: askId → escalationId. Set when an
   * inbound `escalate` event from the receiver side is converted into an
   * upward `ask` (we allocate the askId; the escalationId came from the
   * peer). Cleared on the matching `askAck` from above (we then emit an
   * outbound `escalateAck`).
   */
  inboundEscalations: Record<AskId, EscalationId>;
};

export type PrimThread<V = Value> = Common & {
  kind: "prim";
  primName: string;
  argument: V | undefined;
  /**
   * Set after the prim raised a custom request (e.g. `json_parse_error`)
   * and the corresponding `ask` was emitted upward. The thread stays
   * alive in a "waiting for cancel" state — for `-> never` requests no
   * `askAck` is expected, but if one ever arrives we drop it as a
   * defensive noop. The cancel cascade from whatever handler caught the
   * request is what actually terminates this thread.
   */
  pendingAskId?: AskId;
};

export type CtorThread<V = Value> = Common & {
  kind: "ctor";
  ctorId: QualifiedName;
  argument: V | undefined;
};

/**
 * MakeClosureThread: the async creation of a closure value. Spawned by a
 * `StatementMakeClosure` (a closure literal / local agent). Its `create`
 * serializes the captured scope chain into a value-store blob via `ctx.putBlob`
 * and `done`s its parent with the resulting content-ref closure value. Modelled
 * as a thread (not an inline statement) because persisting the env is async,
 * and in this engine a step that waits is a thread — so the statement loop and
 * `done` stay synchronous (suspension only ever happens by waiting on a child).
 * Has no children.
 */
export type MakeClosureThread = Common & {
  kind: "makeClosure";
  /** Body block (a BlockAgent) the closure runs when invoked. */
  blockId: BlockId;
  /** The scope chain to capture (= the spawning thread's scope). */
  capturedScopeId: ScopeId;
  /**
   * The var the closure binds itself to in its captured scope (a recursive
   * local agent self-references through it). Recorded so materialize can
   * re-bind it to the closure on the receiving side.
   */
  selfVar: number;
};

/**
 * CallAgentThread: the runtime side of the @call_agent(name, args)@
 * primitive. Spawned in place of a PrimThread when the lowered prim
 * leaf's name is the well-known string @"primitive.call_agent"@.
 *
 * Lifecycle:
 *
 *   1. `create` — parses the @name@ argument into a callable identity
 *      (qualified-name agentLiteral or closure stamp), validates the
 *      @args@ record against the resolved target's input schema, and
 *      either:
 *        a. emits an outbound `delegate` event for the resolved target
 *           and stays alive waiting for the matching ack; or
 *        b. on resolve / validation failure, raises the
 *           @call_agent_error@ request upward (the
 *           @pendingAskId@ field below). The thread then stays alive in
 *           a waiting-for-cancel state, mirroring how PrimThread
 *           handles a @PrimRaiseRequest@ throw.
 *
 *   2. `done` (= translated `delegateAck`) — forwards the result value
 *      to our parent as a `done` and exits.
 *
 *   3. `cancel` — emits a `terminate` for any in-flight delegation and
 *      waits for the ack. Mirrors DelegateThread.
 *
 *   4. Inbound `escalate` from the peer becomes an upward `ask` to our
 *      parent (same as DelegateThread); its eventual `askAck` becomes
 *      an outbound `escalateAck`.
 */
export type CallAgentThread<V = Value> = Common & {
  kind: "callAgent";
  /**
   * The callable VALUE to invoke (an `agentLiteral` or `closure`; it carries
   * the dispatch identity + any generic substitution). Resolved at @create@.
   */
  target: V;
  /**
   * The user-supplied @args@ record (dynamically built, e.g. from an AI). Kept
   * verbatim until @create@, where it is validated against the target's input
   * schema (specialised to the target's generics) before the delegate fires.
   */
  argsRecord: Record<string, V>;
  /**
   * `delegationId` issued at create time when the delegate path is
   * taken (= name resolved successfully). Unset otherwise (= the thread
   * raised an error and is waiting for cancel).
   */
  delegationId?: DelegationId;
  /** Mirror of DelegateThread.inboundEscalations. */
  inboundEscalations: Record<AskId, EscalationId>;
  /** AskId reserved when the thread raised @call_agent_error@. */
  pendingAskId?: AskId;
};

/**
 * Shared shape for threads that fan out into N sibling element computations
 * and collect their results into an ordered sequence (TupleThread). The runtime
 * helpers in `thread/ops/collecting.ts` operate generically on this base; the
 * final value is always an ordered `array` Value (tuples and arrays share it).
 */
type CollectingBase<V = Value> = {
  blockId: BlockId;
  /** CallId → element value, collected as children complete. */
  collected: Record<CallId, V>;
  nextIndex: number;
};

// The unified seq thread — both `[...]` and `par [...]` fan out here and collect
// into one ordered `array` Value (tuple / array share the runtime form).
export type TupleThread<V = Value> = Common &
  CollectingBase<V> & {
    kind: "tuple";
  };

export type RecordThread<V = Value> = Common &
  CollectingBase<V> & {
    kind: "record";
  };

/**
 * Threads that go through the shared collecting ops (`collecting.ts`).
 * RecordThread uses `CollectingBase` for its shape but has its own ops
 * (`record.ts`) — it is intentionally excluded here.
 */
export type CollectingThread<V = Value> = TupleThread<V>;

// `V` parameterises the embedded `Value` type so the storage boundary can
// instantiate `Thread<EncryptedValue>` for the encrypted-at-rest checkpoint
// form. The live engine always uses the default `Thread = Thread<Value>`; only
// `engine/snapshot.ts` (encrypt / decrypt) ever picks a different `V`. See the
// `mapThreadValues` walker there — its `Thread<V> → Thread<W>` signature is
// what makes "every embedded Value is transformed" a compile-time guarantee.
export type Thread<V = Value> =
  | AgentThread<V>
  | UserThread
  | HandleThread<V>
  | ForThread<V>
  | MatchThread
  | RequestThread<V>
  | DelegateThread<V>
  | PrimThread<V>
  | CallAgentThread<V>
  | CtorThread<V>
  | MakeClosureThread
  | TupleThread<V>
  | RecordThread<V>
  | GetFieldThread;

export type ThreadKind = Thread["kind"];
