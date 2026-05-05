import type { BlockId, ContKind, ExitKind, ReqId, VarId } from "../../ir/types.js";
import type { AskId, ScopeId, ThreadId } from "../id.js";
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
  /**
   * Handler-owning thread for each registered request. Inherited from
   * parent at creation (typically by-reference copy via `new Map(...)`),
   * augmented when a HandleThread spawns its main target with its own
   * declared handlers. handler-body / thenClause spawns do NOT add their
   * own handle's overrides — they see the outer handlers (algebraic
   * effect semantic).
   */
  handlers: Map<ReqId, Thread>;
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
      args: Record<string, Value>;
    }
  | {
      kind: "callInline";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Record<string, Value>;
      scopeId: ScopeId;
      /**
       * Optional explicit handlers map for the new child. If omitted, the
       * runner copies `parent.handlers` by value. HandleThread uses this
       * to spawn its main target with augmented handlers (parent + this
       * handle's own overrides) while still spawning handler-body /
       * thenClause without those overrides.
       */
      handlersOverride?: Map<ReqId, Thread>;
    }
  | {
      kind: "callValue";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Record<string, Value>;
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
    }
  | {
      /**
       * `request foo(args)` from a RequestThread. Direct-delivered to the
       * handler-owning thread (HandleThread) registered in the asker's
       * `handlers` map for `reqId`. The boundary spawns the corresponding
       * handler body as ITS child (not the asker's child) and remembers
       * `(asker, askId)` so it can later route the resume value back.
       */
      kind: "ask";
      target: Thread;
      asker: Thread;
      askId: AskId;
      reqId: ReqId;
      args: Record<string, Value>;
    }
  | {
      /**
       * Reply to a previously-issued `ask`. Sent by HandleThread back to
       * the asker (RequestThread) after a handler resumed via `next`.
       * The asker matches askId and emits `done` to its parent with
       * `value`.
       */
      kind: "askComplete";
      target: Thread;
      askId: AskId;
      value: Value;
    }
  | {
      /**
       * `next` / `for_next` (statementCont) delivered directly to its
       * boundary thread. Like `return`, the source thread looks up the
       * boundary via `boundaries[contKind]`. Modifiers are pre-evaluated
       * by the source: each `(targetVar, Value)` writes `Value` into the
       * boundary's scope.
       *
       * For for_next: the boundary (ForThread) cancels the current body
       * iteration, applies modifiers to its state vars, advances the
       * iteration index.
       *
       * For next (in a request handler): the boundary (HandleThread)
       * cancels the handler body, applies modifiers, then emits an
       * `askComplete` to resume the asker.
       *
       * `source` is the emitting thread (a descendant of `target`); the
       * boundary uses it to identify which immediate child of itself
       * corresponds to the handler body / iteration body to cancel.
       */
      kind: "cont";
      target: Thread;
      source: Thread;
      contKind: ContKind;
      value: Value;
      modifiers: Map<VarId, Value>;
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
  handlers: Map<ReqId, Thread>;
  scopeId: ScopeId;
  /**
   * Inherited (by reference) from the parent. The runner overwrites the
   * thread's `.boundaries` after creation if the new thread is itself a
   * boundary type.
   */
  boundaries: Boundaries;
};
