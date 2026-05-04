import type { BlockId, ReqId } from "../../ir/types.js";
import type { ScopeId, ThreadId } from "../id.js";
import type { Value } from "../value.js";

import type { APIThread } from "./api.js";
import type { UserThread } from "./user.js";
import type { PrimThread } from "./prim.js";
import type { RequestThread } from "./request.js";
import type { ExternalThread } from "./external.js";
import type { CtorThread } from "./ctor.js";
import type { MatchThread } from "./match.js";
import type { ForThread } from "./for.js";
import type { HandleThread } from "./handle.js";
import type { TupleThread } from "./tuple.js";
import type { ArrayThread } from "./array.js";

// ─── ThreadBase ─────────────────────────────────────────────────────────────

/** Common fields shared by all thread variants. */
export type ThreadBase = {
  id: ThreadId;
  scopeId: ScopeId;
  parentThreadId: ThreadId | null;
  childThreadIds: Set<ThreadId>;
  /** Handler map inherited from parent at thread creation time. */
  inheritedHandlers: Map<ReqId, HandlerEntry>;
  status: ThreadStatus;
};

// ─── ThreadStatus ───────────────────────────────────────────────────────────

export type ThreadStatus =
  | { kind: "running" }
  | { kind: "waiting" }
  | { kind: "done"; value: Value }
  | { kind: "cancelled" };

// ─── HandlerEntry ───────────────────────────────────────────────────────────

export type HandlerEntry = {
  /** BlockId of the handler body block. */
  handlerBlockId: BlockId;
  /** Scope of the HandleThread that registered this handler (state vars live here). */
  handleScopeId: ScopeId;
  /** HandleThread's inheritedHandlers — passed to handler body to prevent recursion. */
  outerHandlers: Map<ReqId, HandlerEntry>;
};

// ─── Thread (discriminated union) ───────────────────────────────────────────

export type Thread =
  | APIThread
  | UserThread
  | PrimThread
  | RequestThread
  | ExternalThread
  | CtorThread
  | MatchThread
  | ForThread
  | HandleThread
  | TupleThread
  | ArrayThread;
