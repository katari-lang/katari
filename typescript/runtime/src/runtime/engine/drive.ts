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

/** Drive the instance bound to `ctx` until its internal queue is empty (one turn / quantum). */
export async function drive(ctx: StepContext): Promise<void> {
  const queue = ctx.buffers.internalQueue;
  while (queue.length > 0) {
    const event = queue.shift();
    if (event === undefined) break;
    await step(ctx, event);
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
