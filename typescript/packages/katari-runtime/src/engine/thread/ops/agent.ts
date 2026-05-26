// AgentThread ops — the agent boundary.
//
// An AgentThread wraps a `BlockAgent` IR block. On `create` it spawns the
// entry body as a child UserThread (callId 0) with the args bound into
// that body's scope. The AgentThread itself runs no statements; it just
// catches `return` asks bubbling up from descendants and waits for the
// body's `done` to drive the outbound `delegateAck`.
//
// Lifecycle:
//   - `create`     spawn body UserThread; bind args by parameter label
//   - `ask:return` cancel body, set pendingReturn = caught value;
//                  finishCancelling emits delegateAck on completion
//   - `done`       body finished naturally; emit delegateAck directly
//                  (no cancel cascade needed — body is already gone)
//   - `cancel`     incoming external terminate; cancel body, no
//                  pendingReturn, finishCancelling emits terminateAck

import type {
  AgentBlock,
  Block,
  BlockId,
} from "../../../ir/types.js";
import type { CallId } from "../../id.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import {
  beginCancel,
  commonRemoveChild,
  emitAgentRootCompletion,
  emitEscalateUpward,
  hasChildren,
  proxyAskToParent,
  setValueInScope,
} from "../common.js";
import type { AgentThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultCancel,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

const BODY_CALL_ID = 0 as CallId;

export const agentOps: ThreadOps<AgentThread> = {
  create(ctx, t) {
    const block = getAgentBlock(ctx, t.blockId);
    // Bind args into our own scope by parameter label so the body
    // (inline child) can see them via the inherited scope chain.
    for (const param of block.parameters) {
      const v = t.args[param.label];
      if (v !== undefined) {
        setValueInScope(ctx, t.scopeId, param.var, v);
      }
    }
    // Spawn the body as a child. The body block is expected to be a
    // BlockUser (inline) — we inherit our scope so args are visible.
    spawnChild(ctx, {
      parentId: t.id,
      parentCallId: BODY_CALL_ID,
      blockId: block.entryBody,
      callArgs: { ...t.args },
      scopeMode: { mode: "inline", parentScopeId: t.scopeId },
    });
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as AgentThread, callId)) return;
    if (callId === BODY_CALL_ID) {
      // Body finished naturally — emit delegateAck and remove ourselves.
      finishWithValue(ctx, t as AgentThread, value);
      return;
    }
    // We don't expect any other children.
    throw new Error(
      `engine.agent: unexpected done from non-body child (callId=${callId})`,
    );
  },

  cancel: (ctx, t) => defaultCancel<AgentThread>(ctx, t as AgentThread),
  cancelAck: (ctx, t, callId) => {
    // Body finished cancelling. commonRemoveChild handles the bookkeeping;
    // finishCancelling fires from there if status === "cancelling" and
    // there are no children left.
    commonRemoveChild(ctx, t as AgentThread, callId);
  },

  ask(ctx, t, askId, kind, childCallId) {
    if (kind.kind === "return") {
      catchReturn(ctx, t as AgentThread, kind.value);
      return;
    }
    if (t.parent === null) {
      // Root AgentThread = receiver side of a delegation. A `request` ask
      // that reaches us has no local handler — escalate it back to the
      // delegation sender (symmetric with DelegateThread sender side).
      const peer = ctx.state.delegationSenders[t.delegationId];
      if (peer === undefined) {
        ctx.log("warn", "engine.agent: ask at root with no registered sender", {
          threadId: t.id,
          delegationId: t.delegationId,
          askKind: kind.kind,
        });
        return;
      }
      emitEscalateUpward(ctx, t as AgentThread, peer, kind, childCallId, askId);
      return;
    }
    // Non-root AgentThread: currently unreachable in well-formed IR
    // (top-level agent calls always go through a BlockDelegate which
    // spawns an AgentThread as a delegation root, not as a child).
    // Kept for symmetry — proxy upward through the parent chain.
    proxyAskToParent(ctx, t as AgentThread, childCallId, askId, kind);
  },

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<AgentThread>(ctx, t as AgentThread, askId, value),
};

// ─── helpers ───────────────────────────────────────────────────────────────

function getAgentBlock(ctx: StepCtx, blockId: BlockId): AgentBlock {
  const b = ctx.state.irModule.blocks[String(blockId)] as Block | undefined;
  if (b === undefined) throw new Error(`engine.agent: block ${blockId} not found`);
  if (b.kind !== "blockAgent") {
    throw new Error(`engine.agent: block ${blockId} is not blockAgent (${b.kind})`);
  }
  return b.body;
}

/**
 * Body returned naturally with `value`. Two completion paths:
 *
 *   - Root AgentThread (parent === null): spawned by `spawnAgentRoot` for
 *     an inbound `delegate` event. Emit outbound `delegateAck` via
 *     `emitAgentRootCompletion`, which also clears `state.delegations`.
 *
 *   - Non-root AgentThread (parent !== null): spawned structurally by
 *     `spawnChild` when a `StatementCall` targets a `blockAgent`. Emit
 *     internal `done` to the parent UserThread; the synthetic
 *     `delegationId` allocated in spawnChild is not registered in
 *     `state.delegations` and is never looked up.
 */
function finishWithValue(
  ctx: StepCtx,
  t: AgentThread,
  value: Value,
): void {
  if (t.parent === null) {
    emitAgentRootCompletion(ctx, t, value);
    delete ctx.state.threads[t.id];
    ctx.state.threadCount--;
    return;
  }
  ctx.enqueue({
    kind: "done",
    target: t.parent,
    callId: t.parentCallId!,
    value,
  });
  delete ctx.state.threads[t.id];
  ctx.state.threadCount--;
}

/**
 * Caught a `return` ask. Stash the value in pendingReturn and cancel
 * the body. finishCancelling reads pendingReturn back when no children
 * remain and emits delegateAck.
 */
function catchReturn(
  ctx: StepCtx,
  t: AgentThread,
  value: Value,
): void {
  if (t.status === "cancelling") return;
  t.pendingReturn = value;
  if (!hasChildren(t)) {
    finishWithValue(ctx, t, value);
    return;
  }
  beginCancel(ctx, t);
}
