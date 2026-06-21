// Shared thread helpers used across the per-kind ops: completion (ack the parent and retire), subtree
// teardown (the unwind side of return / break / cancel), and the default ask plumbing every non-handling
// thread shares (bubble an ask up; route an answer back down).
//
// Ask routing model: only a `request` ask is answered back to its asker, so only it leaves a proxy
// continuation in `instance.askRoutes` as it bubbles. The control asks (`return` / `break` / `break-for`
// / `next` / `next-for`) are one-way — each is consumed by the agent / handle / for it targets, which
// unwinds or resumes some *other* thread — so a proxy just forwards them.

import type { AskKind } from "../event/types.js";
import type { AskId, ThreadId } from "../ids.js";
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
 *  (no parent) does not complete here — that is the agent op's job (it emits the instance's delegateAck). */
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

/**
 * Tear down a thread's entire subtree (used by an unwinding return / break and by cancel cascade),
 * leaving the thread itself in place. A `delegate` child owns a live child instance and must be
 * `terminate`d rather than merely dropped — that cross-instance teardown is wired in the instance layer;
 * here we drop the in-instance bookkeeping.
 */
export function dropDescendants(ctx: StepContext, threadId: ThreadId): void {
  for (const child of childrenOf(ctx, threadId)) {
    dropDescendants(ctx, child.id);
    removeThread(ctx, child.id);
  }
}

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
    // The instance root turns an escaping ask into an outbound escalate — wired in the instance layer.
    throw new Error(
      `ask of kind "${ask.kind}" escaped the instance root before the escalation layer`,
    );
  }
  const askId = allocateAskId(ctx.instance);
  if (isAnsweredAsk(ask)) {
    ctx.instance.askRoutes[askId] = { kind: "resumeThread", thread: from, askId: fromAskId };
  }
  ctx.enqueue({ kind: "ask", target: thread.parent, from: thread.id, askId, ask });
}
