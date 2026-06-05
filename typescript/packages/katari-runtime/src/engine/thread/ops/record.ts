// RecordThread ops.
//
// Each entry block is spawned as a sequential inline child; the
// trailing value of each block becomes the entry's value. When every
// child has reported done, the thread emits a single record Value
// (`{kind: "record", entries: { label: value, ... }}`) to its parent.

import type { BlockId, RecordBlock } from "../../../ir/types.js";
import type { CallId } from "../../id.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import { commonRemoveChild } from "../common.js";
import type { RecordThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const recordOps: ThreadOps<RecordThread> = {
  create(ctx, t) {
    const block = getBlock(ctx, t.blockId);
    if (block.entries.length === 0) {
      emitDone(ctx, t, block, []);
      return;
    }
    const first = block.entries[0]!;
    spawnEntry(ctx, t, 0, first[1]);
  },
  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as RecordThread, callId)) return;
    const block = getBlock(ctx, t.blockId);
    t.collected[callId] = value;
    t.nextIndex += 1;
    if (t.nextIndex >= block.entries.length) {
      emitDone(ctx, t, block, block.entries);
      return;
    }
    const next = block.entries[t.nextIndex]!;
    spawnEntry(ctx, t, t.nextIndex, next[1]);
  },
  cancel: (ctx, t) => defaultCancel<RecordThread>(ctx, t as RecordThread),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<RecordThread>(ctx, t as RecordThread, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<RecordThread>(ctx, t as RecordThread, askId, value),
};

// ─── helpers ───────────────────────────────────────────────────────────────

function getBlock(ctx: StepCtx, blockId: BlockId): RecordBlock {
  const b = ctx.state.irModule.blocks[String(blockId)];
  if (b === undefined) {
    throw new Error(`engine.record: block ${blockId} not found`);
  }
  if (b.kind !== "blockRecord") {
    throw new Error(`engine.record: block ${blockId} is not a record (got ${b.kind})`);
  }
  return b.body;
}

function spawnEntry(ctx: StepCtx, t: RecordThread, index: number, blockId: BlockId): void {
  spawnChild(ctx, {
    parentId: t.id,
    parentCallId: index as CallId,
    blockId,
    argument: undefined,
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
}

function emitDone(
  ctx: StepCtx,
  t: RecordThread,
  _block: RecordBlock,
  entries: [string, BlockId][],
): void {
  if (t.parent === null || t.parentCallId === null) return;
  const out: Record<string, Value> = Object.create(null);
  for (let i = 0; i < entries.length; i++) {
    const [label] = entries[i]!;
    const v = t.collected[i as CallId];
    if (v === undefined) {
      throw new Error(`engine.record: missing entry '${label}' at index ${i}`);
    }
    out[label] = v;
  }
  ctx.enqueue({
    kind: "done",
    target: t.parent,
    callId: t.parentCallId,
    value: { kind: "record", entries: out },
  });
}
