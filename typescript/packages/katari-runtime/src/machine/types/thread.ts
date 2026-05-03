import { BlockId, ReqId, VarId } from "../../ir/types.js";
import { ThreadId, ScopeId, WaitId } from "./id.js";
import { Value } from "./value.js";

/**
 * Records why and how this Thread was created.
 * Stored on the child Thread itself (not on the parent's map).
 *
 * - invoke           : top-level Invoke event (parentThreadId = null)
 * - call             : StatementCall at statementIndex in parent block
 * - matchArm         : StatementMatch at statementIndex, arm armIndex chosen
 * - forIteration     : StatementFor at statementIndex, iterationIndex-th element
 * - handlerInvocation: handler for reqId fired, state version = version
 */
export type ThreadOrigin =
  | { kind: "invoke" } // from API or FFI
  | { kind: "call"; statementIndex: number }
  | { kind: "matchArm"; statementIndex: number; armIndex: number }
  | { kind: "forIteration"; statementIndex: number; iterationIndex: number }
  | { kind: "handlerInvocation"; reqId: ReqId; version: number };

export type HandlerEntry = {
  blockId: BlockId;
  threadId: ThreadId;
};

export type ThreadStatus = "running" | "cancelling" | "cancelled";

export type Thread = {
  id: ThreadId;
  blockId: BlockId;
  arguments: Map<string, Value>;
  /**
   * Lexical scope (variable lookup origin).
   * Usually matches the parent thread's scope, but diverges for closures:
   * a closure body thread's scopeId parent is the captured scope,
   * not the caller's scope.
   */
  scopeId: ScopeId;
  /** Execution tree parent (dynamic). */
  parentThreadId: ThreadId | null;
  /** How this Thread was created. */
  origin: ThreadOrigin;
  childThreads: Set<{
    childThreadId: ThreadId;
    childOrigin: ThreadOrigin;
  }>;
  /**
   * Handlers inherited from the parent at thread creation time.
   * This is the SSoT for what a handler body thread should inherit:
   * when a BlockHandler fires a handler, the body thread receives
   * the BlockHandler thread's parentHandlers (not its ownHandlers),
   * so the handler body cannot recursively trigger the same where-clause.
   */
  parentHandlers: Map<ReqId, HandlerEntry>;
  /**
   * Handlers registered by this thread's block (BlockHandler only).
   * Merged with parentHandlers to form the effective handler set
   * visible to child threads spawned from this thread.
   */
  ownHandlers: Map<ReqId, HandlerEntry>;
  status: ThreadStatus;

  // for variables
  // null = version 0
  varVersions: Map<VarId, number>;
};
