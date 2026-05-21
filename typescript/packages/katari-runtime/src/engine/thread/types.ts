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
  ExternalName,
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
export type AskIdMap = Record<number, { childCallId: CallId; childAskId: AskId }>;

/** Common fields present on every thread variant. */
type Common = {
  id: ThreadId;
  parent: ThreadId | null;
  parentCallId: CallId | null;
  scopeId: ScopeId;
  status: ThreadStatus;
  /** Live children. Map<CallId, ThreadId>, encoded as a Record for Immer. */
  children: Record<number, ThreadId>;
  /** Active handler-owning HandleThread per ReqId, inherited from parent. */
  handlers: Record<number, ThreadId>;
  /** Per-thread next CallId allocator. */
  nextCallId: CallId;
  /** Per-thread next AskId allocator (for proxy forwarding). */
  nextAskId: AskId;
  /** Forwarding bookkeeping for asks bubbled through this thread. */
  askIdMap: AskIdMap;
};

// ─── Variant payloads ──────────────────────────────────────────────────────

/**
 * AgentThread: agent boundary. Wraps a `BlockAgent` IR block.
 *
 * Spawned by:
 *   - inbound `delegate` event (translateExternal): creates a root AgentThread
 *     for the entry block, registered under `state.delegations[delegationId]`.
 *   - inline `statementAgentCall` (either qname or value/closure form):
 *     emits an outbound `delegate` event (core→core, from=to=selfEndpoint)
 *     that the runner picks up on the next iteration and spawns a fresh
 *     AgentThread.
 *
 * Catches `return` asks bubbling up from descendants. Owns one body
 * UserThread spawned at create-time (callId 0). When the body completes
 * — naturally, via caught return, or via cancel — the AgentThread emits
 * `delegateAck` / `terminateAck` to the registered sender.
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
   * Outstanding outbound escalations: childAskId → escalationId. Populated
   * when a non-return `ask` reaches a root AgentThread (parent === null) —
   * we forward it to the delegation sender as an `escalate` event,
   * symmetric with `ExternalThread.pendingEscalations`. Cleared on the
   * matching `escalateAck` from the sender side.
   */
  pendingEscalations: Record<number, EscalationId>;
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
  childRoles: Record<number, ChildRole>;
  /**
   * Sequential-mode pending action queue. Empty when block.parallel === true.
   */
  pendingActions: PendingAction[];
  /** Action to fire once a specific child finishes cancelling. */
  postCancelActions: Record<number, PostCancelAction>;
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
  postCancelActions: Record<number, PostCancelAction>;
  /** Set when a `break-for` ask was caught. */
  pendingReturn?: Value;
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
 * Sentinel `externalName` used by 'spawnExternalForAgentDelegate' for the
 * phantom external that wraps a CORE→CORE agent invocation. Branches on
 * this value in the external ops choose `selfEndpoint` over
 * `ffiTargetEndpoint`. v0.1.0 RFC: replace this sentinel + branches with
 * a proper discriminator on the thread variant; tracked in memory under
 * `project_thread_abstraction_refactor`.
 */
export const PHANTOM_AGENT_EXTERNAL_NAME = "<agent>.<delegate>";

export type ExternalThread = Common & {
  kind: "external";
  externalName: ExternalName;
  args: Record<string, Value>;
  delegationId: DelegationId;
  /**
   * Outstanding outbound escalations: childAskId → escalationId. Set when
   * an `ask` bubbles up into this thread; cleared on the matching
   * `escalateAck` from the external side. Late acks after the thread is
   * cancelling get dropped.
   */
  pendingEscalations: Record<number, EscalationId>;
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

export type TupleThread = Common & {
  kind: "tuple";
  blockId: BlockId;
  /** CallId → element value, collected as children complete. */
  collected: Record<number, Value>;
  nextIndex: number;
};

export type ArrayThread = Common & {
  kind: "array";
  blockId: BlockId;
  collected: Record<number, Value>;
  nextIndex: number;
};

export type Thread =
  | AgentThread
  | UserThread
  | HandleThread
  | ForThread
  | MatchThread
  | RequestThread
  | ExternalThread
  | PrimThread
  | CtorThread
  | TupleThread
  | ArrayThread;

export type ThreadKind = Thread["kind"];
