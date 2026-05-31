// MakeClosureThread ops. Leaf node — `create` freezes the closure's captured
// scope chain into a content blob (async, via `ctx.putBlob`) and `done`s the
// parent with the resulting `{ kind: "closure", ref }` value. No children.
//
// Why a thread (not an inline statement): persisting the env is async, and in
// this engine a step that waits is a thread — so the statement loop and `done`
// stay synchronous. Mirrors PrimThread's leaf lifecycle.

import { serializeClosure } from "../../closure-codec.js";
import type { CallId } from "../../id.js";
import { deleteThread } from "../common.js";
import type { MakeClosureThread } from "../types.js";
import type { ThreadOps } from "./types.js";

export const makeClosureOps: ThreadOps<MakeClosureThread> = {
  async create(ctx, t) {
    const ref = await serializeClosure(ctx.state, {
      blockId: t.blockId,
      scopeId: t.capturedScopeId,
      snapshot: ctx.state.snapshot,
      selfVar: t.selfVar,
      putBytes: (bytes, refsTo) => ctx.putBlob(bytes, "closure", refsTo),
    });
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "done",
        target: t.parent,
        callId: t.parentCallId,
        value: { kind: "closure", ref },
      });
    }
  },

  done(_ctx, t, callId: CallId) {
    throw new Error(
      `makeClosure thread received done (callId=${callId}) — no children expected on ${t.id}`,
    );
  },

  /** Cancel hits us as part of a tree teardown; we have no children — ack and go. */
  cancel(ctx, t) {
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({ kind: "cancelAck", target: t.parent, callId: t.parentCallId });
    }
    deleteThread(ctx, t.id);
  },

  cancelAck(_ctx, t, callId) {
    throw new Error(
      `engine.makeClosure: thread ${t.id} received unexpected cancelAck (callId=${callId})`,
    );
  },

  ask(_ctx, t, askId) {
    throw new Error(
      `makeClosure thread received ask (askId=${askId}) — no children expected on ${t.id}`,
    );
  },

  askAck(ctx, t, askId) {
    ctx.log("debug", "engine.makeClosure: dropped unexpected askAck", {
      threadId: t.id,
      askId,
    });
  },
};
