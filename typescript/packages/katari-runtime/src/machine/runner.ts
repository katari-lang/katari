import type { BlockId, ExitKind } from "../ir/types.js";
import { createThreadId, type ScopeId } from "./id.js";
import type { MachineState } from "./machine.js";
import type { Value } from "./value.js";

import type { CallId, CreateThreadInit, Thread } from "./thread/types.js";
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
import { onCallAPI, onChildDoneAPI } from "./thread/api.js";

// ─── Main Loop ──────────────────────────────────────────────────────────────

/**
 * Process all queued events until the queue is empty.
 * The queue may grow during processing (handlers push new events).
 */
export function processQueue(machine: MachineState): void {
  while (machine.queue.length > 0) {
    const event = machine.queue.shift()!;

    switch (event.kind) {
      case "call": {
        const child = createThread(
          machine,
          event.blockId,
          event.parent,
          event.callId,
          event.args,
          event.scopeId,
        );
        event.parent.children.set(event.callId, child);
        dispatchOnCall(machine, child);
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
        const parent = event.parent;
        const child = parent.children.get(event.callId);
        if (!child) break; // stale
        parent.children.delete(event.callId);
        machine.threads.delete(child.id);
        if (parent.status === "cancelling") {
          // Already cancelling — treat return as implicit cancelAck
          checkAllChildrenDone(machine, parent);
        } else {
          handleReturnReceived(machine, parent, event.value, event.exitKind);
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

// ─── Cancel / Return ─────────────────────────────────────────────────────────

/**
 * Handle a cancel event targeting a specific thread.
 */
function handleCancelReceived(machine: MachineState, target: Thread): void {
  if (target.status === "cancelling") return; // idempotent
  target.status = "cancelling";

  // ExternalThread: emit terminate to FFI, wait for terminateAck
  if (target.kind === "external") {
    machine.outEvents.push({
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
      parent: target.parent!,
      callId: target.parentCallId!,
    });
    return;
  }

  // Propagate cancel to all children
  for (const child of target.children.values()) {
    machine.queue.push({ kind: "cancel", target: child });
  }
}

/**
 * Handle a return event received by a parent thread.
 * Cancels remaining children and prepares to propagate or convert to done.
 */
function handleReturnReceived(
  machine: MachineState,
  parent: Thread,
  value: Value,
  exitKind: ExitKind,
): void {
  parent.status = "cancelling";
  parent.pendingReturn = value;
  parent.pendingExitKind = isBoundaryFor(parent, exitKind) ? undefined : exitKind;

  if (parent.children.size === 0) {
    // No remaining children to cancel
    finishCancelling(machine, parent);
    return;
  }

  // Cancel all remaining children
  for (const child of parent.children.values()) {
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
 * Emits the appropriate event (done, return, cancelAck, or terminateAck).
 */
export function finishCancelling(machine: MachineState, thread: Thread): void {
  // Root thread (APIThread) — emit terminateAck and clean up
  if (thread.parent === null) {
    if (thread.kind === "api") {
      machine.outEvents.push({
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
    if (thread.pendingExitKind !== undefined) {
      // Non-boundary: propagate return upward
      machine.queue.push({
        kind: "return",
        parent: thread.parent,
        callId: thread.parentCallId!,
        value: thread.pendingReturn,
        exitKind: thread.pendingExitKind,
      });
    } else {
      // Boundary: convert to done
      machine.queue.push({
        kind: "done",
        parent: thread.parent,
        callId: thread.parentCallId!,
        value: thread.pendingReturn,
      });
    }
  } else {
    // Cancelled by parent — ack
    machine.queue.push({
      kind: "cancelAck",
      parent: thread.parent,
      callId: thread.parentCallId!,
    });
  }
}

/**
 * Determine if a thread is the boundary for a given exit kind.
 */
function isBoundaryFor(thread: Thread, exitKind: ExitKind): boolean {
  switch (exitKind) {
    case "exitKindReturn":
      return thread.kind === "user" && thread.block.kind === "blockKindAgent";
    case "exitKindForBreak":
      return thread.kind === "for";
    case "exitKindBreak":
      return thread.kind === "handle";
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
      return onCallAPI(machine, thread);
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
    handlers: parent.handlers,
    scopeId,
  };

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
