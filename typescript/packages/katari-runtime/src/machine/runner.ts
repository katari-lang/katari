import type { BlockId } from "../ir/types.js";
import { createThreadId, type ScopeId } from "./id.js";
import type { MachineState } from "./machine.js";
import { createScope } from "./scope.js";
import type { Value } from "./value.js";

import type {
  Boundaries,
  CallId,
  CreateThreadInit,
  Thread,
} from "./thread/types.js";
import { createPrimThread, onCallPrim } from "./thread/prim.js";
import { createCtorThread, onCallCtor } from "./thread/ctor.js";
import {
  createExternalThread,
  onCallExternal,
} from "./thread/external.js";
import {
  createArrayThread,
  onCallArray,
  onChildDoneArray,
} from "./thread/array.js";
import {
  createTupleThread,
  onCallTuple,
  onChildDoneTuple,
} from "./thread/tuple.js";
import {
  createMatchThread,
  onCallMatch,
  onChildDoneMatch,
} from "./thread/match.js";
import {
  createForThread,
  onCallFor,
  onChildCancelAckFor,
  onChildDoneFor,
  onContFor,
} from "./thread/for.js";
import {
  createUserThread,
  onCallUser,
  onChildDoneUser,
} from "./thread/user.js";
import {
  createHandleThread,
  onAskHandle,
  onCallHandle,
  onChildCancelAckHandle,
  onChildDoneHandle,
  onContHandle,
} from "./thread/handle.js";
import {
  createRequestThread,
  onAskCompleteRequest,
  onCallRequest,
} from "./thread/request.js";
import { finishCancellingAPI, onChildDoneAPI } from "./thread/api.js";

// ─── Main Loop ──────────────────────────────────────────────────────────────

/**
 * Process all queued events until the queue is empty.
 * The queue may grow during processing (handlers push new events).
 */
export function processQueue(machine: MachineState): void {
  while (machine.queue.length > 0) {
    const event = machine.queue.shift();
    if (event === undefined) break;

    switch (event.kind) {
      case "callBlock": {
        // Top-level callable. Allocate a fresh isolated scope (parent = null).
        const newScopeId = createScope(machine, null).id;
        const handlers = new Map(event.parent.handlers);
        spawnChild(machine, event.parent, event.callId, event.blockId, event.args, newScopeId, handlers);
        break;
      }

      case "callInline": {
        // Inline child of a structural block. Allocate a new scope under
        // the caller's current scope so that the inline body's `let`s do
        // not leak outward.
        // handlers: an explicit override (for HandleThread main-target spawn)
        // or a fresh copy of the parent's handlers (default inheritance).
        const newScopeId = createScope(machine, event.scopeId).id;
        const handlers = event.handlersOverride ?? new Map(event.parent.handlers);
        spawnChild(machine, event.parent, event.callId, event.blockId, event.args, newScopeId, handlers);
        break;
      }

      case "callValue": {
        // Closure call. New scope with parent = closure's captured scope.
        const newScopeId = createScope(machine, event.capturedScopeId).id;
        const handlers = new Map(event.parent.handlers);
        spawnChild(machine, event.parent, event.callId, event.blockId, event.args, newScopeId, handlers);
        break;
      }

      case "done": {
        const parent = event.parent;
        const child = parent.children.get(event.callId);
        if (!child) break; // stale (already cleaned up by cancel)
        parent.children.delete(event.callId);
        machine.threads.delete(child.id);
        if (parent.status === "cancelling") {
          checkAllChildrenDone(machine, parent);
        } else {
          dispatchOnChildDone(machine, parent, event.callId, event.value);
        }
        break;
      }

      case "return": {
        // Direct delivery to the boundary thread for `return` / `for_break`
        // / `break`. The boundary cancels its remaining children, then
        // emits done with `pendingReturn`.
        const target = event.target;
        if (!machine.threads.has(target.id)) break; // stale
        if (target.status === "cancelling") break;  // race with parent cancel — drop
        target.status = "cancelling";
        target.pendingReturn = event.value;
        if (target.children.size === 0) {
          finishCancelling(machine, target);
        } else {
          for (const child of target.children.values()) {
            machine.queue.push({ kind: "cancel", target: child });
          }
        }
        break;
      }

      case "cancel": {
        if (!machine.threads.has(event.target.id)) break; // stale
        handleCancelReceived(machine, event.target);
        break;
      }

      case "cancelAck": {
        const parent = event.parent;
        const child = parent.children.get(event.callId);
        if (!child) break; // stale
        parent.children.delete(event.callId);
        machine.threads.delete(child.id);
        if (parent.status === "cancelling") {
          checkAllChildrenDone(machine, parent);
        } else {
          // Targeted cancel completed while the parent itself is still
          // running (e.g., HandleThread cancelled one handler body for
          // a `next` resume). Dispatch to a per-kind hook that knows
          // what followup to perform.
          dispatchOnChildCancelAck(machine, parent, event.callId);
        }
        break;
      }

      case "ask": {
        const target = event.target;
        if (!machine.threads.has(target.id)) break; // stale
        if (target.kind !== "handle") {
          throw new Error(
            `processQueue.ask: target ${target.kind} not supported (only HandleThread)`,
          );
        }
        onAskHandle(
          machine,
          target,
          event.asker,
          event.askId,
          event.reqId,
          event.args,
        );
        break;
      }

      case "askComplete": {
        const target = event.target;
        if (!machine.threads.has(target.id)) break; // stale
        if (target.kind !== "request") {
          throw new Error(
            `processQueue.askComplete: target ${target.kind} is not a RequestThread`,
          );
        }
        onAskCompleteRequest(machine, target, event.askId, event.value);
        break;
      }

      case "cont": {
        const target = event.target;
        if (!machine.threads.has(target.id)) break; // stale
        // Race with parent cancel: if the boundary is already cancelling
        // (e.g., outer `break` reached this HandleThread before this
        // `next` did), the targeted children may already be gone. The
        // source thread will be cancelled via the boundary's cascade,
        // so we just drop the cont. Symmetric with the `return` race
        // handler above.
        if (target.status === "cancelling") break;
        switch (target.kind) {
          case "handle":
            onContHandle(machine, target, event.source, event.value, event.modifiers);
            break;
          case "for":
            onContFor(machine, target, event.source, event.contKind, event.modifiers);
            break;
          default:
            throw new Error(
              `processQueue.cont: target ${target.kind} cannot receive cont`,
            );
        }
        break;
      }
    }
  }
}

/**
 * Create a child thread with a pre-allocated scope + handlers map and
 * dispatch its onCall.
 */
function spawnChild(
  machine: MachineState,
  parent: Thread,
  callId: CallId,
  blockId: BlockId,
  args: Record<string, Value>,
  scopeId: ScopeId,
  handlers: Map<import("../ir/types.js").ReqId, Thread>,
): void {
  const child = createThread(machine, blockId, parent, callId, args, scopeId, handlers);
  parent.children.set(callId, child);
  dispatchOnCall(machine, child);
}

// ─── Cancel / Return ─────────────────────────────────────────────────────────

/**
 * Handle a cancel event targeting a specific thread.
 *
 * `cancel` is never directed at a root thread (APIThread) — root cancellation
 * is initiated by `handleTerminateFromAPI`, which propagates `cancel` to the
 * root's children directly. So `target` here is always a ChildThreadBase.
 */
function handleCancelReceived(machine: MachineState, target: Thread): void {
  if (target.kind === "api") {
    throw new Error("handleCancelReceived: APIThread is root and cannot be cancelled by a cancel event");
  }
  if (target.status === "cancelling") return; // idempotent
  target.status = "cancelling";

  // ExternalThread: emit terminate to FFI, wait for terminateAck
  if (target.kind === "external") {
    machine.pendingOutEvents.push({
      from: "CORE",
      to: "FFI",
      kind: "terminate",
      delegationId: target.delegationId,
    });
    return;
  }

  if (target.children.size === 0) {
    // Leaf thread — ack parent immediately
    machine.queue.push({
      kind: "cancelAck",
      parent: target.parent,
      callId: target.parentCallId,
    });
    return;
  }

  // Propagate cancel to all children
  for (const child of target.children.values()) {
    machine.queue.push({ kind: "cancel", target: child });
  }
}

/**
 * Check if all children are gone and finish cancelling if so.
 *
 * Roots (APIThread) take an api-specific finalisation path
 * (`finishCancellingAPI`); non-root threads use the generic
 * `finishCancelling` to emit done / cancelAck back up the tree.
 */
function checkAllChildrenDone(machine: MachineState, thread: Thread): void {
  if (thread.status !== "cancelling") return;
  if (thread.children.size > 0) return;
  if (thread.parent === null) {
    // APIThread is currently the only root thread kind. The discriminated
    // Thread union narrows to APIThread here.
    finishCancellingAPI(machine, thread);
    return;
  }
  finishCancelling(machine, thread);
}

/**
 * Final step for a cancelled NON-ROOT thread.
 * - With `pendingReturn` (= boundary that received a return event):
 *   emit done with the stored value to the parent.
 * - Without `pendingReturn` (= cancelled by parent's cascade):
 *   emit cancelAck to the parent.
 *
 * Root cancellation (APIThread) is handled by `finishCancellingAPI` in
 * `thread/api.ts` — its api-specific cleanup (terminateAck out-event,
 * apiDelegations bookkeeping) is unique to APIThread and lives there.
 */
export function finishCancelling(machine: MachineState, thread: Thread): void {
  if (thread.parent === null) {
    throw new Error(
      "finishCancelling: root thread should be finalised via its kind-specific path (e.g. finishCancellingAPI)",
    );
  }

  if (thread.pendingReturn !== undefined) {
    machine.queue.push({
      kind: "done",
      parent: thread.parent,
      callId: thread.parentCallId,
      value: thread.pendingReturn,
    });
  } else {
    machine.queue.push({
      kind: "cancelAck",
      parent: thread.parent,
      callId: thread.parentCallId,
    });
  }
}

// ─── Dispatch ───────────────────────────────────────────────────────────────

function dispatchOnCall(machine: MachineState, thread: Thread): void {
  switch (thread.kind) {
    case "prim":
      return onCallPrim(machine, thread);
    case "ctor":
      return onCallCtor(machine, thread);
    case "user":
      return onCallUser(machine, thread);
    case "array":
      return onCallArray(machine, thread);
    case "tuple":
      return onCallTuple(machine, thread);
    case "match":
      return onCallMatch(machine, thread);
    case "for":
      return onCallFor(machine, thread);
    case "api":
      throw new Error(
        "dispatchOnCall: APIThread is a root and must not be dispatched via call event",
      );
    case "handle":
      return onCallHandle(machine, thread);
    case "request":
      return onCallRequest(machine, thread);
    case "external":
      return onCallExternal(machine, thread);
  }
}

function dispatchOnChildDone(
  machine: MachineState,
  parent: Thread,
  callId: CallId,
  value: Value,
): void {
  switch (parent.kind) {
    case "user":
      return onChildDoneUser(machine, parent, callId, value);
    case "array":
      return onChildDoneArray(machine, parent, callId, value);
    case "tuple":
      return onChildDoneTuple(machine, parent, callId, value);
    case "match":
      return onChildDoneMatch(machine, parent, callId, value);
    case "for":
      return onChildDoneFor(machine, parent, callId, value);
    case "api":
      return onChildDoneAPI(machine, parent, callId, value);
    case "prim":
      throw new Error("dispatchOnChildDone: prim has no children");
    case "ctor":
      throw new Error("dispatchOnChildDone: ctor has no children");
    case "external":
      throw new Error("dispatchOnChildDone: external has no children");
    case "handle":
      return onChildDoneHandle(machine, parent, callId, value);
    case "request":
      throw new Error(
        "dispatchOnChildDone: RequestThread has no statement-level children",
      );
  }
}

/**
 * Hook called when a child of `parent` cancelAck'd while `parent` is
 * still in `running` state — typically because `parent` initiated a
 * targeted cancel (e.g., HandleThread cancelling one handler body for
 * a `next` resume; ForThread cancelling the body for `for_next`).
 *
 * Standard cancelAck handling (parent in `cancelling` state) is in
 * `processQueue.cancelAck` and goes through `checkAllChildrenDone`.
 */
function dispatchOnChildCancelAck(
  machine: MachineState,
  parent: Thread,
  callId: CallId,
): void {
  switch (parent.kind) {
    case "handle":
      return onChildCancelAckHandle(machine, parent, callId);
    case "for":
      return onChildCancelAckFor(machine, parent, callId);
    default:
      throw new Error(
        `dispatchOnChildCancelAck: unexpected cancelAck on ${parent.kind} thread while running`,
      );
  }
}

// ─── Create thread ──────────────────────────────────────────────────────────

/**
 * Create a child thread for a given blockId.
 * Dispatches to the appropriate module's create function.
 *
 * Boundaries: the child inherits parent's `boundaries` by reference (no
 * mutation downstream). After dispatch we examine the new thread; if it
 * is itself a boundary type (agent UserThread / ForThread / HandleThread)
 * we branch a new map with the relevant key(s) overridden to point at it.
 */
export function createThread(
  machine: MachineState,
  blockId: BlockId,
  parent: Thread,
  callId: CallId,
  args: Record<string, Value>,
  scopeId: ScopeId,
  handlers: Map<import("../ir/types.js").ReqId, Thread>,
): Thread {
  const block = machine.irModule.blocks[blockId];
  if (!block) {
    throw new Error(`createThread: blockId ${blockId} not found in IR`);
  }

  const init: CreateThreadInit = {
    id: createThreadId(),
    parent,
    parentCallId: callId,
    // Caller (processQueue) is responsible for copying / augmenting the
    // handlers map; we just store the reference it gave us.
    handlers,
    scopeId,
    // Share parent's boundaries by reference. Override below if needed.
    boundaries: parent.boundaries,
  };

  const thread = dispatchCreate(machine, init, block, args);

  const overrides = computeSelfBoundaryOverrides(thread);
  if (overrides !== null) {
    thread.boundaries = { ...parent.boundaries, ...overrides };
  }

  return thread;
}

function dispatchCreate(
  machine: MachineState,
  init: CreateThreadInit,
  block: import("../ir/types.js").Block,
  args: Record<string, Value>,
): Thread {
  switch (block.kind) {
    case "blockUser":
      return createUserThread(machine, init, block.body, args);
    case "blockPrim":
      return createPrimThread(machine, init, block.name, args);
    case "blockCtor":
      return createCtorThread(machine, init, block.ctorId, args);
    case "blockExternal":
      return createExternalThread(machine, init, block.externalName, args);
    case "blockMatch":
      return createMatchThread(machine, init, block.matchBlock);
    case "blockFor":
      return createForThread(machine, init, block.forBlock);
    case "blockHandle":
      return createHandleThread(machine, init, block.handleBlock);
    case "blockTuple":
      return createTupleThread(machine, init, block.tupleBlock);
    case "blockArray":
      return createArrayThread(machine, init, block.arrayBlock);
    case "blockRequest":
      return createRequestThread(machine, init, block.reqId, args);
  }
}

/**
 * If `thread` is a boundary type, return the keys of `boundaries` it
 * should claim. Otherwise return null and the inherited boundaries are
 * used as-is.
 */
function computeSelfBoundaryOverrides(thread: Thread): Partial<Boundaries> | null {
  if (thread.kind === "user" && thread.block.kind === "blockKindAgent") {
    return { exitKindReturn: thread };
  }
  if (thread.kind === "for") {
    return { exitKindForBreak: thread, contKindForNext: thread };
  }
  if (thread.kind === "handle") {
    return { exitKindBreak: thread, contKindNext: thread };
  }
  return null;
}
