// ForThread ops.
//
// Iterates over a Cartesian product of one or more iter sources. The
// first iter is the outermost loop. For multi-iter `(a in xs, b in ys)`
// the body sees `(a,b) ∈ {(x0,y0), (x0,y1), ..., (xN,yM)}`.
//
// Sequential mode: spawn one body at a time, advance on done.
// Parallel mode:   not yet implemented (Phase H).
//
// Catches `break-for` (done-terminating) and `next-for` (askAck-terminating
// with state-var modifiers) asks. Other asks bubble up.

import type { ForBlock } from "../../../ir/types.js";
import type { CallId } from "../../id.js";
import type { ModMap } from "../../event.js";
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
} from "../common.js";
import type { ForThread, } from "../types.js";
import {
  defaultAskAckProxy,
  defaultCancel,
} from "./defaults.js";
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
    if (total === 0) {
      emitForDone(ctx, t as ForThread, NULL_VALUE);
      return;
    }

    if (block.parallel) {
      // Spawn every iteration up-front. Each iteration gets its own
      // scope (callInline) into which we write per-iteration iter vars
      // so concurrent iterations don't race on the for thread's scope.
      // break-for / next-for inside parallel mode are not supported —
      // the runtime cannot give them well-defined ordering semantics.
      // The compiler is expected to reject them; if one slips through
      // we let it propagate via the bubbling ask and the surrounding
      // ask handler decides.
      for (let i = 0; i < total; i++) {
        spawnParallelBody(ctx, t as ForThread, block, iterables, i);
      }
      return;
    }

    bindElementVars(ctx, t as ForThread, block, iterables, 0);
    spawnBody(ctx, t as ForThread);
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as ForThread, callId)) return;

    if (t.thenCallId !== null && callId === t.thenCallId) {
      // Then block done — propagate as our result.
      t.thenCallId = null;
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

    const block = getForBlock(ctx, t.blockId);

    if (block.parallel) {
      // Parallel mode: count down by checking remaining children.
      if (Object.keys(t.children).length === 0) {
        emitForDone(ctx, t as ForThread, NULL_VALUE);
      }
      return;
    }

    t.currentIndex += 1;
    const total = getIterableTotal(t.iterableSnapshot as Value[]);
    if (t.currentIndex >= total) {
      emitForDone(ctx, t as ForThread, NULL_VALUE);
      return;
    }
    bindElementVars(ctx, t as ForThread, block, t.iterableSnapshot as Value[], t.currentIndex);
    spawnBody(ctx, t as ForThread);
  },

  cancel: (ctx, t) => defaultCancel<ForThread>(ctx, t as ForThread),

  /**
   * Targeted-cancel followup for `next-for`.
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
      throw new Error(
        `engine.for: unexpected postCancelAction.kind=${action.kind} on ${t.id}`,
      );
    }
    // "finish" here for ForThread means "advance to next iteration".
    const block = getForBlock(ctx, t.blockId);
    t.currentIndex += 1;
    const total = getIterableTotal(t.iterableSnapshot as Value[]);
    if (t.currentIndex >= total) {
      emitForDone(ctx, t as ForThread, NULL_VALUE);
      return;
    }
    bindElementVars(ctx, t as ForThread, block, t.iterableSnapshot as Value[], t.currentIndex);
    spawnBody(ctx, t as ForThread);
  },

  ask(ctx, t, askId, kind, childCallId) {
    if (kind.kind === "break-for") {
      handleBreakFor(ctx, t as ForThread, kind.value);
      return;
    }
    if (kind.kind === "next-for") {
      handleNextFor(ctx, t as ForThread, kind.mods, childCallId);
      return;
    }
    proxyAskToParent(
      ctx,
      t as ForThread,
      childCallId,
      askId,
      kind,
    );
  },

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<ForThread>(ctx, t as ForThread, askId, value),
};

// ─── helpers ───────────────────────────────────────────────────────────────

function getForBlock(ctx: StepCtx, blockId: import("../../../ir/types.js").BlockId): ForBlock {
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
  t: ForThread,
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
    setValueInScope(ctx, t.scopeId, iter[0], elem);
  }
}

function spawnBody(ctx: StepCtx, t: ForThread): void {
  const block = getForBlock(ctx, t.blockId);
  const callId = allocCallId(t);
  spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: block.bodyBlock,
    callArgs: {},
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
}

/**
 * Spawn one parallel iteration. Each iteration's iter-var bindings live
 * in *its own* fresh inline scope (not shared with siblings) so the
 * iterations don't race on the for thread's scope.
 */
function spawnParallelBody(
  ctx: StepCtx,
  t: ForThread,
  block: import("../../../ir/types.js").ForBlock,
  iterables: Value[],
  index: number,
): void {
  const callId = allocCallId(t);
  const childId = spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: block.bodyBlock,
    callArgs: {},
    scopeMode: { mode: "inline", parentScopeId: t.scopeId },
  });
  // Decode iter indices and write into the child's scope.
  let remaining = index;
  const child = ctx.state.threads[childId];
  if (child === undefined) return;
  const childScopeId = child.scopeId;
  for (let i = block.iters.length - 1; i >= 0; i--) {
    const iter = block.iters[i]!;
    const arr = iterables[i];
    if (arr === undefined || arr.kind !== "array") {
      throw new Error("engine.for: iter source is not an array");
    }
    const len = arr.elements.length;
    const digit = remaining % len;
    remaining = Math.floor(remaining / len);
    const elem = arr.elements[digit]!;
    setValueInScope(ctx, childScopeId, iter[0], elem);
  }
}

function emitForDone(
  ctx: StepCtx,
  t: ForThread,
  value: Value,
): void {
  const block = getForBlock(ctx, t.blockId);
  if (block.thenBlock !== undefined) {
    const thenCallId = allocCallId(t);
    t.thenCallId = thenCallId;
    spawnChild(ctx, {
      parentId: t.id,
      parentCallId: thenCallId,
      blockId: block.thenBlock,
      callArgs: {},
      scopeMode: { mode: "inline", parentScopeId: t.scopeId },
    });
    return;
  }
  if (t.parent !== null && t.parentCallId !== null) {
    ctx.enqueue({
      kind: "done",
      target: t.parent,
      callId: t.parentCallId,
      value,
    });
  }
}

function handleBreakFor(
  ctx: StepCtx,
  t: ForThread,
  value: Value,
): void {
  if (t.status === "cancelling") return;
  t.pendingReturn = value;
  beginCancel(ctx, t);
}

function handleNextFor(
  ctx: StepCtx,
  t: ForThread,
  mods: ModMap | undefined,
  childCallId: CallId,
): void {
  if (mods !== undefined) {
    for (const [varKey, value] of Object.entries(mods)) {
      setValueInScope(ctx, t.scopeId, Number(varKey), value);
    }
  }
  // Issue a targeted cancel to the body iteration whose descendant
  // emitted the ask. The childCallId on the inbound ask is the immediate
  // child (i.e. the body iteration for the current index).
  const childId = t.children[childCallId];
  if (childId === undefined) {
    // Body already gone — race. Just advance.
    return;
  }
  t.postCancelActions[childCallId] = { kind: "finish" };
  ctx.enqueue({ kind: "cancel", target: childId });
}

