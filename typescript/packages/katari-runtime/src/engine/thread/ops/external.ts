// ExternalThread ops.
//
// External calls are dispatched outside the engine via a `delegate` event
// emitted to a sidecar endpoint. The host's DelegationRouter receives the
// inbound `delegateAck` reply and translates it into an internal `done`
// event addressed at this thread (the runner's onDone then completes us).
//
// The `to` endpoint is a placeholder until the host wires real routing;
// a future revision will let the IR carry the target endpoint per
// ExternalName.

import type { Draft } from "immer";
import type { CallId } from "../../id.js";
import type { Endpoint } from "../../endpoint.js";
import type { ExternalThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const externalOps: ThreadOps<ExternalThread> = {
  create(ctx, t) {
    // Register this thread as the receiver for the eventual `delegateAck`
    // / `terminateAck` from FFI. The runner's translateExternal looks
    // it up by delegationId.
    ctx.state.ffiDelegations[t.delegationId as string] = t.id;
    ctx.emit({
      from: ctx.state.selfEndpoint as Endpoint,
      to: ctx.state.ffiTargetEndpoint as Endpoint,
      payload: {
        kind: "delegate",
        targetBlock: t.externalName,
        args: { ...t.args },
        delegationId: t.delegationId,
      },
    });
  },

  done(_ctx, t, callId: CallId) {
    throw new Error(`external thread received done (callId=${callId}) — no children expected on ${t.id}`);
  },

  /**
   * Cancel: emit `terminate` to FFI and stay in `cancelling`. The host's
   * DelegationRouter is responsible for translating the eventual FFI
   * `terminateAck` (or a late `delegateAck`) into an internal `cancelAck`
   * targeting our parent on our behalf — the engine waits.
   *
   * This is the only variant where `cancel` does *not* immediately ack
   * the parent: the cancel is in flight to an external system.
   */
  cancel(ctx, t) {
    if (t.status === "cancelling") return;
    t.status = "cancelling";
    ctx.emit({
      from: ctx.state.selfEndpoint as Endpoint,
      to: ctx.state.ffiTargetEndpoint as Endpoint,
      payload: { kind: "terminate", delegationId: t.delegationId },
    });
  },

  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<ExternalThread>(ctx, t as Draft<ExternalThread>, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<ExternalThread>(ctx, t as Draft<ExternalThread>, askId, value),
};
