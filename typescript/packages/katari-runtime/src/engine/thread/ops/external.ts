// ExternalThread ops.
//
// Two roles:
//
//   (1) "Ordinary" external call — the thread was spawned via spawnChild
//       for a `BlockExternal` IR block. Create emits an outbound
//       `delegate` to the FFI endpoint and registers itself in
//       `state.delegations`. The runner's translateExternal translates
//       inbound `delegateAck` / `terminateAck` into internal events.
//
//   (2) Phantom external for an outbound core→core agent call — spawned
//       by `spawnExternalForAgentDelegate`; the user op (caller) emits
//       the outbound delegate itself, the registration happens at spawn
//       time. Create here is a no-op (delegate already in flight).
//
// The thread proxies asks UPWARD on behalf of children only when the
// outbound side is "ordinary" external. For agent calls the AgentThread
// is on the receiving side of the delegation; asks bubble there via the
// delegation event channel (`escalate` / `escalateAck`), not through
// this thread's parent chain.

import type { Draft } from "immer";
import type { CallId } from "../../id.js";
import { createEscalationId } from "../../id.js";
import type { Endpoint } from "../../endpoint.js";
import type { ExternalThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import { allocAskId, recordAskForward } from "../common.js";
import type { ThreadOps } from "./types.js";

export const externalOps: ThreadOps<ExternalThread> = {
  create(ctx, t) {
    // Phantom externals (those created for agent-call delegations) have
    // module_ === "<agent>" — the spawning op already registered the
    // delegation and emitted the outbound event. Nothing to do here.
    if (t.externalName.module_ === "<agent>") return;

    // Ordinary external: register on the sender side and emit the outbound
    // delegate.
    ctx.state.pendingDelegateOut[t.delegationId as string] = t.id;
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
   * Cancel: emit `terminate` to the external endpoint and stay in
   * `cancelling` until the matching ack arrives. Idempotent — duplicate
   * cancels are dropped (Phase 4.8 guard).
   */
  cancel(ctx, t) {
    if (t.status === "cancelling") return;
    t.status = "cancelling";
    const target = t.externalName.module_ === "<agent>"
      ? ctx.state.selfEndpoint
      : ctx.state.ffiTargetEndpoint;
    ctx.emit({
      from: ctx.state.selfEndpoint as Endpoint,
      to: target as Endpoint,
      payload: { kind: "terminate", delegationId: t.delegationId },
    });
  },

  cancelAck: defaultCancelAckUnexpected,

  /**
   * Ask received from a child: forward to the external side as
   * `escalate`. Allocates an EscalationId, records it under
   * pendingEscalations[ownAskId] so the eventual escalateAck can be
   * routed back to the asker.
   */
  ask(ctx, t, askId, kind, childCallId) {
    if (kind.kind !== "request") {
      // Non-request asks (return / break / next / break-for / next-for)
      // never cross an external boundary — they should be caught by
      // earlier ancestors. Drop with a warning.
      ctx.log("warn", "engine.external: non-request ask reached external boundary", {
        threadId: t.id,
        askKind: kind.kind,
      });
      return;
    }
    const draft = t as Draft<ExternalThread>;
    const ownAskId = allocAskId(draft);
    recordAskForward(draft, ownAskId, childCallId, askId);
    const escalationId = createEscalationId();
    draft.pendingEscalations[ownAskId as unknown as number] = escalationId;
    const target = t.externalName.module_ === "<agent>"
      ? ctx.state.selfEndpoint
      : ctx.state.ffiTargetEndpoint;
    ctx.emit({
      from: ctx.state.selfEndpoint as Endpoint,
      to: target as Endpoint,
      payload: {
        kind: "escalate",
        delegationId: t.delegationId,
        escalationId,
        // Synthesize a placeholder qualified name; the receiving side
        // routes by `delegationId`, not by name. The actual ReqId mapping
        // belongs to the outbound IR — for now this is opaque.
        request: { module_: "", name: `req:${kind.reqId}` },
        args: { ...kind.args },
      },
    });
  },

  /**
   * AskAck routed back from translateExternal (escalateAck path).
   * Default proxy: look up the original asker via askIdMap and forward.
   */
  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<ExternalThread>(ctx, t as Draft<ExternalThread>, askId, value),
};
