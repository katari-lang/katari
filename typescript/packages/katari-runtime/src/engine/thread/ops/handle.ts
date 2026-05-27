// HandleThread ops — algebraic-effect handler.
//
// Catches the asks it owns (`request` for any reqId in block.handlers,
// `next` likewise, and `break`); proxies everything else upward.
//
// Children fall into three roles:
//   - main (callId = 0): the body block the handle wraps
//   - handlerBody (callId ≥ 1): a handler invocation in response to a
//     caught `request` ask. Each carries the (askId, askerCallId) of the
//     original ask so we can ack the asker chain when the handler resumes.
//   - thenClause (callId ≥ 1): the optional `then(r) { ... }` clause run
//     after main completes. It runs in our scope.
//
// Sequential mode (`block.parallel === false`) serializes handler bodies
// + thenClause via `pendingActions`. Parallel mode bypasses the queue.
//
// `next` is a targeted cancel: we cancel only the handler body that
// originated the next ask, then fire `askAck` to the original asker
// chain — leaving sibling handler bodies and the main untouched. Done
// via `postCancelActions[handlerBodyCallId] = { kind: "askComplete", ... }`.
//
// `break` is the same return-mechanism as agent UserThread: cancel all
// children, finishCancelling emits `done` with `pendingReturn`.

import type { Block, BlockId, HandleBlock, QualifiedName } from "../../../ir/types.js";
import type { AskId, CallId, } from "../../id.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import {
  allocCallId,
  beginCancel,
  commonRemoveChild,
  hasChildren,
  lookupValue,
  proxyAskToParent,
  setValueInScope,
  writeArgsIntoChildScope,
} from "../common.js";
import type {
  HandleThread,
  PendingAction,
} from "../types.js";
import {
  defaultAskAckProxy,
  defaultCancel,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const handleOps: ThreadOps<HandleThread> = {
  create(ctx, t) {
    const block = getHandleBlock(ctx, t.blockId);

    // Initialize state vars in our own scope from the caller scope (the
    // caller scope is reachable via the inline parent chain).
    for (const [bodyVar, initVar] of block.stateInits) {
      const v = lookupValue(ctx, t.scopeId, initVar);
      setValueInScope(ctx, t.scopeId, bodyVar, v);
    }

    // Allocate the main body's CallId from the shared counter. Role
    // discrimination lives in `childRoles` — no magic CallId reserved.
    const mainCallId = allocCallId(t);
    t.childRoles[mainCallId] = { kind: "main" };
    spawnChild(ctx, {
      parentId: t.id,
      parentCallId: mainCallId,
      blockId: block.body,
      callArgs: {},
      scopeMode: { mode: "inline", parentScopeId: t.scopeId },
    });
  },

  done(ctx, t, callId, value) {
    const role = t.childRoles[callId];
    if (!commonRemoveChild(ctx, t as HandleThread, callId)) return;
    if (role === undefined) return;
    delete t.childRoles[callId];

    switch (role.kind) {
      case "main": {
        // Main finished — schedule the thenClause (or its absence).
        const action: PendingAction = { kind: "thenClause", mainResultValue: value };
        if (isParallel(ctx, t.blockId) || !isBusy(t)) {
          runAction(ctx, t as HandleThread, action);
        } else {
          t.pendingActions.push(action);
        }
        return;
      }
      case "handlerBody":
        // The compiler enforces that handler bodies end with break/next.
        // Reaching this means the body fell through without one.
        throw new Error(
          `engine.handle: handler body finished without break/next (callId=${callId})`,
        );
      case "thenClause":
        // thenClause done — that's our result. Cancel anything still
        // running and emit `done` once the cascade clears.
        enterCancellingForResult(ctx, t as HandleThread, value);
        return;
    }
  },

  cancel: (ctx, t) => defaultCancel<HandleThread>(ctx, t as HandleThread),

  cancelAck(ctx, t, callId) {
    if (!commonRemoveChild(ctx, t as HandleThread, callId)) return;
    delete t.childRoles[callId];

    const action = t.postCancelActions[callId];
    if (action === undefined) {
      // Untracked targeted cancel — likely a logic error, throw.
      throw new Error(
        `engine.handle: cancelAck without postCancelAction (callId=${callId})`,
      );
    }
    delete t.postCancelActions[callId];

    if (action.kind !== "askComplete") {
      throw new Error(
        `engine.handle: unexpected postCancelAction.kind=${action.kind}`,
      );
    }

    // Fire askAck back to the proxy chain that delivered the original
    // request ask. The proxy's askIdMap will route it down to the
    // RequestThread.
    const askerThreadId = t.children[action.askerCallId];
    if (askerThreadId !== undefined) {
      ctx.enqueue({
        kind: "askAck",
        target: askerThreadId,
        askId: action.askId,
        value: action.value,
      });
    } else {
      ctx.log("debug", "engine.handle: askComplete dropped — asker chain gone", {
        threadId: t.id,
        askerCallId: action.askerCallId,
      });
    }

    // Sequential: dispatch the next pending action if any.
    if (!isParallel(ctx, t.blockId) && !isBusy(t) && t.pendingActions.length > 0) {
      const next = t.pendingActions.shift()!;
      runAction(ctx, t as HandleThread, next);
    }
  },

  ask(ctx, t, askId, kind, childCallId) {
    // request: catch if we own the reqId, else proxy.
    if (kind.kind === "request") {
      const block = getHandleBlock(ctx, t.blockId);
      if (block.handlers.find(h => h.request === kind.reqId) !== undefined) {
        const action: PendingAction = {
          kind: "ask",
          reqId: kind.reqId,
          args: { ...kind.args },
          askId,
          askerCallId: childCallId,
        };
        if (block.parallel || !isBusy(t)) {
          runAction(ctx, t as HandleThread, action);
        } else {
          t.pendingActions.push(action);
        }
        return;
      }
      // Not ours — bubble up.
      proxyAskToParent(ctx, t as HandleThread, childCallId, askId, kind);
      return;
    }

    // next: catch if we own the corresponding reqId. Currently the
    // compiler doesn't tag `statementCont` with which req it resumes —
    // we rely on the topology (the `next` came from inside a handler
    // body of *this* handle). Identify the originating handler body via
    // childCallId, confirm it's a handlerBody role here, and proceed.
    if (kind.kind === "next") {
      const role = t.childRoles[childCallId];
      if (role !== undefined && role.kind === "handlerBody") {
        // Apply state-var modifiers to our scope, then targeted cancel.
        for (const [varKey, value] of Object.entries(kind.mods)) {
          setValueInScope(ctx, t.scopeId, Number(varKey), value);
        }
        // Schedule the askAck for after the cancel completes. The
        // (askId, askerCallId) carried by the role identify the
        // outstanding request ask whose ack we need to fire.
        t.postCancelActions[childCallId] = {
          kind: "askComplete",
          askId: role.askId,
          askerCallId: role.askerCallId,
          value: kind.value,
        };
        const childId = t.children[childCallId];
        if (childId !== undefined) {
          ctx.enqueue({ kind: "cancel", target: childId });
        }
        return;
      }
      // Not ours — bubble up.
      proxyAskToParent(ctx, t as HandleThread, childCallId, askId, kind);
      return;
    }

    // break: catch (done-terminating).
    if (kind.kind === "break") {
      handleBreak(ctx, t as HandleThread, kind.value);
      return;
    }

    // Anything else: bubble up.
    proxyAskToParent(ctx, t as HandleThread, childCallId, askId, kind);
  },

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<HandleThread>(ctx, t as HandleThread, askId, value),
};

// ─── helpers ───────────────────────────────────────────────────────────────

function getHandleBlock(ctx: StepCtx, blockId: BlockId): HandleBlock {
  const b = ctx.state.irModule.blocks[String(blockId)] as Block | undefined;
  if (b === undefined) throw new Error(`engine.handle: block ${blockId} not found`);
  if (b.kind !== "blockHandle") {
    throw new Error(`engine.handle: block ${blockId} is not blockHandle (${b.kind})`);
  }
  return b.body;
}

function isParallel(ctx: StepCtx, blockId: BlockId): boolean {
  return getHandleBlock(ctx, blockId).parallel;
}

/** A handler body or thenClause is currently running (sequential gate). */
function isBusy(t: HandleThread): boolean {
  for (const role of Object.values(t.childRoles)) {
    if (role.kind === "handlerBody" || role.kind === "thenClause") return true;
  }
  return false;
}

function runAction(
  ctx: StepCtx,
  t: HandleThread,
  action: PendingAction,
): void {
  switch (action.kind) {
    case "ask":
      spawnHandlerBody(ctx, t, action.reqId, action.args, action.askId, action.askerCallId);
      return;
    case "thenClause":
      spawnThenClauseOrFinish(ctx, t, action.mainResultValue);
      return;
  }
}

function spawnHandlerBody(
  ctx: StepCtx,
  t: HandleThread,
  reqId: QualifiedName,
  args: Record<string, Value>,
  askId: AskId,
  askerCallId: CallId,
): void {
  const block = getHandleBlock(ctx, t.blockId);
  const handler = block.handlers.find(h => h.request === reqId);
  if (handler === undefined) {
    throw new Error(`engine.handle: no handler for reqId ${reqId} (post-catch)`);
  }
  const callId = t.nextCallId;
  t.nextCallId = ((callId as number) + 1) as CallId;
  t.childRoles[callId] = {
    kind: "handlerBody",
    reqId,
    askId,
    askerCallId,
  };
  // Spawn inline; callArgs become the handler-body's parameter values.
  const childId = spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: handler.handlerBody,
    callArgs: args,
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
  // Write call args into the new child's scope by parameter label so the
  // handler body's user thread can read them.
  writeArgsIntoChildScope(ctx, childId, handler.handlerBody, args);
}

function spawnThenClauseOrFinish(
  ctx: StepCtx,
  t: HandleThread,
  mainResultValue: Value,
): void {
  const block = getHandleBlock(ctx, t.blockId);
  if (block.thenBlock === undefined) {
    // No then clause — main's result is our value directly. Finish via
    // the cancel/pendingReturn machinery so any other pending actions
    // get cleaned up.
    enterCancellingForResult(ctx, t, mainResultValue);
    return;
  }
  const callId = t.nextCallId;
  t.nextCallId = ((callId as number) + 1) as CallId;
  t.childRoles[callId] = { kind: "thenClause", mainResultValue };
  const childId = spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: block.thenBlock,
    callArgs: { value: mainResultValue },
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
  // Bind the thenClause's `value` parameter into its scope.
  writeArgsIntoChildScope(ctx, childId, block.thenBlock, { value: mainResultValue });
}

function handleBreak(
  ctx: StepCtx,
  t: HandleThread,
  value: Value,
): void {
  if (t.status === "cancelling") return;
  t.pendingReturn = value;
  beginCancel(ctx, t);
}

function enterCancellingForResult(
  ctx: StepCtx,
  t: HandleThread,
  value: Value,
): void {
  if (t.status === "cancelling") return;
  t.pendingReturn = value;
  if (!hasChildren(t)) {
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "done",
        target: t.parent,
        callId: t.parentCallId,
        value,
      });
    }
    return;
  }
  beginCancel(ctx, t);
}


