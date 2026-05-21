// MatchThread ops.
//
// onCreate:
//   - resolve subject from caller scope (via the inline parent chain)
//   - try arms in order; first that matches binds vars in own scope and
//     spawns the arm body (callInline)
//   - if no arm matches and no default, raise RecoverableEngineError
//
// onChildDone: forward the arm body's value as our own done.

import type { Draft } from "immer";
import type { CallId } from "../../id.js";
import type { Block, BlockId, MatchBlock } from "../../../ir/types.js";
import { tryMatch } from "../../pattern.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import {
  commonRemoveChild,
  emitThrowEscalate,
  lookupValue,
  setValueInScope,
} from "../common.js";
import type { MatchThread, Thread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const matchOps: ThreadOps<MatchThread> = {
  create(ctx, t) {
    const block = getMatchBlock(ctx, t.blockId);
    const subject = lookupValue(ctx, t.scopeId, block.subject);

    for (const arm of block.arms) {
      const bindings = tryMatch(arm.pattern, subject);
      if (bindings !== null) {
        for (const [k, v] of Object.entries(bindings)) {
          setValueInScope(ctx, t.scopeId, Number(k), v);
        }
        spawnArm(ctx, t as Draft<MatchThread>, arm.body);
        return;
      }
    }
    if (block.defaultArm !== undefined) {
      spawnArm(ctx, t as Draft<MatchThread>, block.defaultArm);
      return;
    }
    emitThrowEscalate(ctx, t as Draft<Thread>, "match: no arm matched");
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as Draft<MatchThread>, callId)) return;
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "done",
        target: t.parent,
        callId: t.parentCallId,
        value,
      });
    }
  },

  cancel: (ctx, t) => defaultCancel<MatchThread>(ctx, t as Draft<MatchThread>),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<MatchThread>(ctx, t as Draft<MatchThread>, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<MatchThread>(ctx, t as Draft<MatchThread>, askId, value),
};

function getMatchBlock(ctx: StepCtx, blockId: BlockId): MatchBlock {
  const b = ctx.state.irModule.blocks[String(blockId)] as Block | undefined;
  if (b === undefined) {
    throw new Error(`engine.match: block ${blockId} not found`);
  }
  if (b.kind !== "blockMatch") {
    throw new Error(`engine.match: block ${blockId} is not a match block (got ${b.kind})`);
  }
  return b.body;
}

function spawnArm(ctx: StepCtx, t: Draft<MatchThread>, blockId: BlockId): void {
  spawnChild(ctx, {
    parentId: t.id,
    parentCallId: 0 as CallId,
    blockId,
    callArgs: {},
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
}

