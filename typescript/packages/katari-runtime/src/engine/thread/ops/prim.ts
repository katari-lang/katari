// PrimThread ops. Leaf node — `create` runs the prim synchronously and
// emits `done` to the parent. No children, no asks, no cancel cascade.

import type { Draft } from "immer";
import type { CallId } from "../../id.js";
import { executePrim } from "../../prim.js";
import { RecoverableEngineError } from "../../errors.js";
import type { PrimThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const primOps: ThreadOps<PrimThread> = {
  create(ctx, t) {
    let value;
    try {
      value = executePrim(t.primName, t.args);
    } catch (err) {
      if (err instanceof RecoverableEngineError) {
        ctx.recordError(err);
        // The engine cannot continue this thread; emit cancelAck-equivalent
        // by enqueuing a `cancelAck` to the parent so the parent sees the
        // child go away. Parent variant decides what to do (typically
        // surfaces as an irrecoverable failure for the agent).
        if (t.parent !== null && t.parentCallId !== null) {
          ctx.enqueue({
            kind: "cancelAck",
            target: t.parent,
            callId: t.parentCallId,
          });
        }
        return;
      }
      throw err;
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

  done(_ctx, t, callId: CallId) {
    throw new Error(`prim thread received done (callId=${callId}) — no children expected on ${t.id}`);
  },

  cancel: (ctx, t) => defaultCancel<PrimThread>(ctx, t as Draft<PrimThread>),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<PrimThread>(ctx, t as Draft<PrimThread>, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<PrimThread>(ctx, t as Draft<PrimThread>, askId, value),
};
