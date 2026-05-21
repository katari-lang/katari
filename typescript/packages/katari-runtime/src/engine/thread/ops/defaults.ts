// Default ThreadOps fragments shared across variants. Variants spread these
// into their own ops record and override only the methods that need
// variant-specific behaviour.

import type { AskId, CallId } from "../../id.js";
import type { AskKind } from "../../event.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import {
  beginCancel,
  commonRemoveChild,
  proxyAskAckToChild,
  proxyAskToParent,
} from "../common.js";
import type { Thread } from "../types.js";

/**
 * Standard cancel: enter "cancelling" state and cascade to children.
 * Almost every variant uses this directly; `ExternalThread` overrides
 * to emit an outbound terminate first.
 */
export function defaultCancel<T extends Thread>(
  ctx: StepCtx,
  t: T,
): void {
  beginCancel(ctx, t);
}

/**
 * Variants that don't catch any ask kind use this — just bubble up to
 * their parent. Examples: TupleThread, ArrayThread, MatchThread.
 *
 * Note: leaf threads (PrimThread, CtorThread, ExternalThread) cannot
 * actually receive asks at runtime because they have no children. The
 * default exists only to make the dispatch table total.
 */
export function defaultAskProxy<T extends Thread>(
  ctx: StepCtx,
  t: T,
  childAskId: AskId,
  askKind: AskKind,
  childCallId: CallId,
): void {
  proxyAskToParent(ctx, t, childCallId, childAskId, askKind);
}

/** Default askAck behaviour: forward via askIdMap. */
export function defaultAskAckProxy<T extends Thread>(
  ctx: StepCtx,
  t: T,
  askId: AskId,
  value: Value,
): void {
  proxyAskAckToChild(ctx, t, askId, value);
}

/**
 * Most variants don't expect children to ack a cancel from a *targeted*
 * cancel (only HandleThread / ForThread issue those). But every thread
 * receives cancelAck from its children during a normal cascade — so
 * this default accepts the ack, removes the child, and lets the
 * cancellation logic in `commonRemoveChild` advance. Throwing is
 * reserved for the case where the parent is still running and a child
 * acknowledged a cancel that wasn't issued — that's an invariant.
 */
export function defaultCancelAckUnexpected<T extends Thread>(
  ctx: StepCtx,
  t: T,
  callId: CallId,
): void {
  if (commonRemoveChild(ctx, t as unknown as Thread, callId)) {
    // Parent is running and the child went away unexpectedly.
    throw new Error(
      `engine: ${t.kind} thread received unexpected cancelAck (callId=${callId})`,
    );
  }
  // Otherwise: parent was cancelling (or child stale). commonRemoveChild
  // already advanced the cascade.
}
