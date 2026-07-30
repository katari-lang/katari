// The internal consumer: drain one instance's internal event queue to quiescence ("the same turn"),
// dispatching each event to its target thread's handler. Serial and mostly synchronous; the only await
// is a primitive leaf's `create` (a bounded env / blob fetch), which suspends the drain until it
// resolves — exactly the "network / DB bound during async processing" the design calls out. The actor
// persists and flushes the buffered outbound external events only once this returns (the queue empty).
//
// `askAck` is addressed to a thread: that thread either forwards it on (via its `forwardRoutes`, one hop
// down the bubble chain or out as an escalateAck) or, if it is the genuine asker, consumes it — all in
// `dispatchAskAck`, so the drive loop just routes by target like every other internal event.

import type { InternalEvent } from "../event/types.js";
import type { StepContext } from "./context.js";
import {
  dispatchAsk,
  dispatchAskAck,
  dispatchCallAck,
  dispatchCancel,
  dispatchCancelAck,
  dispatchCreate,
} from "./thread-ops.js";

/** How many events one drain processes before it hands control back to the event loop.
 *
 *  A turn is normally short: an agent runs until it performs an effect, and the delegation that effect
 *  opens empties the queue, so `drive` returns. An ordinary program — including a `forever` loop whose
 *  body genuinely suspends — never comes near this threshold, so the yield costs it nothing.
 *
 *  The exception is a loop whose iterations never actually suspend. `forever` is a first-class,
 *  documented construct, so this is an easy shape to write by accident: a body that only computes, or —
 *  as this file's own test suite has long noted — one that delegates to a handler which resolves without
 *  reaching real I/O. Such a loop enqueues its next iteration as fast as this loop consumes it, so the
 *  queue never empties and `drive` never returns. Every `await` in it settles on a MICROTASK, and Node
 *  drains microtasks completely before returning to the event loop, so without a yield the process stops
 *  serving HTTP, stops firing timers, and stops responding to SIGTERM — for every project, not just the
 *  offending one — until it is killed. On a platform that restarts an unhealthy container that is worse
 *  than a hang: boot revives the in-flight run, which starts the same loop again, so it crash-loops.
 *
 *  What the yield buys is containment, not a bound. The loop still spins and the project whose program is
 *  at fault stays stuck, but the fault stays local: the API keeps answering, other projects keep running,
 *  and the process still shuts down cleanly. Bounding the WORK is a separate question and deliberately
 *  not answered here — by step count alone a runaway is indistinguishable from a turn that legitimately
 *  computes a lot, and failing the latter would break programs that are doing nothing wrong. */
const STEPS_PER_YIELD = 1_000;

/** Hand control back to the event loop.
 *
 *  `setImmediate`, not `await Promise.resolve()`: a resolved promise is a microtask, and Node drains the
 *  whole microtask queue before it ever reaches the event loop — so awaiting one would yield to nothing
 *  and leave the starvation exactly as it was. */
function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => {
    setImmediate(resolve);
  });
}

/** Drive the instance bound to `ctx` until its internal queue is empty (one turn / quantum).
 *
 *  Yielding mid-drain is safe with respect to the turn's atomicity: the actor serialises its own pump
 *  (`Substrate.pump` returns early while a pump is in flight), so no second turn can start in the gap,
 *  and nothing is persisted until this function returns. Events that arrive during a yield simply wait
 *  their turn in the mailbox — which is the point. */
export async function drive(ctx: StepContext): Promise<void> {
  const queue = ctx.buffers.internalQueue;
  let stepsSinceYield = 0;
  while (queue.length > 0) {
    const event = queue.shift();
    if (event === undefined) break;
    await step(ctx, event);
    stepsSinceYield += 1;
    if (stepsSinceYield >= STEPS_PER_YIELD) {
      stepsSinceYield = 0;
      await yieldToEventLoop();
    }
  }
}

async function step(ctx: StepContext, event: InternalEvent): Promise<void> {
  switch (event.kind) {
    case "create": {
      const thread = ctx.instance.threads[event.thread];
      if (thread !== undefined) await dispatchCreate(ctx, thread);
      return;
    }
    case "callAck": {
      const thread = ctx.instance.threads[event.target];
      if (thread !== undefined) dispatchCallAck(ctx, thread, event.callId, event.value);
      return;
    }
    case "cancel": {
      const thread = ctx.instance.threads[event.target];
      if (thread !== undefined) dispatchCancel(ctx, thread);
      return;
    }
    case "cancelAck": {
      const thread = ctx.instance.threads[event.target];
      if (thread !== undefined) dispatchCancelAck(ctx, thread, event.callId);
      return;
    }
    case "ask": {
      const thread = ctx.instance.threads[event.target];
      if (thread !== undefined) dispatchAsk(ctx, thread, event.from, event.askId, event.ask);
      return;
    }
    case "askAck": {
      const thread = ctx.instance.threads[event.target];
      if (thread !== undefined) dispatchAskAck(ctx, thread, event.askId, event.value);
      return;
    }
  }
}
