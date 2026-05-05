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
import { createForThread, onCallFor, onChildDoneFor } from "./thread/for.js";
import {
  createUserThread,
  onCallUser,
  onChildDoneUser,
} from "./thread/user.js";
import { createHandleThread } from "./thread/handle.js";
import { createRequestThread } from "./thread/request.js";
import { onChildDoneAPI } from "./thread/api.js";

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
        spawnChild(machine, event.parent, event.callId, event.blockId, event.args, newScopeId);
        break;
      }

      case "callInline": {
        // Inline child of a structural block. Allocate a new scope under
        // the caller's current scope so that the inline body's `let`s do
        // not leak outward.
        const newScopeId = createScope(machine, event.scopeId).id;
        spawnChild(machine, event.parent, event.callId, event.blockId, event.args, newScopeId);
        break;
      }

      case "callValue": {
        // Closure call. New scope with parent = closure's captured scope.
        const newScopeId = createScope(machine, event.capturedScopeId).id;
        spawnChild(machine, event.parent, event.callId, event.blockId, event.args, newScopeId);
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
        checkAllChildrenDone(machine, parent);
        break;
      }
    }
  }
}

/**
 * Create a child thread with a pre-allocated scope and dispatch its onCall.
 */
function spawnChild(
  machine: MachineState,
  parent: Thread,
  callId: CallId,
  blockId: BlockId,
  args: Map<string, Value>,
  scopeId: ScopeId,
): void {
  const child = createThread(machine, blockId, parent, callId, args, scopeId);
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
 */
function checkAllChildrenDone(machine: MachineState, thread: Thread): void {
  if (thread.status !== "cancelling") return;
  if (thread.children.size > 0) return;
  finishCancelling(machine, thread);
}

/**
 * Called when a cancelling thread has no more children.
 * - Root (APIThread): emit terminateAck and clean up.
 * - Non-root with `pendingReturn` (= boundary that received a return event):
 *   emit done with the stored value.
 * - Non-root without `pendingReturn` (= cancelled by parent's cascade):
 *   emit cancelAck to parent.
 */
export function finishCancelling(machine: MachineState, thread: Thread): void {
  if (thread.parent === null) {
    if (thread.kind === "api") {
      machine.pendingOutEvents.push({
        from: "CORE",
        to: "API",
        kind: "terminateAck",
        delegationId: thread.delegationId,
      });
      machine.apiDelegations.delete(thread.delegationId);
    }
    machine.threads.delete(thread.id);
    return;
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
      throw new Error("dispatchOnCall: handle not implemented");
    case "request":
      throw new Error("dispatchOnCall: request not implemented");
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
      throw new Error("dispatchOnChildDone: handle not implemented");
    case "request":
      throw new Error("dispatchOnChildDone: request not implemented");
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
  args: Map<string, Value>,
  scopeId: ScopeId,
): Thread {
  const block = machine.irModule.blocks[blockId];
  if (!block) {
    throw new Error(`createThread: blockId ${blockId} not found in IR`);
  }

  const init: CreateThreadInit = {
    id: createThreadId(),
    parent,
    parentCallId: callId,
    // Copy parent's handlers so child mutations (handle implementation) do
    // not leak back to the parent's map.
    handlers: new Map(parent.handlers),
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
  args: Map<string, Value>,
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
