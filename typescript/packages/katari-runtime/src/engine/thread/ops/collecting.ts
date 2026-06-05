// Shared logic for the seq collecting thread (TupleThread).
//
// Spawns N inline children (one per element block) and assembles the returned
// values into a single ordered `array` Value when all children are done.
// Sequential mode runs them one at a time; parallel fans them all out at once
// (driven by the block's `parallel` flag).

import type { BlockId, TupleBlock } from "../../../ir/types.js";
import type { CallId } from "../../id.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import type { CollectingThread } from "../types.js";

type CollectingBlock = TupleBlock;

export function collectingCreate(ctx: StepCtx, t: CollectingThread): void {
  const block = getBlock(ctx, t.blockId);
  const elements = block.elements;

  if (elements.length === 0) {
    emitDone(ctx, t, []);
    return;
  }

  if (block.parallel) {
    for (let i = 0; i < elements.length; i++) {
      spawnElement(ctx, t, i, elements[i]!);
    }
  } else {
    spawnElement(ctx, t, 0, elements[0]!);
  }
}

export function collectingDone(
  ctx: StepCtx,
  t: CollectingThread,
  callId: CallId,
  value: Value,
): void {
  const block = getBlock(ctx, t.blockId);
  const elements = block.elements;
  // Common bookkeeping (delete child) is done by the runner via the
  // common.ts helper before the variant op runs. Here we just record
  // the value and decide next steps.
  t.collected[callId] = value as Value;

  if (block.parallel) {
    if (Object.keys(t.collected).length >= elements.length) {
      finishCollecting(ctx, t, elements.length);
    }
    return;
  }

  // Sequential: spawn the next element.
  t.nextIndex += 1;
  if (t.nextIndex >= elements.length) {
    finishCollecting(ctx, t, elements.length);
    return;
  }
  spawnElement(ctx, t, t.nextIndex, elements[t.nextIndex]!);
}

// ─── helpers ───────────────────────────────────────────────────────────────

function getBlock(ctx: StepCtx, blockId: BlockId): CollectingBlock {
  const b = ctx.state.irModule.blocks[String(blockId)];
  if (b === undefined) {
    throw new Error(`engine.collecting: block ${blockId} not found`);
  }
  if (b.kind !== "blockTuple") {
    throw new Error(`engine.collecting: block ${blockId} is not a seq block (got ${b.kind})`);
  }
  return b.body;
}

function spawnElement(ctx: StepCtx, t: CollectingThread, index: number, blockId: BlockId): void {
  spawnChild(ctx, {
    parentId: t.id,
    parentCallId: index as CallId,
    blockId,
    argument: undefined,
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
}

function finishCollecting(ctx: StepCtx, t: CollectingThread, totalLen: number): void {
  const elements: Value[] = [];
  for (let i = 0; i < totalLen; i++) {
    const v = t.collected[i as CallId] as Value | undefined;
    if (v === undefined) {
      throw new Error(`engine.collecting: missing element ${i}`);
    }
    elements.push(v);
  }
  emitDone(ctx, t, elements);
}

function emitDone(ctx: StepCtx, t: CollectingThread, elements: Value[]): void {
  if (t.parent === null || t.parentCallId === null) return;
  // Tuples and arrays share one runtime Value variant — the seq block always
  // produces an ordered `array` Value; its `parallel` flag only chose
  // sequential vs concurrent element collection.
  ctx.enqueue({
    kind: "done",
    target: t.parent,
    callId: t.parentCallId,
    value: { kind: "array", elements },
  });
}
