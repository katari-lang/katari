// Shared thread helpers: completion, the graceful cancel cascade, the default ask plumbing, and the
// escalation escape / relay across instance boundaries.
//
// Ask routing: only a `request` ask is answered back to its asker, so only it leaves a proxy
// continuation in `instance.askRoutes` as it bubbles. The control asks (`return` / `break` / `break-for`
// / `next` / `next-for`) are one-way — each is consumed by the agent / handle / for it targets.
//
// Cancel is a graceful barrier (matching the prototype): cancelling a thread cancels its whole subtree —
// in-instance children via a `cancel` event, a delegate child via `terminate` (whose `terminateAck`
// becomes that delegate thread's cancelAck), an external (FFI) call via the runner — and only once the
// subtree's teardown is confirmed does the thread perform its `CancelExit` (ack its parent, or, for an
// unwinding return / break, complete the instance / handle). An unwinding exit never runs before the
// cancelled subtree is gone.

import type { AskKind } from "../event/types.js";
import { type AskId, type EscalationId, newEscalationId, type ThreadId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { StepContext } from "./context.js";
import { allocateAskId } from "./store.js";
import type { Thread } from "./types.js";

/** Whether an ask is answered back to its asker (only `request`) — i.e. whether proxies must record a
 *  continuation so the eventual `askAck` finds its way home. */
export function isAnsweredAsk(ask: AskKind): boolean {
  return ask.kind === "request";
}

/** Retire a finished thread, delivering its value to the parent's pending call slot. The instance root
 *  (no parent) does not complete here — that is the agent op's job (it retires the whole instance). */
export function completeThread(ctx: StepContext, thread: Thread, value: Value): void {
  if (thread.parent !== null && thread.parentCallId !== null) {
    ctx.enqueue({ kind: "callAck", target: thread.parent, callId: thread.parentCallId, value });
  }
  removeThread(ctx, thread.id);
}

/** Drop a thread from the instance's working set. (Scope reclamation is the instance layer's GC.) */
export function removeThread(ctx: StepContext, threadId: ThreadId): void {
  delete ctx.instance.threads[threadId];
}

/** The direct children of a thread (parent links are the source of truth; no separate child index). */
export function childrenOf(ctx: StepContext, threadId: ThreadId): Thread[] {
  return Object.values(ctx.instance.threads).filter((thread) => thread.parent === threadId);
}

// ─── ask plumbing ─────────────────────────────────────────────────────────────────────────────

/**
 * Bubble an ask one level up to `thread`'s parent, re-stamped as sent by `thread`. For an answered
 * (`request`) ask, record the continuation so its `askAck` routes back to the original sender.
 */
export function proxyAsk(
  ctx: StepContext,
  thread: Thread,
  ask: AskKind,
  from: ThreadId,
  fromAskId: AskId,
): void {
  if (thread.parent === null) {
    throw new Error(`ask of kind "${ask.kind}" reached a parentless thread (engine bug)`);
  }
  const askId = allocateAskId(ctx.instance);
  if (isAnsweredAsk(ask)) {
    ctx.instance.askRoutes[askId] = { kind: "resumeThread", thread: from, askId: fromAskId };
  }
  ctx.enqueue({ kind: "ask", target: thread.parent, from: thread.id, askId, ask });
}

/**
 * An ask reached the instance root (the agent) and is not a `return` to it: it escapes as an outbound
 * `escalate`. For an answered (`request`) ask, record the continuation on this instance so the matching
 * `escalateAck` resumes the original asker.
 */
export function escapeAsk(ctx: StepContext, from: ThreadId, askId: AskId, ask: AskKind): void {
  const delegation = ctx.instance.delegationId;
  if (delegation === null) {
    throw new Error("an instance with no delegation cannot escalate (engine bug)");
  }
  const escalation = newEscalationId();
  if (isAnsweredAsk(ask)) {
    ctx.instance.escalationContinuations[escalation] = {
      kind: "resumeThread",
      thread: from,
      askId,
    };
  }
  ctx.emit({ kind: "escalate", delegation, escalation, ask });
}

/**
 * Re-raise an inbound `escalate`'s ask inside the parent instance, from the proxy DelegateThread's
 * position (so it bubbles toward a handle / the parent agent). For an answered ask, record the relay so
 * its `askAck` is sent back out as the `escalateAck` of the originating escalation.
 */
export function relayEscalate(
  ctx: StepContext,
  proxyId: ThreadId,
  escalation: EscalationId,
  ask: AskKind,
): void {
  const proxy = ctx.instance.threads[proxyId];
  if (proxy === undefined || proxy.parent === null) {
    return; // the caller was torn down; the escalating child will be terminated independently
  }
  const askId = allocateAskId(ctx.instance);
  if (isAnsweredAsk(ask)) {
    ctx.instance.askRoutes[askId] = { kind: "relayEscalateAck", escalation };
  }
  ctx.enqueue({ kind: "ask", target: proxy.parent, from: proxy.id, askId, ask });
}

// ─── instance retirement ─────────────────────────────────────────────────────────────────────────

/** Complete the running instance normally (its body finished): emit the delegateAck and retire it. */
export function completeInstance(ctx: StepContext, value: Value): void {
  retireInstance(ctx, { kind: "return", value });
}

/** Retire a terminated instance: emit its terminateAck (so the caller's delegate proxy can ack) and
 *  retire it without a delegateAck. */
export function terminateInstance(ctx: StepContext): void {
  retireInstance(ctx, { kind: "terminate" });
}

/** Emit the instance's terminal external event and clear its threads (the actor tears down its owned
 *  scopes once the turn sees the empty thread tree). */
function retireInstance(
  ctx: StepContext,
  outcome: { kind: "return"; value: Value } | { kind: "terminate" },
): void {
  const delegation = ctx.instance.delegationId;
  if (delegation !== null) {
    ctx.emit(
      outcome.kind === "return"
        ? { kind: "delegateAck", delegation, value: outcome.value }
        : { kind: "terminateAck", delegation },
    );
  }
  ctx.instance.threads = {};
}
