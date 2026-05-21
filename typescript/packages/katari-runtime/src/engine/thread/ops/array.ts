// ArrayThread ops. Wraps the shared collecting logic.

import { commonRemoveChild } from "../common.js";
import type { ArrayThread } from "../types.js";
import { collectingCreate, collectingDone } from "./collecting.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const arrayOps: ThreadOps<ArrayThread> = {
  create(ctx, t) {
    collectingCreate(ctx, t);
  },
  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as ArrayThread, callId)) return;
    collectingDone(ctx, t, callId, value);
  },
  cancel: (ctx, t) => defaultCancel<ArrayThread>(ctx, t as ArrayThread),
  cancelAck: defaultCancelAckUnexpected,
  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<ArrayThread>(ctx, t as ArrayThread, askId, kind, childCallId),
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<ArrayThread>(ctx, t as ArrayThread, askId, value),
};
