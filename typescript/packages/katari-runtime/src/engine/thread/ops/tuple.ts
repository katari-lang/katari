// TupleThread ops. Wraps the shared collecting logic.

import { commonRemoveChild } from "../common.js";
import type { TupleThread } from "../types.js";
import { collectingCreate, collectingDone } from "./collecting.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const tupleOps: ThreadOps<TupleThread> = {
  create(ctx, t) {
    collectingCreate(ctx, t);
  },
  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as TupleThread, callId)) return;
    collectingDone(ctx, t, callId, value);
  },
  cancel: (ctx, t) => defaultCancel<TupleThread>(ctx, t as TupleThread),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<TupleThread>(ctx, t as TupleThread, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<TupleThread>(ctx, t as TupleThread, askId, value),
};
