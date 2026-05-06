import type { Block, BlockId, ReqId } from "../ir/types.js";
import { createThreadId, type ScopeId } from "./id.js";
import type { MachineState } from "./machine.js";
import { createScope } from "./scope.js";
import type { Value } from "./value.js";

import type { CallId, ChildThreadInit, Thread } from "./thread/types.js";
import { PrimThread } from "./thread/prim.js";
import { CtorThread } from "./thread/ctor.js";
import { ExternalThread } from "./thread/external.js";
import { ArrayThread } from "./thread/array.js";
import { TupleThread } from "./thread/tuple.js";
import { MatchThread } from "./thread/match.js";
import { ForThread } from "./thread/for.js";
import { UserThread } from "./thread/user.js";
import { HandleThread } from "./thread/handle.js";
import { RequestThread } from "./thread/request.js";

// ─── Main loop ──────────────────────────────────────────────────────────────

/**
 * Process all queued events until the queue is empty.
 *
 * Every case dispatches via virtual methods on the target / parent thread —
 * there is no kind-based switch left here. Variant-specific logic lives on
 * the Thread subclasses (template methods + variant hooks in the base).
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

      case "done":
        event.parent.onChildDoneFromRunner(machine, event.callId, event.value);
        break;

      case "cancelAck":
        event.parent.onChildCancelAckFromRunner(machine, event.callId);
        break;

      case "return":
        if (!machine.threads.has(event.target.id)) break; // stale
        event.target.onReturnReceived(machine, event.value);
        break;

      case "cancel":
        if (!machine.threads.has(event.target.id)) break; // stale
        event.target.onCancelReceived(machine);
        break;

      case "ask":
        if (!machine.threads.has(event.target.id)) break; // stale
        event.target.onAsk(
          machine,
          event.asker,
          event.askId,
          event.reqId,
          event.args,
        );
        break;

      case "askComplete":
        if (!machine.threads.has(event.target.id)) break; // stale
        event.target.onAskComplete(machine, event.askId, event.value);
        break;

      case "cont":
        if (!machine.threads.has(event.target.id)) break; // stale
        event.target.onCont(
          machine,
          event.source,
          event.contKind,
          event.value,
          event.modifiers,
        );
        break;
    }
  }
}

// ─── Spawn / factory ────────────────────────────────────────────────────────

/**
 * Construct a fresh child for `parent`, register it in machine state, and
 * dispatch its `onCall`. Used by all three call-event cases.
 *
 * The factory below is the single remaining `block.kind` switch in the
 * runtime — IR consumption inherently requires it.
 */
function spawnChild(
  machine: MachineState,
  parent: Thread,
  callId: CallId,
  blockId: BlockId,
  args: Record<string, Value>,
  scopeId: ScopeId,
  handlers: ReadonlyMap<ReqId, Thread>,
): void {
  const block = machine.irModule.blocks[blockId];
  if (block === undefined) {
    throw new Error(`spawnChild: blockId ${blockId} not found in IR`);
  }

  const init: ChildThreadInit = {
    id: createThreadId(),
    parent,
    parentCallId: callId,
    handlers,
    scopeId,
    // Inherit parent's boundaries. Boundary-type subclasses (UserThread for
    // agent blocks, ForThread, HandleThread) overwrite the relevant slots
    // in their own constructor.
    boundaries: parent.boundariesView,
  };

  const child = createThreadFromBlock(machine, init, block, args);
  machine.threads.set(child.id, child);
  parent.adoptChild(machine, callId, child);
}

function createThreadFromBlock(
  machine: MachineState,
  init: ChildThreadInit,
  block: Block,
  args: Record<string, Value>,
): Thread {
  switch (block.kind) {
    case "blockUser":
      return new UserThread(machine, init, block.body, args);
    case "blockPrim":
      return new PrimThread(init, block.name, args);
    case "blockCtor":
      return new CtorThread(init, block.ctorId, args);
    case "blockExternal":
      return new ExternalThread(init, block.externalName, args);
    case "blockMatch":
      return new MatchThread(init, block.matchBlock);
    case "blockFor":
      return new ForThread(machine, init, block.forBlock);
    case "blockHandle":
      return new HandleThread(machine, init, block.handleBlock);
    case "blockTuple":
      return new TupleThread(init, block.tupleBlock);
    case "blockArray":
      return new ArrayThread(init, block.arrayBlock);
    case "blockRequest":
      return new RequestThread(init, block.reqId, args);
  }
}
