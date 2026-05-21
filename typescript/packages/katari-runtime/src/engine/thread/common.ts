// Common helpers shared by every Thread variant's ops.
//
// The thread lifecycle is the same regardless of variant:
//   - children come and go via done / cancelAck
//   - cancel cascades to all children, then finishCancelling fires
//   - asks bubble up through proxies via askIdMap
// Variant-specific behavior (statement execution, ask catching, etc.)
// lives in the per-variant ops file. This module hosts the common code
// that each op delegates into.

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

export function getThread(ctx: StepCtx, id: ThreadId): Thread | undefined {
  return ctx.state.threads[id] as Thread | undefined;
}

export function requireThread(ctx: StepCtx, id: ThreadId): Thread {
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

export function setChild(t: Thread, callId: CallId, childId: ThreadId): void {
  t.children[callId] = childId;
}

export function deleteChild(t: Thread, callId: CallId): ThreadId | undefined {
  const childId = t.children[callId];
  if (childId === undefined) return undefined;
  delete t.children[callId];
  return childId;
}

export function hasChildren(t: Thread): boolean {
  return Object.keys(t.children).length > 0;
}

export function liveChildIds(t: Thread): ThreadId[] {
  return Object.values(t.children) as ThreadId[];
}

// ─── ID allocators (per-thread) ────────────────────────────────────────────

export function allocCallId(t: Thread): CallId {
  const id = t.nextCallId;
  t.nextCallId = ((id as number) + 1) as CallId;
  return id;
}

export function allocAskId(t: Thread): AskId {
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
export function beginCancel(ctx: StepCtx, t: Thread): void {
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
export function checkCancelComplete(ctx: StepCtx, t: Thread): void {
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
function readPendingReturn(t: Thread): import("../value.js").Value | undefined {
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
export function finishCancelling(ctx: StepCtx, t: Thread): void {
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
  t: import("./types.js").AgentThread,
  value: import("../value.js").Value | undefined,
): void {
  const delegationId = t.delegationId;
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
  parent: Thread,
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
 * Forward a `request` ask from a descendant across the delegation
 * boundary as an outbound `escalate` event. This is the AgentThread root
 * case: a child's ask reached us with no local handler, so we issue a
 * fresh escalationId and ship the request to the delegation sender.
 *
 * Bookkeeping written:
 *   - allocate `ownAskId` on `t` (for the upward forward + eventual ack)
 *   - `askIdMap[ownAskId] = (childCallId, childAskId)` so a future
 *     askAck can be routed back down to the original asker
 *   - `outboundEscalations[escalationId] = ownAskId` so the inbound
 *     `escalateAck` (which carries escalationId) can be matched in O(1)
 *   - `escalationOwners[escalationId] = t.id` so the runner can find us
 *     given just the escalationId
 *
 * Non-`request` ask kinds (return / break / next / break-for / next-for)
 * never cross a delegation boundary — they are caught by earlier ancestors.
 * If one reaches here it's a compiler bug; we drop with a warn.
 */
export function emitEscalateUpward(
  ctx: StepCtx,
  t: import("./types.js").AgentThread,
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
  const ownAskId = allocAskId(t as Thread);
  recordAskForward(t as Thread, ownAskId, childCallId, childAskId);
  const escalationId = createEscalationId();
  t.outboundEscalations[escalationId] = ownAskId;
  // Mirror the registration into the global owner index so escalateAck
  // routing is O(1). See state.ts `escalationOwners`.
  ctx.state.escalationOwners[escalationId] = t.id;
  // 'reqId' is already the request's 'QualifiedName' (since the IR-id
  // unification in Phase 2.A), so we ship it as the escalate's
  // 'agentDefId' directly. The receiver decodes it and pumps an upward
  // request ask carrying the same qname.
  const wireId: import("../../agent-def-id.js").AgentDefId =
    encodeCoreAgentDefId({
      kind: "qname",
      value: askKind.reqId,
    });
  ctx.emit({
    from: ctx.state.selfEndpoint,
    to: peer,
    payload: {
      kind: "escalate",
      delegationId: t.delegationId,
      escalationId,
      agentDefId: wireId,
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
  t: Thread,
  ownAskId: AskId,
  childCallId: CallId,
  childAskId: AskId,
): void {
  t.askIdMap[ownAskId] = { childCallId, childAskId };
}

/** Pop a forwarding entry. Returns undefined if no record exists. */
export function popAskForward(
  t: Thread,
  ownAskId: AskId,
): { childCallId: CallId; childAskId: AskId } | undefined {
  const entry = t.askIdMap[ownAskId];
  if (entry === undefined) return undefined;
  delete t.askIdMap[ownAskId];
  return entry;
}

/**
 * Default proxy behavior: forward an ask to the parent. Allocates a new
 * AskId on `t`, records the (childCallId, childAskId) mapping under it,
 * and enqueues an `ask` event addressed to `t.parent` with the new id.
 */
export function proxyAskToParent(
  ctx: StepCtx,
  t: Thread,
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
  t: Thread,
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
  const childId = t.children[entry.childCallId];
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

// ─── Throw escalation ─────────────────────────────────────────────────────
//
// Converts an engine-internal recoverable error into a `prim.throw` request
// ask that bubbles up the normal handle chain. Two outcomes:
//
//   1. A `handle { req throw(msg) { ... } }` ancestor catches it —
//      the user-defined handler executes and the program resumes.
//
//   2. The ask reaches a root AgentThread uncaught — `emitEscalateUpward`
//      fires a `throw` escalate to the delegation sender (= API Module),
//      which marks the agent as errored and terminates the snapshot.
//
// Callers MUST return immediately after this call. The thread stays alive
// and will be cancelled by the cascade that the handler or API Module starts.

/**
 * Initiate a recoverable throw from inside a running thread. Enqueues a
 * `request` ask to the parent with `reqId = "prim.throw"` and the given
 * message, then returns. The ask travels through the normal handle chain:
 * a matching `handle { req throw(msg) { ... } }` catches it; if nothing
 * catches it, the root AgentThread escalates it to the API Module.
 */
export function emitThrowEscalate(
  ctx: StepCtx,
  t: Thread,
  message: string,
): void {
  if (t.parent === null || t.parentCallId === null) {
    ctx.log("warn", "engine: throw escalate at root thread with no parent", {
      threadId: t.id,
      message,
    });
    return;
  }
  const askId = allocAskId(t);
  ctx.enqueue({
    kind: "ask",
    target: t.parent,
    askId,
    askKind: {
      kind: "request",
      reqId: "prim.throw",
      args: { msg: { kind: "string", value: message } },
    },
    childCallId: t.parentCallId,
  });
}

// ─── Scope helpers ─────────────────────────────────────────────────────────

export function getScope(ctx: StepCtx, id: ScopeId): Scope {
  const sc = ctx.state.scopes[id];
  if (sc === undefined) {
    throw new Error(`engine: scope ${id} not found`);
  }
  return sc as Scope;
}

export function createScope(
  ctx: StepCtx,
  id: ScopeId,
  parentId: ScopeId | null,
): Scope {
  const sc: Scope = { id, parentId, values: {} };
  ctx.state.scopes[id] = sc as Scope;
  return ctx.state.scopes[id] as Scope;
}

export function setValueInScope(
  ctx: StepCtx,
  scopeId: ScopeId,
  varId: number,
  value: Value,
): void {
  const sc = getScope(ctx, scopeId);
  sc.values[varId] = value as Value;
}

// Hard upper bound on scope-chain depth to catch corrupt checkpoints
// that contain a cycle (parentId pointing back into the chain). Real
// programs nest 10-20 frames at the deepest; 1000 is comfortably above
// anything reachable through legal lowering. Above that we'd rather
// fail loudly than spin in an infinite walk.
const MAX_SCOPE_DEPTH = 1000;

export function lookupValue(
  ctx: StepCtx,
  scopeId: ScopeId,
  varId: number,
): Value {
  let cur: ScopeId | null = scopeId;
  let depth = 0;
  while (cur !== null) {
    if (depth++ > MAX_SCOPE_DEPTH) {
      throw new Error(
        `engine: scope chain from ${scopeId} exceeded ${MAX_SCOPE_DEPTH} frames while looking up var ${varId} (possible cycle in scope.parentId)`,
      );
    }
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
}): {
  id: ThreadId;
  parent: ThreadId | null;
  parentCallId: CallId | null;
  scopeId: ScopeId;
  status: ThreadStatus;
  children: Record<CallId, ThreadId>;
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
    nextCallId: 0 as CallId,
    nextAskId: 0 as AskId,
    askIdMap: {},
  };
}
