// Common helpers shared by every Thread variant's ops.
//
// The thread lifecycle is the same regardless of variant:
//   - children come and go via done / cancelAck
//   - cancel cascades to all children, then finishCancelling fires
//   - asks bubble up through proxies via askIdMap
// Variant-specific behavior (statement execution, ask catching, etc.)
// lives in the per-variant ops file. This module hosts the common code
// that each op delegates into.

import type { Draft } from "immer";
import {
  type AskId,
  type CallId,
  type ScopeId,
  type ThreadId,
  createEscalationId,
} from "../id.js";
import { encodeCoreAgentDefId } from "../../agent-def-id.js";
import type { Scope } from "../scope.js";
import type { StepCtx } from "../step-ctx.js";
import type { Value } from "../value.js";
import type {
  AskIdMap,
  Thread,
  ThreadStatus,
} from "./types.js";

// ─── Thread lookups ────────────────────────────────────────────────────────

export function getThread(ctx: StepCtx, id: ThreadId): Draft<Thread> | undefined {
  return ctx.state.threads[id] as Draft<Thread> | undefined;
}

export function requireThread(ctx: StepCtx, id: ThreadId): Draft<Thread> {
  const t = getThread(ctx, id);
  if (t === undefined) {
    throw new Error(`engine: thread ${id} not found in state`);
  }
  return t;
}

export function deleteThread(ctx: StepCtx, id: ThreadId): void {
  delete ctx.state.threads[id];
}

// ─── Children bookkeeping ──────────────────────────────────────────────────

export function setChild(t: Draft<Thread>, callId: CallId, childId: ThreadId): void {
  t.children[callId as number] = childId;
}

export function deleteChild(t: Draft<Thread>, callId: CallId): ThreadId | undefined {
  const childId = t.children[callId as number];
  if (childId === undefined) return undefined;
  delete t.children[callId as number];
  return childId;
}

export function hasChildren(t: Draft<Thread>): boolean {
  return Object.keys(t.children).length > 0;
}

export function liveChildIds(t: Draft<Thread>): ThreadId[] {
  return Object.values(t.children) as ThreadId[];
}

// ─── ID allocators (per-thread) ────────────────────────────────────────────

export function allocCallId(t: Draft<Thread>): CallId {
  const id = t.nextCallId;
  t.nextCallId = ((id as number) + 1) as CallId;
  return id;
}

export function allocAskId(t: Draft<Thread>): AskId {
  const id = t.nextAskId;
  t.nextAskId = ((id as number) + 1) as AskId;
  return id;
}

// ─── Cancellation cascade ──────────────────────────────────────────────────

/**
 * Move `t` into `cancelling` state and dispatch cancel to every live
 * child. If the thread already has no children, finishCancelling fires
 * immediately. Idempotent on already-cancelling threads.
 */
export function beginCancel(ctx: StepCtx, t: Draft<Thread>): void {
  if (t.status === "cancelling") return;
  t.status = "cancelling";
  if (!hasChildren(t)) {
    finishCancelling(ctx, t);
    return;
  }
  for (const childId of liveChildIds(t)) {
    ctx.enqueue({ kind: "cancel", target: childId });
  }
}

/**
 * Re-check whether cancellation can complete now that a child went away.
 * Called from common done/cancelAck handlers when status === "cancelling".
 */
export function checkCancelComplete(ctx: StepCtx, t: Draft<Thread>): void {
  if (t.status !== "cancelling") return;
  if (hasChildren(t)) return;
  finishCancelling(ctx, t);
}

/**
 * Variants that can carry a `pendingReturn` (a caught done-terminating ask
 * value) — i.e. AgentThread (return), HandleThread (break), ForThread
 * (break-for). Centralized here so `finishCancelling` can read the field
 * without proliferating type guards everywhere.
 */
function readPendingReturn(t: Draft<Thread>): import("../value.js").Value | undefined {
  switch (t.kind) {
    case "agent":
    case "handle":
    case "for":
      return t.pendingReturn;
    default:
      return undefined;
  }
}

/**
 * The thread has no remaining children; emit the appropriate notification
 * to the parent and cease.
 *
 * - If `pendingReturn` is set (a done-terminating ask was caught earlier),
 *   emit `done` to parent with that value.
 * - Otherwise, emit `cancelAck` to parent (pure cancel cascade).
 *
 * For root threads (parent === null) — only AgentThreads can be roots in
 * the new design — we delegate to the variant's own completion path via
 * `emitAgentRootCompletion`.
 */
export function finishCancelling(ctx: StepCtx, t: Draft<Thread>): void {
  const pending = readPendingReturn(t);
  if (t.parent === null) {
    if (t.kind === "agent") {
      emitAgentRootCompletion(ctx, t, pending);
      deleteThread(ctx, t.id);
      return;
    }
    // Non-agent root: nothing to emit (test scaffolding may spawn these
    // directly). Drop with a debug log.
    ctx.log("debug", "engine: non-agent root thread cancelled", {
      threadId: t.id,
      kind: t.kind,
    });
    deleteThread(ctx, t.id);
    return;
  }
  if (pending !== undefined) {
    ctx.enqueue({
      kind: "done",
      target: t.parent,
      callId: t.parentCallId!,
      value: pending,
    });
  } else {
    ctx.enqueue({
      kind: "cancelAck",
      target: t.parent,
      callId: t.parentCallId!,
    });
  }
}

/**
 * Emit a completion notification for an AgentThread root back to the
 * delegation's sender, then drop the delegations entries.
 *
 * `value !== undefined` → `delegateAck` (normal completion or caught return).
 * `value === undefined` → `terminateAck` (pure cancel cascade).
 */
export function emitAgentRootCompletion(
  ctx: StepCtx,
  t: Draft<import("./types.js").AgentThread>,
  value: import("../value.js").Value | undefined,
): void {
  const delegationId = t.delegationId as string;
  const sender = ctx.state.delegationSenders[delegationId];
  if (sender !== undefined) {
    if (value !== undefined) {
      ctx.emit({
        from: ctx.state.selfEndpoint,
        to: sender,
        payload: {
          kind: "delegateAck",
          delegationId: t.delegationId,
          value: value as import("../value.js").Value,
        },
      });
    } else {
      ctx.emit({
        from: ctx.state.selfEndpoint,
        to: sender,
        payload: { kind: "terminateAck", delegationId: t.delegationId },
      });
    }
  } else {
    ctx.log("debug", "engine: agent root completed without registered sender", {
      threadId: t.id,
      delegationId,
    });
  }
  delete ctx.state.delegations[delegationId];
  delete ctx.state.delegationSenders[delegationId];
}

/**
 * Common bookkeeping when the parent receives done/cancelAck for a child.
 * Returns true if the variant-specific handler should run.
 */
export function commonRemoveChild(
  ctx: StepCtx,
  parent: Draft<Thread>,
  callId: CallId,
): boolean {
  const childId = deleteChild(parent, callId);
  if (childId === undefined) {
    // Stale event — the child was already cleaned up, e.g. by a cascade
    // that finished out-of-order with this notification.
    return false;
  }
  deleteThread(ctx, childId);
  if (parent.status === "cancelling") {
    checkCancelComplete(ctx, parent);
    return false;
  }
  return true;
}

// ─── Escalation across a delegation boundary ──────────────────────────────

/**
 * Threads that sit on a delegation boundary and forward asks across it as
 * `escalate` events. Two cases, symmetric:
 *
 *   - `ExternalThread`: sender side. Children's asks are escalated to the
 *     external peer (FFI sidecar / another machine).
 *   - `AgentThread` at root (`parent === null`): receiver side. Children's
 *     asks are escalated back to the delegation's original sender via
 *     `state.delegationSenders[delegationId]`.
 *
 * Both threads carry `delegationId` + `pendingEscalations`, so the bookkeeping
 * is identical. Only the peer endpoint (where the escalate event is `to`-ed)
 * differs.
 */
type EscalatableThread = import("./types.js").ExternalThread | import("./types.js").AgentThread;

/**
 * Forward a `request` ask across the delegation boundary as an outbound
 * `escalate` event. Allocates an own askId on `t`, records the forward
 * mapping for the eventual escalateAck, allocates a fresh escalationId
 * for the peer's matching, and emits the outbound event.
 *
 * Non-`request` ask kinds (return / break / next / break-for / next-for)
 * never cross a delegation boundary — they are caught by earlier ancestors
 * (HandleThread / ForThread / AgentThread for return). If one reaches here
 * it's a compiler bug; we drop with a warn.
 */
export function emitEscalateUpward(
  ctx: StepCtx,
  t: Draft<EscalatableThread>,
  peer: import("../endpoint.js").Endpoint,
  askKind: import("../event.js").AskKind,
  childCallId: CallId,
  childAskId: AskId,
): void {
  if (askKind.kind !== "request") {
    ctx.log("warn", "engine: non-request ask reached delegation boundary", {
      threadId: t.id,
      askKind: askKind.kind,
    });
    return;
  }
  const ownAskId = allocAskId(t as Draft<Thread>);
  recordAskForward(t as Draft<Thread>, ownAskId, childCallId, childAskId);
  const escalationId = createEscalationId();
  t.pendingEscalations[ownAskId as unknown as number] = escalationId;
  // ReqId is engine-internal; the receiver of this escalate must resolve
  // its own AgentDefId. We currently synthesize a placeholder qname so the
  // wire format stays valid — the proper qname-from-reqId mapping needs to
  // flow from IR (TODO when handle-scope routing on inbound escalate matures).
  const placeholder: import("../../agent-def-id.js").AgentDefId =
    encodeCoreAgentDefId({
      kind: "qname",
      value: `req:${askKind.reqId}`,
    });
  ctx.emit({
    from: ctx.state.selfEndpoint,
    to: peer,
    payload: {
      kind: "escalate",
      delegationId: t.delegationId,
      escalationId,
      agentDefId: placeholder,
      args: { ...askKind.args },
    },
  });
}

// ─── askIdMap forwarding ───────────────────────────────────────────────────

/**
 * Record a forwarding entry: when ack for `ownAskId` arrives, deliver
 * `(childCallId, childAskId)` back to the original child.
 */
export function recordAskForward(
  t: Draft<Thread>,
  ownAskId: AskId,
  childCallId: CallId,
  childAskId: AskId,
): void {
  t.askIdMap[ownAskId as number] = { childCallId, childAskId };
}

/** Pop a forwarding entry. Returns undefined if no record exists. */
export function popAskForward(
  t: Draft<Thread>,
  ownAskId: AskId,
): { childCallId: CallId; childAskId: AskId } | undefined {
  const entry = (t.askIdMap as AskIdMap)[ownAskId as number];
  if (entry === undefined) return undefined;
  delete t.askIdMap[ownAskId as number];
  return entry;
}

/**
 * Default proxy behavior: forward an ask to the parent. Allocates a new
 * AskId on `t`, records the (childCallId, childAskId) mapping under it,
 * and enqueues an `ask` event addressed to `t.parent` with the new id.
 */
export function proxyAskToParent(
  ctx: StepCtx,
  t: Draft<Thread>,
  childCallId: CallId,
  childAskId: AskId,
  askKind: import("../event.js").AskKind,
): void {
  if (t.parent === null) {
    // No parent to forward to — this ask cannot be served. Drop and log.
    ctx.log("warn", "engine: ask reached root thread with no handler", {
      threadId: t.id,
      askKind: askKind.kind,
    });
    return;
  }
  const ownAskId = allocAskId(t);
  recordAskForward(t, ownAskId, childCallId, childAskId);
  ctx.enqueue({
    kind: "ask",
    target: t.parent,
    askId: ownAskId,
    askKind,
    childCallId: t.parentCallId!,
  });
}

/**
 * Default proxy behavior for askAck: look up the forwarding entry and
 * forward the ack down to the child that originally asked.
 */
export function proxyAskAckToChild(
  ctx: StepCtx,
  t: Draft<Thread>,
  ownAskId: AskId,
  value: Value,
): void {
  const entry = popAskForward(t, ownAskId);
  if (entry === undefined) {
    ctx.log("debug", "engine: askAck without forward record (stale)", {
      threadId: t.id,
      askId: ownAskId,
    });
    return;
  }
  const childId = t.children[entry.childCallId as number];
  if (childId === undefined) {
    // Child went away while the ack was in flight. Drop.
    ctx.log("debug", "engine: askAck dropped — child gone", {
      threadId: t.id,
      childCallId: entry.childCallId,
    });
    return;
  }
  ctx.enqueue({
    kind: "askAck",
    target: childId,
    askId: entry.childAskId,
    value,
  });
}

// ─── Scope helpers ─────────────────────────────────────────────────────────

export function getScope(ctx: StepCtx, id: ScopeId): Draft<Scope> {
  const sc = ctx.state.scopes[id];
  if (sc === undefined) {
    throw new Error(`engine: scope ${id} not found`);
  }
  return sc as Draft<Scope>;
}

export function createScope(
  ctx: StepCtx,
  id: ScopeId,
  parentId: ScopeId | null,
): Draft<Scope> {
  const sc: Scope = { id, parentId, values: {} };
  ctx.state.scopes[id] = sc as Draft<Scope>;
  return ctx.state.scopes[id] as Draft<Scope>;
}

export function setValueInScope(
  ctx: StepCtx,
  scopeId: ScopeId,
  varId: number,
  value: Value,
): void {
  const sc = getScope(ctx, scopeId);
  sc.values[varId] = value as Draft<Value>;
}

export function lookupValue(
  ctx: StepCtx,
  scopeId: ScopeId,
  varId: number,
): Value {
  let cur: ScopeId | null = scopeId;
  while (cur !== null) {
    const sc: Scope | undefined = ctx.state.scopes[cur] as Scope | undefined;
    if (sc === undefined) {
      throw new Error(`engine: scope ${cur} not found while looking up var ${varId}`);
    }
    const v = sc.values[varId];
    if (v !== undefined) return v as Value;
    cur = sc.parentId;
  }
  throw new Error(`engine: var ${varId} not found in scope ${scopeId} or ancestors`);
}

// ─── Common Thread defaults (for spawn) ────────────────────────────────────

/**
 * Initial values for the `Common` fields shared by every Thread variant.
 * Variants spread this and add their kind-specific fields.
 */
export function newCommonFields(args: {
  id: ThreadId;
  parent: ThreadId | null;
  parentCallId: CallId | null;
  scopeId: ScopeId;
  handlers: Record<number, ThreadId>;
}): {
  id: ThreadId;
  parent: ThreadId | null;
  parentCallId: CallId | null;
  scopeId: ScopeId;
  status: ThreadStatus;
  children: Record<number, ThreadId>;
  handlers: Record<number, ThreadId>;
  nextCallId: CallId;
  nextAskId: AskId;
  askIdMap: AskIdMap;
} {
  return {
    id: args.id,
    parent: args.parent,
    parentCallId: args.parentCallId,
    scopeId: args.scopeId,
    status: "running",
    children: {},
    handlers: { ...args.handlers },
    nextCallId: 0 as CallId,
    nextAskId: 0 as AskId,
    askIdMap: {},
  };
}
