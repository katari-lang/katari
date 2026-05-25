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

import type {
  BlockId,
  QualifiedName,
} from "../../ir/types.js";
import type {
  AskId,
  CallId,
  DelegationId,
  EscalationId,
  ScopeId,
  ThreadId,
} from "../id.js";
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
export type AgentThread = Common & {
  kind: "agent";
  /** BlockId of the BlockAgent we represent. */
  blockId: BlockId;
  /** Args this agent was called with (passed into the body's scope at create). */
  args: Record<string, Value>;
  /**
   * Delegation id that landed us here. Used to look up the sender in
   * `state.delegationSenders` when emitting delegateAck/terminateAck/escalate.
   */
  delegationId: DelegationId;
  /**
   * Set when a `return` ask (or natural body done) was caught. Drives the
   * eventual outbound `delegateAck` after children finish cancelling.
   */
  pendingReturn?: Value;
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

export type HandleThread = Common & {
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
  childRoles: Record<CallId, ChildRole>;
  /**
   * Sequential-mode pending action queue. Empty when block.parallel === true.
   */
  pendingActions: PendingAction[];
  /** Action to fire once a specific child finishes cancelling. */
  postCancelActions: Record<CallId, PostCancelAction>;
  /**
   * Set when a `break` ask was caught (handle scope's done-terminating
   * exit). Drives the eventual `done` to parent after children finish
   * cancelling.
   */
  pendingReturn?: Value;
};

export type ChildRole =
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
  | { kind: "thenClause"; mainResultValue: Value };

export type PendingAction =
  | {
      kind: "ask";
      reqId: QualifiedName;
      args: Record<string, Value>;
      askId: AskId;
      askerCallId: CallId;
    }
  | { kind: "thenClause"; mainResultValue: Value };

export type PostCancelAction =
  /** Pattern (i): general post-cancel cleanup, used by ForThread. */
  | { kind: "finish"; value?: Value }
  /** Pattern (ii): targeted `next` resume — fire askAck after the cancel completes. */
  | {
      kind: "askComplete";
      askId: AskId;
      askerCallId: CallId;
      value: Value;
    };

export type ForThread = Common & {
  kind: "for";
  blockId: BlockId;
  currentIndex: number;
  /** Iter source array values resolved at construction. */
  iterableSnapshot: Value[];
  postCancelActions: Record<CallId, PostCancelAction>;
  /** Set when a `break-for` ask was caught. */
  pendingReturn?: Value;
  /**
   * CallId of the spawned then-block child, when one exists. Set in
   * `emitForDone` at the moment the then-block is spawned; consulted in
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

export type RequestThread = Common & {
  kind: "request";
  reqId: QualifiedName;
  args: Record<string, Value>;
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
export type DelegateThread = Common & {
  kind: "delegate";
  /** BlockId of the BlockDelegate that spawned us (target lives in the block). */
  blockId: BlockId;
  /** Args passed in the delegate event. */
  args: Record<string, Value>;
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

export type PrimThread = Common & {
  kind: "prim";
  primName: string;
  args: Record<string, Value>;
};

export type CtorThread = Common & {
  kind: "ctor";
  ctorId: QualifiedName;
  args: Record<string, Value>;
};

/**
 * Shared shape for threads that fan out into N sibling element computations
 * and collect their results into an ordered sequence (TupleThread / ArrayThread).
 * The runtime helpers in `thread/ops/collecting.ts` operate generically on this
 * base; only the final-value construction step (build a tuple vs an array Value)
 * is variant-specific.
 */
type CollectingBase = {
  blockId: BlockId;
  /** CallId → element value, collected as children complete. */
  collected: Record<CallId, Value>;
  nextIndex: number;
};

export type TupleThread = Common & CollectingBase & {
  kind: "tuple";
};

export type ArrayThread = Common & CollectingBase & {
  kind: "array";
};

export type RecordThread = Common & CollectingBase & {
  kind: "record";
};

/** Union of every variant that uses the `CollectingBase` shape. */
export type CollectingThread = TupleThread | ArrayThread | RecordThread;

export type Thread =
  | AgentThread
  | UserThread
  | HandleThread
  | ForThread
  | MatchThread
  | RequestThread
  | DelegateThread
  | PrimThread
  | CtorThread
  | TupleThread
  | ArrayThread
  | RecordThread;

export type ThreadKind = Thread["kind"];
