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

// Re-export imported HandleThread type for the spawnChild signature; keeps
// the direct dependency explicit at the use site.

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
        if (!machine.threads.has(event.target.id)) {
          machine.logger.log("debug", "runner: stale return event dropped", {
            targetId: event.target.id,
          });
          break;
        }
        event.target.onReturnReceived(machine, event.value);
        break;

      case "cancel":
        if (!machine.threads.has(event.target.id)) {
          machine.logger.log("debug", "runner: stale cancel event dropped", {
            targetId: event.target.id,
          });
          break;
        }
        event.target.onCancelReceived(machine);
        break;

      case "ask":
        if (!machine.threads.has(event.target.id)) {
          machine.logger.log("debug", "runner: stale ask event dropped", {
            targetId: event.target.id,
            askId: event.askId,
          });
          break;
        }
        event.target.onAsk(
          machine,
          event.asker,
          event.askId,
          event.reqId,
          event.args,
        );
        break;

      case "askComplete":
        if (!machine.threads.has(event.target.id)) {
          machine.logger.log("debug", "runner: stale askComplete event dropped", {
            targetId: event.target.id,
            askId: event.askId,
          });
          break;
        }
        event.target.onAskComplete(machine, event.askId, event.value);
        break;

      case "cont":
        if (!machine.threads.has(event.target.id)) {
          machine.logger.log("debug", "runner: stale cont event dropped", {
            targetId: event.target.id,
            contKind: event.contKind,
          });
          break;
        }
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
  handlers: ReadonlyMap<ReqId, HandleThread>,
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

  const child = createThreadFromBlock(machine, init, block, blockId, args);
  machine.threads.set(child.id, child);
  parent.adoptChild(machine, callId, child);
}

function createThreadFromBlock(
  machine: MachineState,
  init: ChildThreadInit,
  block: Block,
  blockId: BlockId,
  args: Record<string, Value>,
): Thread {
  switch (block.kind) {
    case "blockUser":
      return new UserThread(machine, init, block.body, blockId, args);
    case "blockPrim":
      return new PrimThread(init, block.body, args);
    case "blockConstructor":
      return new CtorThread(init, block.body, args);
    case "blockExternal":
      return new ExternalThread(init, block.body, args);
    case "blockMatch":
      return new MatchThread(init, block.body, blockId);
    case "blockFor":
      return new ForThread(machine, init, block.body, blockId);
    case "blockHandle":
      return new HandleThread(machine, init, block.body, blockId);
    case "blockTuple":
      return new TupleThread(init, block.body, blockId);
    case "blockArray":
      return new ArrayThread(init, block.body, blockId);
    case "blockRequest":
      return new RequestThread(init, block.body, args);
  }
}
