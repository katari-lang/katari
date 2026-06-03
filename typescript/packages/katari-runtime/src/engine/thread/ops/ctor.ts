// CtorThread ops. Leaf — `create` builds a data value (a `record` carrying its
// constructor) and emits done.

import type { CallId } from "../../id.js";
import type { CtorThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const ctorOps: ThreadOps<CtorThread> = {
  create(ctx, t) {
    if (t.parent === null || t.parentCallId === null) return;
    ctx.enqueue({
      kind: "done",
      target: t.parent,
      callId: t.parentCallId,
      value: {
        kind: "record",
        entries: { ...t.args },
        ctor: t.ctorId,
      },
    });
  },

  done(_ctx, t, callId: CallId) {
    throw new Error(
      `ctor thread received done (callId=${callId}) — no children expected on ${t.id}`,
    );
  },

  cancel: (ctx, t) => defaultCancel<CtorThread>(ctx, t as CtorThread),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<CtorThread>(ctx, t as CtorThread, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<CtorThread>(ctx, t as CtorThread, askId, value),
};
