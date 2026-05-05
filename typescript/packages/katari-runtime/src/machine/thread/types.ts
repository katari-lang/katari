import type { BlockId, ContKind, ExitKind, ReqId } from "../../ir/types.js";
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

// ─── Boundaries ─────────────────────────────────────────────────────────────

/**
 * Direct dispatch targets for the five global-exit operations.
 *
 * Each thread carries this map and exit / cont statements look up their
 * boundary thread directly via `thread.boundaries[exitKind | contKind]`.
 * Inherited from parent by reference at thread creation. When the new
 * thread is itself a boundary (agent UserThread / ForThread / HandleThread),
 * the runner branches a new map with the relevant key(s) overridden to self.
 *
 * Cont keys (`contKindForNext` / `contKindNext`) are reserved here for the
 * future runtime dispatch of `next` / `for_next`. They are populated for
 * ForThread / HandleThread boundary threads but no QueueEvent currently
 * targets them.
 */
export type Boundaries = {
  exitKindReturn: Thread | null;
  exitKindForBreak: Thread | null;
  exitKindBreak: Thread | null;
  contKindForNext: Thread | null;
  contKindNext: Thread | null;
};

/** Initial boundaries with every key set to null. Used for root (APIThread). */
export const EMPTY_BOUNDARIES: Boundaries = {
  exitKindReturn: null,
  exitKindForBreak: null,
  exitKindBreak: null,
  contKindForNext: null,
  contKindNext: null,
};

/** Key used to address a boundary slot. ExitKind ∪ ContKind. */
export type BoundaryKey = ExitKind | ContKind;

// ─── ThreadBase ─────────────────────────────────────────────────────────────

/** Fields common to every thread variant. */
type CommonThreadFields = {
  id: ThreadId;
  scopeId: ScopeId;
  /** Handler map inherited from parent at creation time. */
  handlers: Map<ReqId, ThreadId>;
  /** Active (running or suspended) child threads. */
  children: Map<CallId, Thread>;
  /** Execution status. "cancelling" means waiting for all children to ack. */
  status: "running" | "cancelling";
  /** Direct targets for exit / cont operations. */
  boundaries: Boundaries;
  /**
   * Return value stored while cancelling children. Set when a `return`
   * event is delivered to this thread (this thread is the boundary).
   * Cleared on creation. If still undefined at finishCancelling time the
   * cancellation was initiated by a parent and we emit cancelAck rather
   * than done.
   */
  pendingReturn?: Value;
};

/** Base for root threads (APIThread). Has no parent. */
export type RootThreadBase = CommonThreadFields & {
  parent: null;
  parentCallId: null;
};

/** Base for non-root (child) threads. Always has a parent + parentCallId. */
export type ChildThreadBase = CommonThreadFields & {
  parent: Thread;
  parentCallId: CallId;
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
 *
 * Call events are split by call site so that each child thread gets a fresh
 * scope with a parent determined statically by the call kind:
 * - callBlock: top-level callable (statementCall/callTargetBlock or API entry).
 *   New scope with parent = null (isolated).
 * - callInline: inline child of a structural block (array/tuple/match/for/handle).
 *   New scope with parent = scopeId (caller's current scope).
 * - callValue: closure call (statementCall/callTargetValue).
 *   New scope with parent = capturedScopeId (closure's captured scope).
 *
 * Other events:
 * - done: child notifies parent of completion with a value.
 * - cancel: parent requests termination of a child thread (recursive).
 * - cancelAck: child notifies parent that cancellation is complete.
 * - return: child notifies parent of non-local exit (propagates to boundary).
 */
export type QueueEvent =
  | {
      kind: "callBlock";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Map<string, Value>;
    }
  | {
      kind: "callInline";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Map<string, Value>;
      scopeId: ScopeId;
    }
  | {
      kind: "callValue";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Map<string, Value>;
      capturedScopeId: ScopeId;
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
      /**
       * Global exit (return / for_break / break) delivered directly to
       * its boundary thread. The source thread looks up the boundary via
       * `boundaries[exitKind]` and sends this event with the boundary as
       * the target. The boundary cancels its children, then emits done.
       */
      kind: "return";
      target: Thread;
      value: Value;
      exitKind: ExitKind;
    };

// ─── CreateThreadInit ───────────────────────────────────────────────────────

/**
 * Common initialization data passed by the runner to each child thread's
 * create function. The runner allocates `scopeId` (a fresh scope) before
 * dispatching, so create functions just store it.
 */
export type CreateThreadInit = {
  id: ThreadId;
  parent: Thread;
  parentCallId: CallId;
  handlers: Map<ReqId, ThreadId>;
  scopeId: ScopeId;
  /**
   * Inherited (by reference) from the parent. The runner overwrites the
   * thread's `.boundaries` after creation if the new thread is itself a
   * boundary type.
   */
  boundaries: Boundaries;
};
