// Shared thread helpers: completion, the graceful cancel cascade, the default ask plumbing, and the
// escalation escape / relay across instance boundaries.
//
// Ask routing is symmetric to the bubble: an ask rises one hop at a time (each proxy re-raises it under a
// fresh local askId), and its answer descends the same path one hop at a time. Each hop records on the
// proxying *thread* (`forwardRoutes`) where its answer goes — so the answer reverses the bubble with no
// instance-global table. Every ask records a route uniformly (request and the control asks alike); a
// control ask that is consumed by its target boundary just never has its route fired, and a cancelled
// subtree drops its threads' pending routes for free. So the only two fates of a pending ask are: its
// answer comes back (the route fires), or a cancel reaches it (the route dies with the thread).
//
// Cancel is a graceful barrier (matching the prototype): cancelling a thread cancels its whole subtree —
// in-instance children via a `cancel` event, a delegate child via `terminate` (whose `terminateAck`
// becomes that delegate thread's cancelAck), an external (FFI) call via the runner — and only once the
// subtree's teardown is confirmed does the thread perform its `CancelExit` (ack its parent, or, for an
// unwinding return / break, complete the instance / handle). An unwinding exit never runs before the
// cancelled subtree is gone.

import type { QualifiedName } from "@katari-lang/types";
import type { AskKind } from "../event/types.js";
import {
  type AskId,
  type DelegationId,
  type EscalationId,
  newEscalationId,
  type ThreadId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type { StepContext } from "./context.js";
import { allocateAskId } from "./store.js";
import { THROW_REQUEST, throwArgument } from "./throw-signal.js";
import type { CoreInstance, DelegateThread, ExternalThread, Thread } from "./types.js";

/** The proxy thread for an outbound `delegation` in `instance`, found by its own `delegationId`
 *  back-reference (the source of truth — there is no separate outbound-delegation map). Both a
 *  `DelegateThread` (a core sub-call) and an `ExternalThread` (an ffi call) are such proxies. */
export function delegateProxyOf(
  instance: CoreInstance,
  delegation: DelegationId,
): DelegateThread | ExternalThread | undefined {
  for (const thread of Object.values(instance.threads)) {
    if (
      (thread.kind === "delegate" || thread.kind === "external") &&
      thread.delegationId === delegation
    ) {
      return thread;
    }
  }
  return undefined;
}

/** The built-in request a runtime error becomes (a prim failure, a non-exhaustive match, an FFI error).
 *  It bubbles like any request, but the prelude deliberately does not declare it — a program can neither
 *  raise nor handle a panic (anticipated errors are `prelude.throw`, see `throw-signal.ts`); reaching the
 *  run root unhandled, it fails the run with its message. */
export const PANIC_REQUEST = "prelude.panic" as QualifiedName;

/** The wired-in dynamic-dispatch callable: a delegate to it is unwrapped at the core acceptance surface
 *  (`CoreReactor.onDelegate`), never summoned as an instance. The engine re-shapes a direct call of a
 *  `tool` value into this form, so the acceptance surface is the single home of dynamic dispatch. */
export const CALL_AGENT_NAME = "prelude.reflection.call_agent" as QualifiedName;

/** The `{ msg }` record a `panic` request carries. Shared by the engine's thread-level panic and the
 *  reactor-level panic (an ffi error, an unresolvable delegate target). */
export function panicArgument(message: string): Value {
  return { kind: "record", fields: { msg: { kind: "string", value: message } } };
}

/** A data constructor's semantics — tag the argument record's fields with the constructor's name — in
 *  one place, so the `construct` leaf body and the delegate op's inlined construct cannot drift. */
export function constructValue(argument: Value, constructorName: QualifiedName): Value {
  const fields = argument.kind === "record" ? argument.fields : {};
  return { kind: "record", fields, ctor: constructorName };
}

/** Raise a `panic` from a failing thread: an ask carrying `{ msg }` to its parent, escalating outward
 *  toward the nearest `panic` handler (or the run root). */
export function raisePanic(ctx: StepContext, thread: Thread, message: string): void {
  if (thread.parent === null) {
    throw new Error(`panic at the instance root: ${message}`);
  }
  const askId = allocateAskId(ctx.instance);
  ctx.enqueue({
    kind: "ask",
    target: thread.parent,
    from: thread.id,
    askId,
    ask: { kind: "request", request: PANIC_REQUEST, argument: panicArgument(message) },
  });
}

/** Raise a `prelude.throw` from a thread whose prim met an anticipated failure: an ask carrying
 *  `{ error: payload }` to its parent, escalating outward toward the nearest `throw` handler (or the
 *  run root, where it fails the run with the payload). */
export function raiseThrow(ctx: StepContext, thread: Thread, payload: Value): void {
  if (thread.parent === null) {
    throw new Error("throw at the instance root (engine bug)");
  }
  const askId = allocateAskId(ctx.instance);
  ctx.enqueue({
    kind: "ask",
    target: thread.parent,
    from: thread.id,
    askId,
    ask: { kind: "request", request: THROW_REQUEST, argument: throwArgument(payload) },
  });
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
 * Bubble an ask one level up to `thread`'s parent, re-stamped as sent by `thread`, recording on `thread`
 * where this hop's answer goes (back down to `from`). Records for every ask kind — a control ask consumed
 * by its target boundary simply never has this route fired (and a cancel drops it with the thread).
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
  thread.forwardRoutes[askId] = { thread: from, askId: fromAskId };
  ctx.enqueue({ kind: "ask", target: thread.parent, from: thread.id, askId, ask });
}

/**
 * An ask reached the instance root (the agent) and is not a `return` to it: the root escapes it as an
 * outbound `escalate`. This is exactly `proxyAsk`, but the root has no parent, so it "bubbles to the
 * outside": it records the same `resumeThread` route on its own `forwardRoutes` (keyed by a fresh local
 * `askId`), then bridges a fresh external `escalation` id to that `askId` (the `escalations` map) and
 * emits the `escalate`. The cross-instance events thus speak only external vocabulary; the returning
 * `escalateAck` is converted back to an internal `askAck` here, in `resumeEscalation`.
 */
export function escapeAsk(ctx: StepContext, from: ThreadId, fromAskId: AskId, ask: AskKind): void {
  const delegation = ctx.instance.delegationId;
  if (delegation === null) {
    throw new Error("an instance with no delegation cannot escalate (engine bug)");
  }
  const root = ctx.instance.threads[ctx.instance.rootThreadId];
  if (root === undefined || root.kind !== "agent") {
    throw new Error("the escalation boundary is not an agent root (engine bug)");
  }
  const askId = allocateAskId(ctx.instance);
  root.forwardRoutes[askId] = { thread: from, askId: fromAskId };
  const escalation = newEscalationId();
  root.escalations[escalation] = askId;
  // An escalate rises to this instance's summoner — the reactor that issued the delegation it answers.
  ctx.emit({ kind: "escalate", delegation, escalation, ask }, ctx.instance.callerReactor);
}

/**
 * Convert a returning `escalateAck` back into an internal answer at the raising instance's Agent root.
 * The actor hands this external vocabulary only — `(escalation, value)`, having routed to the raiser by
 * `delegation`. The Agent maps the `escalation` to the `askId` it escaped under and re-enters it as a
 * plain `askAck` to itself; its `forwardRoutes` then carry the answer on down like any bubbled answer.
 */
export function resumeEscalation(ctx: StepContext, escalation: EscalationId, value: Value): void {
  const root = ctx.instance.threads[ctx.instance.rootThreadId];
  if (root === undefined || root.kind !== "agent") return;
  const askId = root.escalations[escalation];
  if (askId === undefined) return;
  delete root.escalations[escalation];
  ctx.enqueue({ kind: "askAck", target: root.id, askId, value });
}

/**
 * Re-raise an inbound `escalate`'s ask inside the parent instance, from the proxy's position (so it bubbles
 * toward a handle / the parent agent), recording the `escalation` on the proxy's `relays` so its answer
 * leaves again as that escalate's `escalateAck` (`(proxy.delegationId, escalation)`). The proxy is a
 * `DelegateThread` (a sub-call's escalation) or an `ExternalThread` (an ffi error's panic).
 */
export function relayEscalate(
  ctx: StepContext,
  proxyId: ThreadId,
  escalation: EscalationId,
  ask: AskKind,
): void {
  const proxy = ctx.instance.threads[proxyId];
  if (
    proxy === undefined ||
    proxy.parent === null ||
    (proxy.kind !== "delegate" && proxy.kind !== "external")
  ) {
    return; // the caller was torn down; the escalating child will be terminated independently
  }
  const askId = allocateAskId(ctx.instance);
  proxy.relays[askId] = escalation;
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
    // A delegateAck / terminateAck returns to this instance's summoner (the reactor that issued its delegation).
    ctx.emit(
      outcome.kind === "return"
        ? { kind: "delegateAck", delegation, value: outcome.value }
        : { kind: "terminateAck", delegation },
      ctx.instance.callerReactor,
    );
  }
  ctx.instance.threads = {};
}
