import type { HandleBlock, ReqId, VarId } from "../../ir/types.js";
import type { AskId } from "../id.js";
import type { MachineState } from "../machine.js";
import { finishCancelling } from "../runner.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import type { Value } from "../value.js";
import type { CallId, ChildThreadBase, CreateThreadInit, Thread } from "./types.js";

/**
 * BlockHandle: an algebraic-effect handler scope.
 *
 * Children are one of three roles, tracked via `childRoles`:
 *   - main  (callId = 0) — the body the handler block guards.
 *   - handlerBody (callId ≥ 1) — a handler body spawned in response
 *     to an `ask`. Bound to a specific `(asker, askId, reqId)`.
 *   - thenClause (callId ≥ 1) — the optional `then(r) { ... }` clause
 *     run after the main target completes successfully.
 *
 * Two state-machines guide the lifecycle:
 *
 *   1. **Sequential queue.** When `block.parallel === false`, only one
 *      handler-body / thenClause runs at a time. New asks and the
 *      then-clause activation are queued in `pendingActions` and dequeued
 *      as the currently-running child finishes.
 *
 *   2. **Per-child post-cancel actions.** When `next` resumes a handler,
 *      we cancel only that one handler-body without putting the whole
 *      HandleThread into "cancelling" state. After the cancelled child
 *      acks, we look up `postCancelActions[callId]` and execute it
 *      (typically: emit `askComplete` to the asker, then pop the queue).
 *
 * `break` and "thenClause done" reuse the existing return-event
 * machinery: HandleThread enters status="cancelling" with `pendingReturn`
 * set, all children are cancelled, and finishCancelling emits `done` to
 * the parent.
 */
export type HandleThread = ChildThreadBase & {
  kind: "handle";
  block: HandleBlock;
  childRoles: Map<CallId, ChildRole>;
  pendingActions: PendingAction[];
  postCancelActions: Map<CallId, PostCancelAction>;
  /** CallId allocator for non-main children. main is reserved as 0. */
  nextCallId: CallId;
  /**
   * In sequential mode, true while a handler-body or thenClause is in
   * flight. New asks queue while busy. Parallel mode keeps this false
   * (every ask spawns immediately).
   */
  busy: boolean;
};

export type ChildRole =
  | { kind: "main" }
  | { kind: "handlerBody"; reqId: ReqId; askId: AskId; asker: Thread }
  | { kind: "thenClause"; mainResultValue: Value };

export type PendingAction =
  | { kind: "ask"; reqId: ReqId; args: Record<string, Value>; asker: Thread; askId: AskId }
  | { kind: "thenClause"; mainResultValue: Value };

export type PostCancelAction =
  | { kind: "askComplete"; asker: Thread; askId: AskId; value: Value };

const MAIN_CALL_ID = 0 as CallId;

// ─── create / onCall ────────────────────────────────────────────────────────

export function createHandleThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: HandleBlock,
): HandleThread {
  // Initialize state variables in the handle scope from the caller scope.
  // The caller scope is reachable via the parent chain (init.scopeId is
  // a fresh scope under the caller's scope, per callInline mechanics).
  for (const [bodyVar, initVar] of block.stateInits) {
    const initValue = getValueFromScope(machine, init.scopeId, initVar);
    setValueInScope(machine, init.scopeId, bodyVar, initValue);
  }

  const thread: HandleThread = {
    ...init,
    kind: "handle",
    children: new Map(),
    status: "running",
    block,
    childRoles: new Map(),
    pendingActions: [],
    postCancelActions: new Map(),
    nextCallId: 1 as CallId,
    busy: false,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallHandle(machine: MachineState, thread: HandleThread): void {
  // Spawn the main target. Augment handlers with this handle's own
  // overrides so the body's requests are caught here. handler-body and
  // thenClause spawns NEVER add this augmentation — they see the outer
  // handlers (algebraic effect semantics).
  thread.childRoles.set(MAIN_CALL_ID, { kind: "main" });
  const augmented = new Map(thread.handlers);
  for (const handler of thread.block.handlers) {
    augmented.set(handler.request, thread);
  }
  machine.queue.push({
    kind: "callInline",
    parent: thread,
    callId: MAIN_CALL_ID,
    blockId: thread.block.body,
    args: {},
    scopeId: thread.scopeId,
    handlersOverride: augmented,
  });
}

// ─── ask handling ───────────────────────────────────────────────────────────

export function onAskHandle(
  machine: MachineState,
  thread: HandleThread,
  asker: Thread,
  askId: AskId,
  reqId: ReqId,
  args: Record<string, Value>,
): void {
  const action: PendingAction = { kind: "ask", reqId, args, asker, askId };
  if (thread.block.parallel || !thread.busy) {
    runPendingAction(machine, thread, action);
  } else {
    thread.pendingActions.push(action);
  }
}

/**
 * Spawn the child for `action`. In sequential mode this is gated by
 * `busy === false`; in parallel mode it can run any number of times
 * concurrently.
 */
function runPendingAction(
  machine: MachineState,
  thread: HandleThread,
  action: PendingAction,
): void {
  switch (action.kind) {
    case "ask":
      spawnHandlerBody(machine, thread, action);
      break;
    case "thenClause":
      spawnThenClause(machine, thread, action.mainResultValue);
      break;
  }
}

function spawnHandlerBody(
  machine: MachineState,
  thread: HandleThread,
  action: { reqId: ReqId; args: Record<string, Value>; asker: Thread; askId: AskId },
): void {
  const handler = thread.block.handlers.find((h) => h.request === action.reqId);
  if (handler === undefined) {
    throw new Error(
      `spawnHandlerBody: no handler for reqId ${action.reqId} in this handle block`,
    );
  }
  const callId = thread.nextCallId++ as CallId;
  thread.childRoles.set(callId, {
    kind: "handlerBody",
    reqId: action.reqId,
    askId: action.askId,
    asker: action.asker,
  });
  thread.busy = !thread.block.parallel;
  // No handlersOverride — the body inherits this HandleThread's handlers,
  // which deliberately do NOT include this handle's own overrides.
  machine.queue.push({
    kind: "callInline",
    parent: thread,
    callId,
    blockId: handler.handlerBody,
    args: action.args,
    scopeId: thread.scopeId,
  });
}

function spawnThenClause(
  machine: MachineState,
  thread: HandleThread,
  mainResultValue: Value,
): void {
  if (thread.block.thenBlock === undefined) {
    // No `then` clause: the main result is the handle's value directly.
    // Reuse the return-mechanism finish path: pendingReturn + cancel of
    // remaining children, then finishCancelling emits done. Children at
    // this point are only the queued/running handler bodies (if any).
    enterCancellingForResult(machine, thread, mainResultValue);
    return;
  }
  const callId = thread.nextCallId++ as CallId;
  thread.childRoles.set(callId, { kind: "thenClause", mainResultValue });
  thread.busy = !thread.block.parallel;
  machine.queue.push({
    kind: "callInline",
    parent: thread,
    callId,
    blockId: thread.block.thenBlock,
    args: { value: mainResultValue },
    scopeId: thread.scopeId,
  });
}

// ─── cont (next) handling ───────────────────────────────────────────────────

export function onContHandle(
  machine: MachineState,
  thread: HandleThread,
  source: Thread,
  value: Value,
  modifiers: Map<VarId, Value>,
): void {
  // Apply state-var modifiers to the handle scope.
  for (const [targetVar, newValue] of modifiers) {
    setValueInScope(machine, thread.scopeId, targetVar, newValue);
  }

  // Find which immediate child of `thread` is the ancestor of `source`.
  const childCallId = findImmediateChildCallId(thread, source);
  const role = thread.childRoles.get(childCallId);
  if (role === undefined || role.kind !== "handlerBody") {
    throw new Error(
      `onContHandle: source's owning child is not a handlerBody (callId=${childCallId})`,
    );
  }

  // Schedule askComplete to fire after the handler body has cancelled,
  // then send the cancel.
  thread.postCancelActions.set(childCallId, {
    kind: "askComplete",
    asker: role.asker,
    askId: role.askId,
    value,
  });
  const childThread = thread.children.get(childCallId);
  if (childThread === undefined) {
    throw new Error(
      `onContHandle: no live child at callId ${childCallId}`,
    );
  }
  machine.queue.push({ kind: "cancel", target: childThread });
}

/**
 * Walk `source.parent` chain until we hit a thread whose parent is `handle`.
 * That thread is the immediate child of `handle` on the path from `source`.
 */
function findImmediateChildCallId(handle: HandleThread, source: Thread): CallId {
  let cur: Thread | null = source;
  while (cur !== null) {
    if (cur.parent === handle && cur.parentCallId !== null) {
      return cur.parentCallId;
    }
    cur = cur.parent;
  }
  throw new Error(
    "findImmediateChildCallId: source is not a descendant of handle",
  );
}

// ─── done handling ──────────────────────────────────────────────────────────

export function onChildDoneHandle(
  machine: MachineState,
  thread: HandleThread,
  callId: CallId,
  value: Value,
): void {
  const role = thread.childRoles.get(callId);
  if (role === undefined) {
    throw new Error(`onChildDoneHandle: no role for callId ${callId}`);
  }
  thread.childRoles.delete(callId);

  switch (role.kind) {
    case "main": {
      // Enqueue thenClause execution. In sequential mode if a handler is
      // still running we wait; otherwise dispatch immediately.
      const action: PendingAction = { kind: "thenClause", mainResultValue: value };
      if (thread.block.parallel || !thread.busy) {
        runPendingAction(machine, thread, action);
      } else {
        thread.pendingActions.push(action);
      }
      return;
    }
    case "handlerBody":
      throw new Error(
        "onChildDoneHandle: handler body finished without break/next (must end with one of them)",
      );
    case "thenClause":
      // thenClause finished. Cancel all remaining children, then emit
      // `done` to our parent with the thenClause's result.
      enterCancellingForResult(machine, thread, value);
      return;
  }
}

// ─── cancelAck handling (post-cancel followups) ─────────────────────────────

export function onChildCancelAckHandle(
  machine: MachineState,
  thread: HandleThread,
  callId: CallId,
): void {
  thread.childRoles.delete(callId);
  const action = thread.postCancelActions.get(callId);
  if (action === undefined) {
    // No registered followup. Should not happen in current design.
    throw new Error(
      `onChildCancelAckHandle: no postCancelAction for callId ${callId}`,
    );
  }
  thread.postCancelActions.delete(callId);
  switch (action.kind) {
    case "askComplete":
      machine.queue.push({
        kind: "askComplete",
        target: action.asker,
        askId: action.askId,
        value: action.value,
      });
      // Free the busy slot and dispatch the next pending action if any.
      thread.busy = false;
      const next = thread.pendingActions.shift();
      if (next !== undefined) {
        runPendingAction(machine, thread, next);
      }
      return;
  }
}

// ─── helpers ────────────────────────────────────────────────────────────────

/**
 * Mark this handle as "cancelling, will emit done with `value`". Used by
 * thenClause-done and break (the latter via the return event in
 * processQueue). Cancels any remaining children; once they're all gone
 * `checkAllChildrenDone` calls `finishCancelling` which emits done with
 * `pendingReturn`. If there are already no children we call
 * `finishCancelling` directly to skip the cancel/cancelAck round-trip.
 *
 * HandleThread is always non-root (ChildThreadBase), so calling
 * `finishCancelling` here is safe — no APIThread can flow through.
 */
function enterCancellingForResult(
  machine: MachineState,
  thread: HandleThread,
  value: Value,
): void {
  thread.status = "cancelling";
  thread.pendingReturn = value;
  if (thread.children.size === 0) {
    finishCancelling(machine, thread);
    return;
  }
  for (const child of thread.children.values()) {
    machine.queue.push({ kind: "cancel", target: child });
  }
}

