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
  CtorId,
  ExternalName,
  ReqId,
} from "../../ir/types.js";
import type {
  AskId,
  CallId,
  DelegationId,
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
  /** Set when a done-terminating ask (return/break/break-for) was caught. */
  pendingReturn?: Value;
};

// ─── Variant payloads ──────────────────────────────────────────────────────

export type UserThread = Common & {
  kind: "user";
  blockId: BlockId;
  /** Statement program counter. */
  pc: number;
  /** True if this user thread caches `return` (block.kind === "blockKindAgent"). */
  catchesReturn: boolean;
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
};

export type ChildRole =
  | { kind: "main" }
  | {
      kind: "handlerBody";
      reqId: ReqId;
      /** Which AskId on this thread is currently being serviced. */
      askId: AskId;
    }
  | { kind: "thenClause"; mainResultValue: Value };

export type PendingAction =
  | { kind: "ask"; reqId: ReqId; args: Record<string, Value>; askId: AskId }
  | { kind: "thenClause"; mainResultValue: Value };

export type PostCancelAction =
  /** Pattern (i): general post-cancel cleanup. */
  | { kind: "finish"; value?: Value }
  /** Pattern (ii): targeted next/break-for resume. */
  | { kind: "askComplete"; askId: AskId; value: Value };

export type ForThread = Common & {
  kind: "for";
  blockId: BlockId;
  currentIndex: number;
  /** Iter source array values resolved at construction. */
  iterableSnapshot: Value[];
  postCancelActions: Record<number, PostCancelAction>;
};

export type MatchThread = Common & {
  kind: "match";
  blockId: BlockId;
};

export type RequestThread = Common & {
  kind: "request";
  reqId: ReqId;
  args: Record<string, Value>;
  /** Set after the initial ask has been emitted. */
  pendingAskId?: AskId;
};

export type ExternalThread = Common & {
  kind: "external";
  externalName: ExternalName;
  args: Record<string, Value>;
  delegationId: DelegationId;
};

export type PrimThread = Common & {
  kind: "prim";
  primName: string;
  args: Record<string, Value>;
};

export type CtorThread = Common & {
  kind: "ctor";
  ctorId: CtorId;
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
