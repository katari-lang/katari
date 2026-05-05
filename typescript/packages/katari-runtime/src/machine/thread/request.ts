import type { ReqId } from "../../ir/types.js";
import type { AskId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { ChildThreadBase, CreateThreadInit } from "./types.js";

/**
 * Executes a BlockRequest. Issues a single `ask` to the registered
 * handler-owning thread (looked up via `handlers[reqId]`), then waits
 * for the matching `askComplete` to come back.
 *
 * Lifecycle:
 *   onCall   → emit `ask` to handlers[reqId], record pendingAskId
 *   askComplete (matching askId) → emit `done` with the resume value
 *
 * RequestThread has no statements of its own and never spawns children.
 */
export type RequestThread = ChildThreadBase & {
  kind: "request";
  reqId: ReqId;
  args: Record<string, Value>;
  /** Allocated by onCallRequest; matches the `askComplete` reply. */
  pendingAskId?: AskId;
};

export function createRequestThread(
  machine: MachineState,
  init: CreateThreadInit,
  reqId: ReqId,
  args: Record<string, Value>,
): RequestThread {
  const thread: RequestThread = {
    ...init,
    kind: "request",
    children: new Map(),
    status: "running",
    reqId,
    args,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

/**
 * RequestThread asks at most once in its entire lifetime, so its AskId
 * is always 0. The (asker, askId) pair is unique because `asker` (this
 * thread) is unique. Other asker kinds (future external agents) that
 * may issue multiple asks will keep their own per-asker counter.
 */
const REQUEST_ASK_ID = 0 as AskId;

export function onCallRequest(machine: MachineState, thread: RequestThread): void {
  const handler = thread.handlers.get(thread.reqId);
  if (handler === undefined) {
    throw new Error(
      `onCallRequest: no handler registered for reqId ${thread.reqId}`,
    );
  }
  thread.pendingAskId = REQUEST_ASK_ID;
  machine.queue.push({
    kind: "ask",
    target: handler,
    asker: thread,
    askId: REQUEST_ASK_ID,
    reqId: thread.reqId,
    args: thread.args,
  });
}

/**
 * Handle the askComplete reply for this thread.
 * Validates that the askId matches what we sent, then emits `done` to
 * our parent so the calling UserThread can pick the value up via
 * onChildDoneUser.
 */
export function onAskCompleteRequest(
  machine: MachineState,
  thread: RequestThread,
  askId: AskId,
  value: Value,
): void {
  if (thread.pendingAskId !== askId) {
    throw new Error(
      `onAskCompleteRequest: askId mismatch (expected ${thread.pendingAskId}, got ${askId})`,
    );
  }
  machine.queue.push({
    kind: "done",
    parent: thread.parent,
    callId: thread.parentCallId,
    value,
  });
}
