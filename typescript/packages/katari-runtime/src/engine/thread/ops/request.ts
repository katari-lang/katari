// RequestThread ops.
//
// Issues a single `request` ask to its parent (which proxies upward
// until a HandleThread for `reqId` catches it). The askAck reply
// carries the resume value — we propagate it to our parent as a `done`.
//
// RequestThread asks at most once in its lifetime; pendingAskId is
// stored only as a sanity check.

import { allocAskId } from "../common.js";
import type { RequestThread } from "../types.js";
import { defaultCancel, defaultCancelAckUnexpected } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const requestOps: ThreadOps<RequestThread> = {
  create(ctx, t) {
    if (t.parent === null || t.parentCallId === null) {
      throw new Error("engine.request: RequestThread spawned with no parent");
    }
    const askId = allocAskId(t as RequestThread);
    t.pendingAskId = askId;
    ctx.enqueue({
      kind: "ask",
      target: t.parent,
      askId,
      askKind: { kind: "request", reqId: t.reqId, args: { ...t.args } },
      childCallId: t.parentCallId,
    });
  },

  /**
   * RequestThread has no children; receiving `done` is invariant violation.
   */
  done(_ctx, t, callId) {
    throw new Error(
      `request thread received done (callId=${callId}) — no children expected on ${t.id}`,
    );
  },

  cancel: (ctx, t) => defaultCancel<RequestThread>(ctx, t as RequestThread),
  cancelAck: defaultCancelAckUnexpected,

  /**
   * Default ask is "proxy to parent" — but RequestThread has no
   * children to ask, so this should never fire. Treat as invariant.
   */
  ask(_ctx, t, askId, kind, _childCallId) {
    throw new Error(
      `engine.request: RequestThread ${t.id} unexpectedly received ask (kind=${kind.kind}, askId=${askId})`,
    );
  },

  /**
   * The askAck for our outstanding `request` ask is the resume value —
   * forward it to our parent as `done`.
   */
  askAck(ctx, t, askId, value) {
    if (t.pendingAskId === undefined) {
      throw new Error(`engine.request: askAck on RequestThread ${t.id} without pending ask`);
    }
    if (t.pendingAskId !== askId) {
      throw new Error(
        `engine.request: askId mismatch on ${t.id} (expected ${t.pendingAskId}, got ${askId})`,
      );
    }
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "done",
        target: t.parent,
        callId: t.parentCallId,
        value,
      });
    }
  },
};
