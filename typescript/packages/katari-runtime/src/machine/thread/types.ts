import type { BlockId, ExitKind, ReqId } from "../../ir/types.js";
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

// ─── CallId ─────────────────────────────────────────────────────────────────

/**
 * Identifies a specific child call within a parent thread.
 * Each thread variant uses natural indices (element index, pc, etc.).
 */
export type CallId = number;

// ─── ThreadBase ─────────────────────────────────────────────────────────────

/** Common fields shared by all thread variants. */
export type ThreadBase = {
  id: ThreadId;
  scopeId: ScopeId;
  parent: Thread | null;
  /** Key in parent's children map. null for root (APIThread). */
  parentCallId: CallId | null;
  /** Handler map inherited from parent at creation time. */
  handlers: Map<ReqId, ThreadId>;
  /** Active (running or suspended) child threads. */
  children: Map<CallId, Thread>;
  /** Execution status. "cancelling" means waiting for all children to ack. */
  status: "running" | "cancelling";
  /** Return value stored while cancelling children (from return event). */
  pendingReturn?: Value;
  /** ExitKind for return propagation. undefined = at boundary (emit done). */
  pendingExitKind?: ExitKind;
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

// ─── QueueEvent ─────────────────────────────────────────────────────────────

/**
 * Events processed by the main loop (processQueue).
 * - call: parent requests creation and execution of a child thread.
 * - done: child notifies parent of completion with a value.
 * - cancel: parent requests termination of a child thread (recursive).
 * - cancelAck: child notifies parent that cancellation is complete.
 * - return: child notifies parent of non-local exit (propagates to boundary).
 */
export type QueueEvent =
  | {
      kind: "call";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Map<string, Value>;
      scopeId: ScopeId;
    }
  | {
      kind: "done";
      parent: Thread;
      callId: CallId;
      value: Value;
    }
  | {
      kind: "cancel";
      target: Thread;
    }
  | {
      kind: "cancelAck";
      parent: Thread;
      callId: CallId;
    }
  | {
      kind: "return";
      parent: Thread;
      callId: CallId;
      value: Value;
      exitKind: ExitKind;
    };

// ─── CreateThreadInit ───────────────────────────────────────────────────────

/**
 * Common initialization data passed by the runner to each thread's create function.
 */
export type CreateThreadInit = {
  id: ThreadId;
  parent: Thread;
  parentCallId: CallId;
  handlers: Map<ReqId, ThreadId>;
  scopeId: ScopeId;
};
