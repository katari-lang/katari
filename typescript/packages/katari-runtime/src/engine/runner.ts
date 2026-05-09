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
import type { CallId, ThreadId, AskId } from "./id.js";
import type { Diff } from "./diff.js";
import { spawnAgentRoot } from "./spawn.js";
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
 * `initial` may be any Event (internal or external). External events
 * with `to === selfEndpoint` are translated locally (this is how
 * core→core agent dispatch works); other external events go through
 * `translateExternal` once for the initial event.
 *
 * Self-loop handling: any outbound events emitted during the drain
 * whose `to` matches `state.selfEndpoint` are looped back through
 * `translateExternal` after the queue settles. This lets a single
 * `applyEvent` resolve an entire same-machine agent-call chain
 * (StatementAgentCall → delegate → AgentThread spawn → … → delegateAck
 *  → done → resume caller) without round-tripping through the host.
 * Cross-machine events (to !== selfEndpoint) remain in `outbound` for
 * the host to deliver.
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
    current = applyTranslateExternal(current, buffers, initial, allPatches);
  } else {
    buffers.queue.push(initial.payload);
  }

  while (true) {
    // Drain the internal event queue.
    while (buffers.queue.length > 0) {
      const ev = buffers.queue.shift()!;
      const [next, patches] = produceWithPatches(current, (draft) => {
        const ctx = makeStepCtx(draft, buffers);
        step(ctx, ev);
      });
      allPatches.push(...patches);
      current = next;
    }

    // After the queue is empty, peel off any self-targeted outbound
    // events and feed them back through `translateExternal`. Each
    // translated event may push fresh internal events back onto the
    // queue, so we re-enter the outer loop until everything settles.
    const selfEvents: Event[] = [];
    const remaining: Event[] = [];
    for (const ev of buffers.outbound) {
      if (ev.to === current.selfEndpoint) {
        selfEvents.push(ev);
      } else {
        remaining.push(ev);
      }
    }
    if (selfEvents.length === 0) break;
    buffers.outbound = remaining;
    for (const ev of selfEvents) {
      current = applyTranslateExternal(current, buffers, ev, allPatches);
    }
  }

  return { state: current, buffers, patches: allPatches };
}

/**
 * Run `translateExternal` against the current state, accumulating its
 * patches into `allPatches` and returning the next state. Recoverable
 * errors raised inside translation are recorded; anything else
 * propagates.
 */
function applyTranslateExternal(
  current: State,
  buffers: StepBuffers,
  event: Event,
  allPatches: Patch[],
): State {
  const [next, patches] = produceWithPatches(current, (draft) => {
    const ctx = makeStepCtx(draft, buffers);
    try {
      translateExternal(ctx, event);
    } catch (err) {
      if (err instanceof RecoverableEngineError) {
        ctx.recordError(err);
      } else {
        throw err;
      }
    }
  });
  allPatches.push(...patches);
  return next;
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
 * Translate an external Event into engine actions:
 *
 *   - `delegate` to self  → spawn an AgentThread and register
 *     `state.delegations[delegationId] = agentThreadId`
 *   - `terminate` to self → look up the thread under that delegationId
 *     and cancel it (whether the local owner is an AgentThread we spawned
 *     for an inbound delegate, or an ExternalThread that emitted an
 *     outbound delegate — same machinery either way)
 *   - `delegateAck` to self  → translate to a `done` event addressed at
 *     the local ExternalThread that owns the delegationId
 *   - `terminateAck` to self → translate to a `cancelAck` event addressed
 *     at the local ExternalThread's parent
 *   - `escalate` to self → forward to the AgentThread that owns the
 *     delegationId; AgentThread.ask routes the request through its body
 *   - `escalateAck` to self → match to ExternalThread.pendingEscalations
 *     and fire askAck back to the chain that originally bubbled the ask
 *
 * Anything addressed elsewhere (`event.to !== selfEndpoint`) is dropped
 * with a debug log — the runner only consumes its own inbound events.
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
    const blockId = resolveDelegateTarget(ctx, p.targetBlock, p.delegationId);
    const agentThreadId = spawnAgentRoot(ctx, {
      blockId,
      args: p.args,
      delegationId: p.delegationId,
    });
    ctx.state.delegations[p.delegationId as string] = agentThreadId;
    ctx.state.delegationSenders[p.delegationId as string] = event.from;
    return;
  }

  if (p.kind === "terminate") {
    const threadId = ctx.state.delegations[p.delegationId as string] as ThreadId | undefined;
    if (threadId === undefined) return;
    ctx.enqueue({ kind: "cancel", target: threadId });
    return;
  }

  if (p.kind === "delegateAck") {
    // Look up the sender side: the ExternalThread (real or phantom) that
    // issued the outbound delegate. The receiver-side AgentThread (if
    // any, for self→self) has already cleaned itself up before emitting
    // this ack.
    const threadId = ctx.state.pendingDelegateOut[p.delegationId as string] as
      | ThreadId
      | undefined;
    if (threadId === undefined) return;
    const ext = ctx.state.threads[threadId];
    if (ext === undefined || ext.kind !== "external") {
      ctx.log("debug", "engine: delegateAck for non-external thread", { kind: ext?.kind });
      return;
    }
    delete ctx.state.pendingDelegateOut[p.delegationId as string];
    if (ext.status === "cancelling") {
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
    const threadId = ctx.state.pendingDelegateOut[p.delegationId as string] as
      | ThreadId
      | undefined;
    if (threadId === undefined) return;
    const ext = ctx.state.threads[threadId];
    if (ext === undefined || ext.kind !== "external") return;
    delete ctx.state.pendingDelegateOut[p.delegationId as string];
    if (ext.parent !== null && ext.parentCallId !== null) {
      ctx.enqueue({ kind: "cancelAck", target: ext.parent, callId: ext.parentCallId });
    }
    return;
  }

  if (p.kind === "escalate") {
    // Inbound escalate: an external (the receiver side of one of OUR
    // outbound delegates) is asking us for a capability.
    //
    // We find the local sender ExternalThread (under
    // `pendingDelegateOut[delegationId]`) and inject the request as an
    // ask bubbling upward through that thread's parent chain — the same
    // path a request statement takes locally. The escalateAck round-trip
    // matches via `ExternalThread.pendingEscalations[escalationId]`.
    const threadId = ctx.state.pendingDelegateOut[p.delegationId as string] as
      | ThreadId
      | undefined;
    if (threadId === undefined) {
      ctx.log("debug", "engine: escalate for unknown delegationId", {
        delegationId: p.delegationId,
      });
      return;
    }
    const ext = ctx.state.threads[threadId];
    if (ext === undefined || ext.kind !== "external") {
      ctx.log("debug", "engine: escalate target not an ExternalThread", {
        kind: ext?.kind,
      });
      return;
    }
    if (ext.parent === null || ext.parentCallId === null) {
      ctx.log("warn", "engine: escalate at parentless external; dropping", {
        threadId: ext.id,
      });
      return;
    }
    // Allocate an own askId on the external for the upward forward, and
    // map (escalationId → ownAskId) so the eventual escalateAck can route
    // back. The request payload uses the placeholder reqId of `0` since
    // the receiving AgentThread looks up handlers by qualified name; the
    // concrete ReqId mapping will be provided once requests carry their
    // qname through the engine layer.
    const draft = ext as import("immer").Draft<typeof ext>;
    const ownAskId = (draft.nextAskId as number) as import("./id.js").AskId;
    draft.nextAskId = ((draft.nextAskId as number) + 1) as import("./id.js").AskId;
    draft.pendingEscalations[ownAskId as unknown as number] =
      p.escalationId as import("./id.js").EscalationId;
    ctx.enqueue({
      kind: "ask",
      target: ext.parent,
      askId: ownAskId,
      askKind: {
        kind: "request",
        reqId: 0 as import("../ir/types.js").ReqId,
        args: { ...p.args },
      },
      childCallId: ext.parentCallId,
    });
    return;
  }

  if (p.kind === "escalateAck") {
    // Find the ExternalThread holding this escalation in pendingEscalations.
    for (const t of Object.values(ctx.state.threads)) {
      if (t === undefined || t.kind !== "external") continue;
      const askIdNum = findEscalationAskId(t.pendingEscalations, p.escalationId as string);
      if (askIdNum === undefined) continue;
      delete t.pendingEscalations[askIdNum];
      // Fire askAck back to the chain that originally asked.
      ctx.enqueue({
        kind: "askAck",
        target: t.id,
        askId: askIdNum as AskId,
        value: p.value,
      });
      return;
    }
    ctx.log("debug", "engine: escalateAck without registered escalation", {
      escalationId: p.escalationId,
    });
    return;
  }

  ctx.log("debug", "engine: unrecognized external event kind", { kind: p.kind });
}

/**
 * Resolve a delegate `targetBlock` to a BlockId.
 *
 * - `module_ === "<closure>"` → the `name` is the BlockId stringified.
 *   Closure-based agent calls (`statementAgentCallClosure`) take this
 *   path — the BlockAgent body lives directly in IR; no entry lookup.
 * - otherwise the qualified name is resolved through `IRModule.entries`.
 */
function resolveDelegateTarget(
  ctx: ReturnType<typeof makeStepCtx>,
  target: { module_: string; name: string },
  delegationId: import("./id.js").DelegationId,
): import("../ir/types.js").BlockId {
  if (target.module_ === "<closure>") {
    return Number(target.name) as import("../ir/types.js").BlockId;
  }
  const qn = target.module_ === "" ? target.name : `${target.module_}.${target.name}`;
  const blockId = ctx.state.irModule.entries[qn];
  if (blockId === undefined) {
    throw new EntryNotFoundError(qn, delegationId);
  }
  return blockId;
}

function findEscalationAskId(
  pendingEscalations: Record<number, import("./id.js").EscalationId>,
  escalationId: string,
): number | undefined {
  for (const [askIdStr, esc] of Object.entries(pendingEscalations)) {
    if ((esc as string) === escalationId) return Number(askIdStr);
  }
  return undefined;
}

// `CallId` referenced via signatures.
void (null as unknown as CallId);

// ─── Patches → Diff translation ────────────────────────────────────────────

/**
 * Translate Immer's low-level Patch[] to our domain Diff[].
 *
 * Immer patches are JSON-Pointer style:
 *   { op: "replace" | "add" | "remove", path: (string | number)[], value? }
 *
 * The host layer no longer consumes these (DiffRepo was removed) but we
 * keep the translation for future audit/replay use.
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
    }
  }
  return diffs;
}
