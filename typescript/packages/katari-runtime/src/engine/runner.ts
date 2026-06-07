// Runner: drives the internal event queue inside one applyEvent call.
//
// The runner doesn't know about Thread variants; it dispatches each event
// to the per-method routing in `thread/ops/index.ts`. State is mutated in
// place. An irrecoverable throw mid-drain therefore leaves the State
// half-mutated: the per-feed tx rolls back the DB side, and CoreModule
// evicts the poisoned shard from its warm cache so the next feed reloads a
// clean copy from the (rolled-back) DB. (Recoverable errors never reach
// here — `applyTranslateExternal` converts them into a throw escalate.)
//
// Stale-event semantics: events targeting a thread that was already
// removed from `state.threads` are dropped silently with a debug log
// (matches the previous engine's behaviour).

import {
  decodeCoreAgentDefId,
  encodeCoreAgentDefId,
  THROW_REQUEST_QNAME,
} from "../agent-def-id.js";
import { EntryNotFoundError, RecoverableEngineError } from "./errors.js";
import type { Event, InternalEventPayload } from "./event.js";
import { isInternal } from "./event.js";
import type { AskId, ThreadId } from "./id.js";
import { createEscalationId } from "./id.js";
import { spawnAgentRoot } from "./spawn.js";
import type { State } from "./state.js";
import {
  emptyBuffers,
  makeStepCtx,
  type RefFetcher,
  type RefPutter,
  type StepBuffers,
} from "./step-ctx.js";
import {
  dispatchAsk,
  dispatchAskAck,
  dispatchCancel,
  dispatchCancelAck,
  dispatchCreate,
  dispatchDone,
} from "./thread/ops/index.js";
import type { Thread } from "./thread/types.js";
import { mkRecord, mkString } from "./value.js";

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
export async function drive(
  state: State,
  initial: Event,
  fetchRef?: RefFetcher,
  putRef?: RefPutter,
): Promise<{
  state: State;
  buffers: StepBuffers;
}> {
  const buffers = emptyBuffers();
  const ctx = makeStepCtx(state, buffers, fetchRef, putRef);

  if (!isInternal(initial.payload)) {
    applyTranslateExternal(ctx, initial);
  } else {
    buffers.queue.push(initial.payload);
  }

  while (buffers.queue.length > 0) {
    const ev = buffers.queue.shift()!;
    await step(ctx, ev);
  }

  return { state, buffers };
}

/**
 * Run `translateExternal` against the live state. Recoverable errors
 * raised inside translation are recorded; anything else propagates.
 */
function applyTranslateExternal(ctx: ReturnType<typeof makeStepCtx>, event: Event): void {
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
            agentDefId: encodeCoreAgentDefId({ kind: "qname", value: THROW_REQUEST_QNAME }),
            argument: mkRecord({ msg: mkString(err.message) }),
          },
        });
      }
    } else {
      throw err;
    }
  }
}

// ─── Single-step dispatch ──────────────────────────────────────────────────

async function step(ctx: ReturnType<typeof makeStepCtx>, ev: InternalEventPayload): Promise<void> {
  switch (ev.kind) {
    case "create":
      // Only `create` can be async (prim materialize); the other internal
      // events spawn work via the queue rather than evaluating prims inline.
      await onCreate(ctx, ev);
      break;
    case "done":
      onDone(ctx, ev);
      break;
    case "cancel":
      onCancel(ctx, ev);
      break;
    case "cancelAck":
      onCancelAck(ctx, ev);
      break;
    case "ask":
      onAsk(ctx, ev);
      break;
    case "askAck":
      onAskAck(ctx, ev);
      break;
    default: {
      const _exhaustive: never = ev;
      throw new Error(
        `engine: unrecognized internal event kind: ${(_exhaustive as InternalEventPayload).kind}`,
      );
    }
  }
}

// `create` event: the spawning code already wrote the Thread record into
// state.threads. Our job is just to invoke the variant's create op.
async function onCreate(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "create" }>,
): Promise<void> {
  const t = ctx.state.threads[ev.threadId] as Thread | undefined;
  if (t === undefined) {
    throw new Error(`engine: create event for ${ev.threadId} but no thread record present`);
  }
  await dispatchCreate(ctx, t);
}

function onDone(
  ctx: ReturnType<typeof makeStepCtx>,
  ev: Extract<InternalEventPayload, { kind: "done" }>,
): void {
  const t = ctx.state.threads[ev.target] as Thread | undefined;
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
  const t = ctx.state.threads[ev.target] as Thread | undefined;
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
  const t = ctx.state.threads[ev.target] as Thread | undefined;
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
  const t = ctx.state.threads[ev.target] as Thread | undefined;
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
  const t = ctx.state.threads[ev.target] as Thread | undefined;
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
 *     for an inbound delegate, or an DelegateThread that emitted an
 *     outbound delegate — same machinery either way)
 *   - `delegateAck` to self  → translate to a `done` event addressed at
 *     the local DelegateThread that owns the delegationId
 *   - `terminateAck` to self → translate to a `cancelAck` event addressed
 *     at the local DelegateThread's parent
 *   - `escalate` to self → forward to the AgentThread that owns the
 *     delegationId; AgentThread.ask routes the request through its body
 *   - `escalateAck` to self → look up the owning AgentThread root via
 *     `escalationOwners`, retrieve the original askId from its
 *     `outboundEscalations[escalationId]`, and fire askAck back to the
 *     chain that originally bubbled the ask
 *
 * Anything addressed elsewhere (`event.to !== selfEndpoint`) is dropped
 * with a debug log — the runner only consumes its own inbound events.
 */
function translateExternal(ctx: ReturnType<typeof makeStepCtx>, event: Event): void {
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
      argument: p.argument,
      delegationId: p.delegationId,
      capturedScopeId: target.capturedScopeId,
      ambientGenerics: p.generics,
    });
    ctx.state.delegations[p.delegationId] = agentThreadId;
    ctx.state.delegationSenders[p.delegationId] = event.from;
    return;
  }

  if (p.kind === "terminate") {
    const threadId = ctx.state.delegations[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) return;
    ctx.enqueue({ kind: "cancel", target: threadId });
    return;
  }

  if (p.kind === "delegateAck") {
    // Look up the sender side: the thread that issued the outbound
    // delegate. Two kinds: a normal `DelegateThread` (statement call to
    // a delegate block) or a `CallAgentThread` (the dynamic
    // `call_agent` prim). Both follow the same finishing pattern —
    // forward done / cancelAck and clear the pending-out entry.
    const threadId = ctx.state.pendingDelegateOut[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) return;
    const sender = ctx.state.threads[threadId];
    if (sender === undefined || (sender.kind !== "delegate" && sender.kind !== "callAgent")) {
      ctx.log("debug", "engine: delegateAck for non-delegate thread", { kind: sender?.kind });
      return;
    }
    delete ctx.state.pendingDelegateOut[p.delegationId];
    if (sender.status === "cancelling") {
      if (sender.parent !== null && sender.parentCallId !== null) {
        ctx.enqueue({ kind: "cancelAck", target: sender.parent, callId: sender.parentCallId });
      }
    } else {
      if (sender.parent !== null && sender.parentCallId !== null) {
        ctx.enqueue({
          kind: "done",
          target: sender.parent,
          callId: sender.parentCallId,
          value: p.value,
        });
      }
    }
    return;
  }

  if (p.kind === "terminateAck") {
    const threadId = ctx.state.pendingDelegateOut[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) return;
    const sender = ctx.state.threads[threadId];
    if (sender === undefined || (sender.kind !== "delegate" && sender.kind !== "callAgent")) {
      return;
    }
    delete ctx.state.pendingDelegateOut[p.delegationId];
    if (sender.parent !== null && sender.parentCallId !== null) {
      ctx.enqueue({ kind: "cancelAck", target: sender.parent, callId: sender.parentCallId });
    }
    return;
  }

  if (p.kind === "escalate") {
    // Inbound escalate: the receiver side of one of OUR outbound
    // delegates is asking us for a capability.
    //
    // Find the local sender DelegateThread (under
    // `pendingDelegateOut[delegationId]`) and inject the request as an
    // ask bubbling upward through that thread's parent chain — the same
    // path a request statement takes locally. The escalateAck round-trip
    // matches via `DelegateThread.inboundEscalations[askId]`.
    const threadId = ctx.state.pendingDelegateOut[p.delegationId] as ThreadId | undefined;
    if (threadId === undefined) {
      ctx.log("debug", "engine: escalate for unknown delegationId", {
        delegationId: p.delegationId,
      });
      return;
    }
    const sender = ctx.state.threads[threadId];
    if (sender === undefined || (sender.kind !== "delegate" && sender.kind !== "callAgent")) {
      ctx.log("debug", "engine: escalate target not a DelegateThread / CallAgentThread", {
        kind: sender?.kind,
      });
      return;
    }
    if (sender.parent === null || sender.parentCallId === null) {
      ctx.log("warn", "engine: escalate at parentless delegate; dropping", {
        threadId: sender.id,
      });
      return;
    }
    if (p.control !== undefined) {
      // A CONTROL-flow unwind (return / break / next / …) crossing INTO this
      // delegation from a sub-delegation (e.g. a `use` continuation), bound for
      // a lexical ancestor. Re-emit it as an upward `ask` through the sender's
      // parent — `p.control` IS the AskKind (value / target / mods inline). No
      // `inboundEscalations` / escalateAck bookkeeping: a control unwind never
      // resumes the asker. The eventual catch above cancel-cascades a
      // `terminate` back down, which tears the sub-delegation down normally.
      const ownAskId = sender.nextAskId as number as AskId;
      sender.nextAskId = ((sender.nextAskId as number) + 1) as AskId;
      ctx.enqueue({
        kind: "ask",
        target: sender.parent,
        askId: ownAskId,
        askKind: p.control,
        childCallId: sender.parentCallId,
      });
      return;
    }
    // Allocate an own askId for the upward forward, and map
    // (askId → escalationId) so the eventual askAck from above can be
    // turned back into an outbound escalateAck. Resolve agentDefId →
    // ReqId via IRModule.entries when it's a qname-encoded request;
    // closure-encoded escalates have no handle-scope dispatch and fall
    // back to a sentinel handled only by reqId-0 fallback handlers.
    const ownAskId = sender.nextAskId as number as import("./id.js").AskId;
    sender.nextAskId = ((sender.nextAskId as number) + 1) as import("./id.js").AskId;
    sender.inboundEscalations[ownAskId] = p.escalationId as import("./id.js").EscalationId;
    // NOTE on the global owner index: do NOT write 'escalationOwners'
    // here. In a CORE→CORE round-trip the same escalationId is
    // registered first by 'emitEscalateUpward' on the SENDER thread
    // (T_A, the AgentThread root that started the escalation) and then
    // again here on the RECEIVER bookkeeping thread (T_B = this
    // DelegateThread). The owner index must remain pointing at T_A
    // because the eventual inbound 'escalateAck' must deliver its
    // askAck to T_A (= the original sender's pending askId). Overwriting
    // with T_B's id would route the ack to the wrong end and strand T_A.
    // In cross-module cases (FFI→CORE) the matching escalateAck is
    // OUTBOUND, never inbound, so the owner index is not consulted.
    ctx.enqueue({
      kind: "ask",
      target: sender.parent,
      askId: ownAskId,
      askKind: {
        kind: "request",
        reqId: resolveRequestReqId(ctx, p.agentDefId),
        argument: p.argument,
      },
      childCallId: sender.parentCallId,
    });
    return;
  }

  if (p.kind === "escalateAck") {
    // Resolve the owning AgentThread via the global `escalationOwners`
    // index. The owner is always an AgentThread (= the root that
    // originally issued the outbound escalate via emitEscalateUpward).
    // `outboundEscalations[escalationId]` gives the askId we need to use
    // when constructing the askAck — direct lookup, no linear scan.
    const ownerId = ctx.state.escalationOwners[p.escalationId];
    if (ownerId !== undefined) {
      const t = ctx.state.threads[ownerId];
      if (t !== undefined && t.kind === "agent") {
        const askId = t.outboundEscalations[p.escalationId];
        if (askId !== undefined) {
          delete t.outboundEscalations[p.escalationId];
          delete ctx.state.escalationOwners[p.escalationId];
          ctx.enqueue({
            kind: "askAck",
            target: t.id,
            askId: askId as AskId,
            value: p.value,
          });
          return;
        }
      }
      // Index was stale (owner thread gone / wrong kind). Clean it
      // up and fall through to the debug log.
      delete ctx.state.escalationOwners[p.escalationId];
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
  if (decoded.kind === "closureRef") {
    // CORE materializes a closure-ref delegate into a local closure (rewriting
    // the target to closure:N) BEFORE applyEvent — so the engine must never see
    // one. Reaching here is a host-side invariant violation.
    throw new Error(
      `engine.runner: closure-ref delegate ${delegationId} reached the engine unmaterialized (CORE must materialize it first)`,
    );
  }
  // kind === "closure"
  const record = ctx.state.closures[decoded.value];
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
