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
import { EntryNotFoundError, RecoverableEngineError } from "./errors.js";
import type { Event, InternalEventPayload } from "./event.js";
import { isInternal } from "./event.js";
import { createScopeId, createThreadId, type CallId, type ScopeId, type ThreadId, type AskId } from "./id.js";
import type { Diff } from "./diff.js";
import type { State } from "./state.js";
import {
  emptyBuffers,
  makeStepCtx,
  type StepBuffers,
} from "./step-ctx.js";
import type { Thread, UserThread } from "./thread/types.js";
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

  // External events go through a translation step that may register
  // delegation indexes / spawn root threads / etc. before the runner
  // proper sees them. Internal events are queued directly.
  let current = state;
  if (!isInternal(initial.payload)) {
    const [next, patches] = produceWithPatches(current, (draft) => {
      const ctx = makeStepCtx(draft, buffers);
      try {
        translateExternal(ctx, initial);
      } catch (err) {
        if (err instanceof RecoverableEngineError) {
          ctx.recordError(err);
        } else {
          throw err;
        }
      }
    });
    allPatches.push(...patches);
    current = next;
  } else {
    buffers.queue.push(initial.payload);
  }

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

// ─── External event translation ────────────────────────────────────────────

/**
 * Translate an external Event (`from` / `to` not both equal to selfEndpoint)
 * into one or more internal events. Mutates the draft directly to register
 * delegation indexes / spawn root threads.
 *
 * Recognized:
 *   - `delegate` to self → spawn root user thread + register apiDelegations
 *   - `terminate` to self → cancel the root thread for that delegationId
 *   - `delegateAck` to self → done (or cancelAck if cancelling) for the
 *     ExternalThread for that delegationId
 *   - `terminateAck` to self → cancelAck for the ExternalThread for that delegationId
 *
 * Anything else (including events whose `to` is not selfEndpoint) is logged
 * and dropped.
 */
function translateExternal(
  ctx: ReturnType<typeof makeStepCtx>,
  event: Event,
): void {
  if (event.to !== ctx.state.selfEndpoint) {
    ctx.log("debug", "engine: external event dropped (to !== self)", {
      kind: event.payload.kind,
      to: event.to,
    });
    return;
  }
  const p = event.payload;
  if (p.kind === "delegate") {
    spawnApiRoot(ctx, p.targetBlock, p.args, p.delegationId, event.from);
    return;
  }
  if (p.kind === "terminate") {
    const threadId = ctx.state.apiDelegations[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) return;
    ctx.enqueue({ kind: "cancel", target: threadId });
    return;
  }
  if (p.kind === "delegateAck") {
    const threadId = ctx.state.ffiDelegations[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) return;
    const ext = ctx.state.threads[threadId];
    if (ext === undefined || ext.kind !== "external") return;
    delete ctx.state.ffiDelegations[p.delegationId];
    if (ext.status === "cancelling") {
      // Late delegateAck during cancellation: drop the value, ack as cancel.
      if (ext.parent !== null && ext.parentCallId !== null) {
        ctx.enqueue({ kind: "cancelAck", target: ext.parent, callId: ext.parentCallId });
      }
    } else {
      if (ext.parent !== null && ext.parentCallId !== null) {
        ctx.enqueue({
          kind: "done",
          target: ext.parent,
          callId: ext.parentCallId,
          value: p.value,
        });
      }
    }
    return;
  }
  if (p.kind === "terminateAck") {
    const threadId = ctx.state.ffiDelegations[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) return;
    const ext = ctx.state.threads[threadId];
    if (ext === undefined || ext.kind !== "external") return;
    delete ctx.state.ffiDelegations[p.delegationId];
    if (ext.parent !== null && ext.parentCallId !== null) {
      ctx.enqueue({ kind: "cancelAck", target: ext.parent, callId: ext.parentCallId });
    }
    return;
  }
  ctx.log("debug", "engine: unrecognized external event kind", { kind: p.kind });
}

/**
 * Allocate a fresh root UserThread for the given entry block and register
 * it under apiDelegations. Throws `EntryNotFoundError` (Recoverable) if
 * the qualified name doesn't exist in the IR.
 */
function spawnApiRoot(
  ctx: ReturnType<typeof makeStepCtx>,
  targetBlock: { module_: string; name: string },
  args: Record<string, import("./value.js").Value>,
  delegationId: string,
  sender: import("./endpoint.js").Endpoint,
): void {
  const qn =
    targetBlock.module_ === ""
      ? targetBlock.name
      : `${targetBlock.module_}.${targetBlock.name}`;
  const blockId = ctx.state.irModule.entries[qn];
  if (blockId === undefined) {
    throw new EntryNotFoundError(qn, delegationId as import("./id.js").DelegationId);
  }
  const block = ctx.state.irModule.blocks[String(blockId)];
  if (block === undefined || block.kind !== "blockUser") {
    throw new RecoverableEngineError(
      `engine.spawnApiRoot: entry "${qn}" maps to block ${blockId}, but it is not a blockUser (${block?.kind})`,
      delegationId as import("./id.js").DelegationId,
    );
  }

  const threadId = createThreadId();
  const scopeId = createScopeId();
  ctx.state.scopes[scopeId] = { id: scopeId, parentId: null, values: {} };

  // Bind args into the new scope by parameter label.
  for (const param of block.body.parameters) {
    const v = args[param.label];
    if (v !== undefined) {
      ctx.state.scopes[scopeId]!.values[param.var] = v;
    }
  }

  const root: UserThread = {
    kind: "user",
    id: threadId,
    parent: null,
    parentCallId: null,
    scopeId,
    status: "running",
    children: {},
    handlers: {},
    nextCallId: 0 as CallId,
    nextAskId: 0 as AskId,
    askIdMap: {},
    blockId: blockId as import("../ir/types.js").BlockId,
    pc: 0,
    catchesReturn: block.body.kind === "blockKindAgent",
  };
  ctx.state.threads[threadId] = root;
  ctx.state.apiDelegations[delegationId] = threadId;
  ctx.state.apiDelegationSenders[delegationId] = sender;

  ctx.enqueue({ kind: "create", threadId });
}

/** Used by spawn.ts and the External thread's outbound emission. */
export function findApiDelegationByThreadId(
  state: State,
  threadId: ThreadId,
): { delegationId: string; sender: import("./endpoint.js").Endpoint } | undefined {
  for (const [did, tid] of Object.entries(state.apiDelegations)) {
    if (tid === threadId) {
      const sender = state.apiDelegationSenders[did];
      if (sender !== undefined) return { delegationId: did, sender };
    }
  }
  return undefined;
}

// `ScopeId` referenced indirectly via spawnApiRoot.
void (null as unknown as ScopeId);

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
