// GetFieldThread ops — read one field out of a record value.
//
// Spawned inline by a StatementCall targeting a `blockGetField`. On create it
// reads its `source` var from the inherited scope, takes `source.field` (or
// null when the source is not a record / lacks the field), and `done`s that
// value to its parent. Being a thread (not an inline statement) leaves room to
// grow an async path once file / blob / stream sources need materialising.

import type { Block, BlockId, GetFieldBlock } from "../../../ir/types.js";
import type { StepCtx } from "../../step-ctx.js";
import { NULL_VALUE, type Value } from "../../value.js";
import { lookupValue } from "../common.js";
import type { GetFieldThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const getFieldOps: ThreadOps<GetFieldThread> = {
  create(ctx, t) {
    const block = getGetFieldBlock(ctx, t.blockId);
    const source = lookupValue(ctx, t.scopeId, block.source);
    const field = source.kind === "record" ? source.entries[block.field] : undefined;
    const value: Value = field ?? NULL_VALUE;
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({ kind: "done", target: t.parent, callId: t.parentCallId, value });
    }
  },

  done(_ctx, t, callId) {
    throw new Error(`engine.getField: unexpected done (callId=${callId}) on ${t.id}`);
  },
  cancel: (ctx, t) => defaultCancel<GetFieldThread>(ctx, t as GetFieldThread),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<GetFieldThread>(ctx, t as GetFieldThread, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<GetFieldThread>(ctx, t as GetFieldThread, askId, value),
};

function getGetFieldBlock(ctx: StepCtx, blockId: BlockId): GetFieldBlock {
  const b = ctx.state.irModule.blocks[String(blockId)] as Block | undefined;
  if (b === undefined || b.kind !== "blockGetField") {
    throw new Error(`engine.getField: block ${blockId} is not blockGetField (${b?.kind})`);
  }
  return b.body;
}
