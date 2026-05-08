// Runner: drives the internal event queue inside one applyEvent call.
//
// The runner doesn't know about Thread variants; it dispatches each event
// to the per-method routing in `thread/ops/index.ts`. State updates pass
// through Immer's `produceWithPatches` so we get diff information for free.
//
// Stale-event semantics: events targeting a thread that was already
// removed from `state.threads` are dropped silently with a debug log
// (matches the previous engine's behaviour).

import { produceWithPatches, enablePatches, type Patch } from "immer";
import { match } from "ts-pattern";
import type { Event, InternalEventPayload } from "./event.js";
import { isInternal } from "./event.js";
import type { Diff } from "./diff.js";
import type { State } from "./state.js";
import {
  emptyBuffers,
  makeStepCtx,
  type StepBuffers,
} from "./step-ctx.js";
import type { Thread } from "./thread/types.js";
import {
  dispatchAsk,
  dispatchAskAck,
  dispatchCancel,
  dispatchCancelAck,
  dispatchCreate,
  dispatchDone,
} from "./thread/ops/index.js";

// Immer patch generation is opt-in.
enablePatches();

/**
 * Drive the event queue starting with `initial`. Returns the new state
 * plus the side-effects accumulated during the drain.
 *
 * `initial` may be any Event (internal or external). External events are
 * silently ignored at the engine layer — the host translates them into
 * internal events before feeding the engine.
 */
export function drive(
  state: State,
  initial: Event,
): {
  state: State;
  buffers: StepBuffers;
  patches: Patch[];
} {
  const buffers = emptyBuffers();
  const allPatches: Patch[] = [];

  // External events are the host's job to translate. Drop here.
  if (!isInternal(initial.payload)) {
    buffers.logs.push({
      level: "debug",
      message: "engine: ignoring non-internal inbound event",
      context: { kind: initial.payload.kind, from: initial.from, to: initial.to },
    });
    return { state, buffers, patches: [] };
  }

  buffers.queue.push(initial.payload);

  let current = state;
  while (buffers.queue.length > 0) {
    const ev = buffers.queue.shift()!;
    const [next, patches] = produceWithPatches(current, (draft) => {
      const ctx = makeStepCtx(draft, buffers);
      step(ctx, ev);
    });
    allPatches.push(...patches);
    current = next;
  }

  return { state: current, buffers, patches: allPatches };
}

// ─── Single-step dispatch ──────────────────────────────────────────────────

function step(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: InternalEventPayload,
): void {
  match(ev)
    .with({ kind: "create" }, e => onCreate(ctx, e))
    .with({ kind: "done" }, e => onDone(ctx, e))
    .with({ kind: "cancel" }, e => onCancel(ctx, e))
    .with({ kind: "cancelAck" }, e => onCancelAck(ctx, e))
    .with({ kind: "ask" }, e => onAsk(ctx, e))
    .with({ kind: "askAck" }, e => onAskAck(ctx, e))
    .exhaustive();
}

// `create` event: the spawning code already wrote the Thread record into
// state.threads. Our job is just to invoke the variant's create op.
function onCreate(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "create" }>,
): void {
  const t = ctx.state.threads[ev.threadId] as import("immer").Draft<Thread> | undefined;
  if (t === undefined) {
    throw new Error(
      `engine: create event for ${ev.threadId} but no thread record present`,
    );
  }
  dispatchCreate(ctx, t);
}

function onDone(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "done" }>,
): void {
  const t = ctx.state.threads[ev.target] as import("immer").Draft<Thread> | undefined;
  if (t === undefined) {
    ctx.log("debug", "engine: stale done dropped", { target: ev.target });
    return;
  }
  dispatchDone(ctx, t, ev.callId, ev.value);
}

function onCancel(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "cancel" }>,
): void {
  const t = ctx.state.threads[ev.target] as import("immer").Draft<Thread> | undefined;
  if (t === undefined) {
    ctx.log("debug", "engine: stale cancel dropped", { target: ev.target });
    return;
  }
  dispatchCancel(ctx, t);
}

function onCancelAck(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "cancelAck" }>,
): void {
  const t = ctx.state.threads[ev.target] as import("immer").Draft<Thread> | undefined;
  if (t === undefined) {
    ctx.log("debug", "engine: stale cancelAck dropped", { target: ev.target });
    return;
  }
  dispatchCancelAck(ctx, t, ev.callId);
}

function onAsk(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "ask" }>,
): void {
  const t = ctx.state.threads[ev.target] as import("immer").Draft<Thread> | undefined;
  if (t === undefined) {
    ctx.log("debug", "engine: stale ask dropped", { target: ev.target, askId: ev.askId });
    return;
  }
  dispatchAsk(ctx, t, ev.askId, ev.askKind, ev.childCallId);
}

function onAskAck(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "askAck" }>,
): void {
  const t = ctx.state.threads[ev.target] as import("immer").Draft<Thread> | undefined;
  if (t === undefined) {
    ctx.log("debug", "engine: stale askAck dropped", { target: ev.target, askId: ev.askId });
    return;
  }
  dispatchAskAck(ctx, t, ev.askId, ev.value);
}

// ─── Patches → Diff translation ────────────────────────────────────────────

/**
 * Translate Immer's low-level Patch[] to our domain Diff[].
 *
 * Immer patches are JSON-Pointer style:
 *   { op: "replace" | "add" | "remove", path: (string | number)[], value? }
 *
 * For Stage A we recognize the common cases and emit `thread.update` with
 * the raw patch under `patch` for everything else. The host layer can
 * either consume these as-is or post-process them into row-level upserts.
 */
export function patchesToDiffs(patches: Patch[]): Diff[] {
  const diffs: Diff[] = [];
  for (const p of patches) {
    const path = p.path;
    if (path.length === 0) continue;
    const root = path[0] as string;
    if (root === "threads") {
      const threadId = path[1] as import("./id.js").ThreadId;
      if (path.length === 2 && p.op === "add") {
        diffs.push({ op: "thread.create", threadId, data: p.value as Thread });
      } else if (path.length === 2 && p.op === "remove") {
        diffs.push({ op: "thread.delete", threadId });
      } else {
        diffs.push({ op: "thread.update", threadId, patch: p });
      }
    } else if (root === "scopes") {
      const scopeId = path[1] as import("./id.js").ScopeId;
      if (path.length === 2 && p.op === "add") {
        diffs.push({
          op: "scope.create",
          scopeId,
          data: p.value as import("./scope.js").Scope,
        });
      } else if (path.length === 2 && p.op === "remove") {
        diffs.push({ op: "scope.delete", scopeId });
      } else if (
        path.length === 4 &&
        path[2] === "values" &&
        (p.op === "add" || p.op === "replace")
      ) {
        diffs.push({
          op: "scope.set",
          scopeId,
          varId: Number(path[3]),
          value: p.value as import("./value.js").Value,
        });
      }
      // Other scope-internal patches roll into the snapshot via
      // `scope.create` semantics on rebuild — the host can replay the
      // raw Immer patch separately if needed.
    }
  }
  return diffs;
}
