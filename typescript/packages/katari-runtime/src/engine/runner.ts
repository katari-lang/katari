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
import { createEscalationId } from "./id.js";
import type { Diff } from "./diff.js";
import { spawnAgentRoot } from "./spawn.js";
import { decodeCoreAgentDefId, encodeCoreAgentDefId } from "../agent-def-id.js";
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
 * Process a single inbound event against `state` and drain only the
 * **internal** event queue (thread-tree control: create / done / cancel
 * / cancelAck / ask / askAck). Cross-module events emitted via
 * `ctx.emit(...)` accumulate on `buffers.outbound` and are returned
 * as-is — including self-targeted ones (= CORE→CORE).
 *
 * The host's bus loops self-targeted outbound events back into another
 * `drive(...)` call. The engine itself never special-cases self routing.
 *
 * `initial` may be either an external event (= one of the 6 cross-module
 * events) or an internal event (only used by tests / pre-Bus call sites).
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

  let current = state;
  if (!isInternal(initial.payload)) {
    current = applyTranslateExternal(current, buffers, initial, allPatches);
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
        // Emit a throw escalate back to the sender so they can surface
        // the error (e.g. agent entry not found → API Module marks agent
        // as error). Only meaningful for `delegate` events; other payload
        // kinds that error here are dropped silently.
        if (!isInternal(event.payload) && event.payload.kind === "delegate") {
          ctx.emit({
            from: ctx.state.selfEndpoint,
            to: event.from,
            payload: {
              kind: "escalate",
              delegationId: event.payload.delegationId,
              escalationId: createEscalationId(),
              agentDefId: encodeCoreAgentDefId({ kind: "qname", value: "prim.throw" }),
              args: { msg: { kind: "string", value: err.message } },
            },
          });
        }
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
    const target = resolveDelegateTarget(ctx, p.agentDefId, p.delegationId);
    const agentThreadId = spawnAgentRoot(ctx, {
      blockId: target.blockId,
      args: p.args,
      delegationId: p.delegationId,
      capturedScopeId: target.capturedScopeId,
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
    // back. Resolve agentDefId → ReqId via IRModule.entries when it's a
    // qname-encoded request; closure-encoded escalates are not yet
    // handle-routable and fall back to reqId 0 (caught only by handlers
    // installed at reqId 0, mostly a debug fallback).
    const draft = ext as import("immer").Draft<typeof ext>;
    const ownAskId = (draft.nextAskId as number) as import("./id.js").AskId;
    draft.nextAskId = ((draft.nextAskId as number) + 1) as import("./id.js").AskId;
    draft.pendingEscalations[ownAskId as unknown as number] =
      p.escalationId as import("./id.js").EscalationId;
    // NOTE on the global owner index: do NOT write 'escalationOwners'
    // here. In a CORE→CORE round-trip the same escalationId is
    // registered first by 'emitEscalateUpward' on the SENDER thread
    // (T_A) and then again here on the RECEIVER bookkeeping thread
    // (T_B). The owner index must remain pointing at T_A because the
    // eventual inbound 'escalateAck' has to deliver its askAck to T_A
    // (= the original sender's pending askId). Overwriting with T_B's
    // id would route the ack to the wrong end and strand T_A. In
    // cross-module cases (FFI→CORE) the matching escalateAck is
    // OUTBOUND, never inbound, so the owner index is not consulted.
    ctx.enqueue({
      kind: "ask",
      target: ext.parent,
      askId: ownAskId,
      askKind: {
        kind: "request",
        reqId: resolveRequestReqId(ctx, p.agentDefId),
        args: { ...p.args },
      },
      childCallId: ext.parentCallId,
    });
    return;
  }

  if (p.kind === "escalateAck") {
    // Resolve the owning thread via the global `escalationOwners`
    // index (O(1)) instead of scanning every thread's
    // `pendingEscalations` map. The index is populated alongside the
    // per-thread map at registration time in 'emitEscalateUpward' and
    // the inbound-escalate branch above; on load() of an older
    // checkpoint, snapshot.ts rebuilds it from existing thread maps.
    const ownerId =
      ctx.state.escalationOwners[p.escalationId as unknown as string];
    if (ownerId !== undefined) {
      const t = ctx.state.threads[ownerId];
      if (t !== undefined && (t.kind === "external" || t.kind === "agent")) {
        const askIdNum = findEscalationAskId(
          t.pendingEscalations,
          p.escalationId as string,
        );
        if (askIdNum !== undefined) {
          delete t.pendingEscalations[askIdNum];
          delete ctx.state.escalationOwners[
            p.escalationId as unknown as string
          ];
          ctx.enqueue({
            kind: "askAck",
            target: t.id,
            askId: askIdNum as AskId,
            value: p.value,
          });
          return;
        }
      }
      // Index was stale (owner thread gone / wrong kind). Clean it
      // up and fall through to the debug log.
      delete ctx.state.escalationOwners[p.escalationId as unknown as string];
    }
    ctx.log("debug", "engine: escalateAck without registered escalation", {
      escalationId: p.escalationId,
    });
    return;
  }

  ctx.log("debug", "engine: unrecognized external event kind", { kind: p.kind });
}

/**
 * Resolve a CORE-encoded `agentDefId` to a target BlockAgent.
 *
 *   - `{ kind: "qname",   value }` → `IRModule.entries` lookup (top-level)
 *   - `{ kind: "closure", value }` → `state.closures` lookup (closure dispatch)
 *
 * The `capturedScopeId` is non-null only for closure dispatch; the new
 * AgentThread's body scope inherits from it so captured locals are visible.
 */
function resolveDelegateTarget(
  ctx: ReturnType<typeof makeStepCtx>,
  agentDefId: import("../agent-def-id.js").AgentDefId,
  delegationId: import("./id.js").DelegationId,
): {
  blockId: import("../ir/types.js").BlockId;
  capturedScopeId: import("./id.js").ScopeId | null;
} {
  const decoded = decodeCoreAgentDefId(agentDefId);
  if (decoded.kind === "qname") {
    const qn = decoded.value;
    const blockId = ctx.state.irModule.entries[qn];
    if (blockId === undefined) {
      throw new EntryNotFoundError(qn, delegationId);
    }
    return { blockId, capturedScopeId: null };
  }
  // kind === "closure"
  const record = ctx.state.closures[decoded.value as unknown as number];
  if (record === undefined) {
    // A stale `delegate` referencing a GC'd closure is a per-agent
    // recoverable error (= the original closure is no longer alive),
    // not an engine invariant violation. Throw the recoverable variant
    // so the runner converts it into a `prim.throw` escalate; the
    // previous raw `Error` poisoned the whole snapshot.
    throw new RecoverableEngineError(
      `engine.runner: closure ${decoded.value} not found for delegate ${delegationId} (closure may have been GC'd)`,
    );
  }
  return {
    blockId: record.blockId,
    capturedScopeId: record.scopeId,
  };
}

/**
 * Decode an inbound `escalate`'s `agentDefId` into the request
 * 'QualifiedName' used by handle scopes for dispatch. Since
 * 'emitEscalateUpward' ships the qname directly (Phase 2.A unified
 * 'reqId' with 'QualifiedName'), the decode is a thin wrapper that
 * returns a sentinel for closure-encoded ids — those have no qname-side
 * handler.
 */
function resolveRequestReqId(
  ctx: ReturnType<typeof makeStepCtx>,
  agentDefId: import("../agent-def-id.js").AgentDefId,
): import("../ir/types.js").QualifiedName {
  const sentinel = "<unresolved>.<unresolved>";
  let decoded: import("../agent-def-id.js").CoreAgentDefId | undefined;
  try {
    decoded = decodeCoreAgentDefId(agentDefId);
  } catch (err) {
    ctx.log("warn", "engine: escalate carried an undecodable agentDefId", {
      agentDefId,
      err: err instanceof Error ? err.message : String(err),
    });
    return sentinel;
  }
  if (decoded.kind !== "qname") {
    // Closure-encoded escalate targets have no handle-scope handler
    // (only qname-keyed handlers are registered). Returning a sentinel
    // routes the ask to a handler at reqId=0 (= debug fallback only).
    // Surface this so a misconfigured ext agent surface doesn't silently
    // misroute requests.
    ctx.log(
      "warn",
      "engine: escalate carried a closure-encoded agentDefId; no handle-scope dispatch possible",
      { agentDefId },
    );
    return sentinel;
  }
  return decoded.value;
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
