// ForThread ops.
//
// Iterates over a Cartesian product of one or more iter sources. The
// first iter is the outermost loop. For multi-iter `(a in xs, b in ys)`
// the body sees `(a,b) ∈ {(x0,y0), (x0,y1), ..., (xN,yM)}`.
//
// The loop's value is a MAPPING: each iteration exits via `next v`, and the
// `v` values are collected in source order into an array. With a then-clause
// that array is handed to the then-block (bound by its pattern); without one
// the array IS the loop's value. A `break v` short-circuits the whole loop to
// `v`, discarding the collected array.
//
// Sequential mode: spawn one body at a time; each `next-for` advances.
// Parallel mode:   spawn every body up front; each `next-for` records its
//                  slot and retires that body. State vars / `break` are
//                  rejected by the compiler (`par for` restrictions).
//
// `break-for` (done-terminating) short-circuits; `next-for` (askAck-style,
// here resolved by a targeted cancel) records + advances. Other asks bubble.

import type { BlockId, ForBlock } from "../../../ir/types.js";
import type { ModMap } from "../../event.js";
import type { CallId } from "../../id.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import { NULL_VALUE, type Value } from "../../value.js";
import {
  allocCallId,
  beginCancel,
  commonRemoveChild,
  lookupValue,
  proxyAskToParent,
  setValueInScope,
  writeArgsIntoChildScope,
} from "../common.js";
import type { ForThread } from "../types.js";
import { defaultAskAckProxy, defaultCancel } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const forOps: ThreadOps<ForThread> = {
  create(ctx, t) {
    const block = getForBlock(ctx, t.blockId);

    // Initialize state vars from caller scope into our own scope.
    for (const [bodyVar, initVar] of block.stateInits) {
      const v = lookupValue(ctx, t.scopeId, initVar);
      setValueInScope(ctx, t.scopeId, bodyVar, v);
    }

    // Resolve iter sources once into a snapshot.
    const iterables: Value[] = block.iters.map(([_elem, source]) =>
      lookupValue(ctx, t.scopeId, source),
    );
    t.iterableSnapshot = iterables;

    const total = getIterableTotal(iterables);
    t.total = total;
    if (total === 0) {
      emitForResult(ctx, t as ForThread, buildCollected(t as ForThread));
      return;
    }

    if (block.parallel) {
      // Spawn every iteration up-front. Each iteration gets its own
      // scope (inline) into which we write per-iteration iter vars so
      // concurrent iterations don't race on the for thread's scope. Each
      // body exits with `next v`; we record `v` at its index and retire it.
      for (let i = 0; i < total; i++) {
        spawnParallelBody(ctx, t as ForThread, block, iterables, i);
      }
      return;
    }

    spawnSequentialBody(ctx, t as ForThread, block, 0);
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as ForThread, callId)) return;

    if (t.thenCallId !== null && callId === t.thenCallId) {
      // Then-block done — its value is the loop's result.
      t.thenCallId = null;
      emitDoneToParent(ctx, t as ForThread, value);
      return;
    }

    // A body completed via `done` rather than `next` / `break`. The compiler
    // enforces that a for body always exits (must-exit), so this is defensive:
    // treat the iteration as contributing `null` and advance / count down.
    delete t.iterIndexByCallId[callId];
    advanceAfterIteration(ctx, t as ForThread);
  },

  cancel: (ctx, t) => defaultCancel<ForThread>(ctx, t as ForThread),

  /**
   * Targeted-cancel followup for `next-for`: the retired body is gone, so
   * advance (sequential) or count down (parallel).
   */
  cancelAck(ctx, t, callId) {
    if (!commonRemoveChild(ctx, t as ForThread, callId)) return;
    const action = t.postCancelActions[callId];
    if (action === undefined) {
      throw new Error(
        `engine.for: cancelAck on ${t.id} without postCancelAction for callId ${callId}`,
      );
    }
    delete t.postCancelActions[callId];
    if (action.kind !== "finish") {
      throw new Error(`engine.for: unexpected postCancelAction.kind=${action.kind} on ${t.id}`);
    }
    delete t.iterIndexByCallId[callId];
    advanceAfterIteration(ctx, t as ForThread);
  },

  ask(ctx, t, askId, kind, childCallId) {
    if (kind.kind === "break-for") {
      handleBreakFor(ctx, t as ForThread, kind.value);
      return;
    }
    if (kind.kind === "next-for") {
      handleNextFor(ctx, t as ForThread, kind.value, kind.mods, childCallId);
      return;
    }
    proxyAskToParent(ctx, t as ForThread, childCallId, askId, kind);
  },

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<ForThread>(ctx, t as ForThread, askId, value),
};

// ─── helpers ───────────────────────────────────────────────────────────────

function getForBlock(ctx: StepCtx, blockId: BlockId): ForBlock {
  const b = ctx.state.irModule.blocks[String(blockId)];
  if (b === undefined) throw new Error(`engine.for: block ${blockId} not found`);
  if (b.kind !== "blockFor") {
    throw new Error(`engine.for: block ${blockId} is not blockFor (${b.kind})`);
  }
  return b.body;
}

function getIterableTotal(iterables: Value[]): number {
  let total = 1;
  for (const it of iterables) {
    if (it.kind !== "array") {
      throw new Error("engine.for: iter source is not an array");
    }
    // Refuse cartesian products that overflow Number.MAX_SAFE_INTEGER
    // (= 2^53 - 1). Past that point linearIndex / total comparisons
    // start producing wrong results because adjacent doubles collide.
    // A real program would never iterate that many times anyway, but
    // an attacker who can pass two large arrays could lock the engine
    // into Infinity-bound infinite loop without this guard.
    total *= it.elements.length;
    if (!Number.isSafeInteger(total)) {
      throw new Error(
        `engine.for: cartesian product exceeds Number.MAX_SAFE_INTEGER (${Number.MAX_SAFE_INTEGER})`,
      );
    }
  }
  return total;
}

function bindElementVars(
  ctx: StepCtx,
  scopeId: ForThread["scopeId"],
  block: ForBlock,
  iterables: Value[],
  linearIndex: number,
): void {
  let remaining = linearIndex;
  for (let i = block.iters.length - 1; i >= 0; i--) {
    const iter = block.iters[i]!;
    const arr = iterables[i];
    if (arr === undefined || arr.kind !== "array") {
      throw new Error("engine.for: iter source is not an array");
    }
    const len = arr.elements.length;
    if (len === 0) {
      throw new Error(`engine.for: iter at index ${i} is empty`);
    }
    const digit = remaining % len;
    remaining = Math.floor(remaining / len);
    const elem = arr.elements[digit]!;
    setValueInScope(ctx, scopeId, iter[0], elem);
  }
}

/**
 * Spawn the sequential body for `index`: bind its iter vars into the for
 * thread's shared scope (only one body runs at a time, so no race), then
 * spawn the body inline.
 */
function spawnSequentialBody(ctx: StepCtx, t: ForThread, block: ForBlock, index: number): void {
  bindElementVars(ctx, t.scopeId, block, t.iterableSnapshot, index);
  const callId = allocCallId(t);
  t.iterIndexByCallId[callId] = index;
  spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: block.bodyBlock,
    argument: undefined,
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
}

/**
 * Spawn one parallel iteration. Each iteration's iter-var bindings live in
 * *its own* fresh inline scope (not shared with siblings) so the iterations
 * don't race on the for thread's scope.
 */
function spawnParallelBody(
  ctx: StepCtx,
  t: ForThread,
  block: ForBlock,
  iterables: Value[],
  index: number,
): void {
  const callId = allocCallId(t);
  t.iterIndexByCallId[callId] = index;
  const childId = spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: block.bodyBlock,
    argument: undefined,
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
  const child = ctx.state.threads[childId];
  if (child === undefined) return;
  bindElementVars(ctx, child.scopeId, block, iterables, index);
}

/**
 * One iteration body has retired (via `next-for` or a defensive `done`).
 * Sequential: advance the cursor and spawn the next body, or finish.
 * Parallel: finish once every body has retired.
 */
function advanceAfterIteration(ctx: StepCtx, t: ForThread): void {
  const block = getForBlock(ctx, t.blockId);
  if (block.parallel) {
    if (Object.keys(t.children).length === 0) {
      emitForResult(ctx, t, buildCollected(t));
    }
    return;
  }
  t.currentIndex += 1;
  if (t.currentIndex >= t.total) {
    emitForResult(ctx, t, buildCollected(t));
    return;
  }
  spawnSequentialBody(ctx, t, block, t.currentIndex);
}

/** Assemble the collected `next` values into an ordered array Value. */
function buildCollected(t: ForThread): Value {
  const elements: Value[] = [];
  for (let i = 0; i < t.total; i++) {
    elements.push(t.collected[i] ?? NULL_VALUE);
  }
  return { kind: "array", elements };
}

/**
 * Emit the loop's normal result `value` (the mapped array). With a
 * then-block, hand it to the then-block (bound to its input var); otherwise
 * propagate it straight to the parent.
 */
function emitForResult(ctx: StepCtx, t: ForThread, value: Value): void {
  const block = getForBlock(ctx, t.blockId);
  if (block.thenBlock !== undefined) {
    const thenCallId = allocCallId(t);
    t.thenCallId = thenCallId;
    const childId = spawnChild(ctx, {
      parentId: t.id,
      parentCallId: thenCallId,
      blockId: block.thenBlock,
      argument: value,
      scopeMode: { mode: "inline", parentScopeId: t.scopeId },
    });
    writeArgsIntoChildScope(ctx, childId, block.thenBlock, value);
    return;
  }
  emitDoneToParent(ctx, t, value);
}

function emitDoneToParent(ctx: StepCtx, t: ForThread, value: Value): void {
  if (t.parent !== null && t.parentCallId !== null) {
    ctx.enqueue({
      kind: "done",
      target: t.parent,
      callId: t.parentCallId,
      value,
    });
  }
}

function handleBreakFor(ctx: StepCtx, t: ForThread, value: Value): void {
  if (t.status === "cancelling") return;
  // Short-circuit: the loop's value is the break value (collected array and
  // then-clause are discarded). The cancel cascade emits `done` with this.
  t.pendingReturn = value;
  beginCancel(ctx, t);
}

function handleNextFor(
  ctx: StepCtx,
  t: ForThread,
  value: Value,
  mods: ModMap | undefined,
  childCallId: CallId,
): void {
  // Record this iteration's mapped value at its source-order slot.
  const index = t.iterIndexByCallId[childCallId];
  if (index !== undefined) {
    t.collected[index] = value;
  }
  // Apply state-var modifiers (sequential only; `par for` forbids state).
  if (mods !== undefined) {
    for (const [varKey, modValue] of Object.entries(mods)) {
      setValueInScope(ctx, t.scopeId, Number(varKey), modValue);
    }
  }
  // Retire the body iteration whose descendant emitted the ask via a targeted
  // cancel; the cancelAck advances us.
  const childId = t.children[childCallId];
  if (childId === undefined) {
    // Body already gone — race. Just advance.
    return;
  }
  t.postCancelActions[childCallId] = { kind: "finish" };
  ctx.enqueue({ kind: "cancel", target: childId });
}
