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
import type { Endpoint } from "../../endpoint.js";
import type { ExternalThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import { emitEscalateUpward } from "../common.js";
import { encodeFfiAgentDefId } from "../../../agent-def-id.js";
import type { ThreadOps } from "./types.js";

export const externalOps: ThreadOps<ExternalThread> = {
  create(ctx, t) {
    // Phantom externals (those created for agent-call delegations) have
    // module_ === "<agent>" — the spawning op already registered the
    // delegation and emitted the outbound event. Nothing to do here.
    if (t.externalName === "<agent>.<delegate>") return;

    // Ordinary external: register on the sender side and emit the outbound
    // delegate. The target FFI module decodes our agentDefId.
    ctx.state.pendingDelegateOut[t.delegationId as string] = t.id;
    ctx.emit({
      from: ctx.state.selfEndpoint as Endpoint,
      to: ctx.state.ffiTargetEndpoint as Endpoint,
      payload: {
        kind: "delegate",
        delegationId: t.delegationId,
        agentDefId: encodeFfiAgentDefId({ kind: "qname", value: t.externalName }),
        args: { ...t.args },
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
    const target = t.externalName === "<agent>.<delegate>"
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
   * Ask received from a child: forward to the external peer as `escalate`.
   * Shared logic with `AgentThread` root via `emitEscalateUpward`.
   */
  ask(ctx, t, askId, kind, childCallId) {
    const peer: Endpoint =
      t.externalName === "<agent>.<delegate>"
        ? ctx.state.selfEndpoint
        : ctx.state.ffiTargetEndpoint;
    emitEscalateUpward(
      ctx,
      t as Draft<ExternalThread>,
      peer,
      kind,
      childCallId,
      askId,
    );
  },

  /**
   * AskAck has two sources:
   *
   *   (a) Inbound `escalateAck` event was translated into an `askAck` by
   *       the runner (FFI / CORE→CORE 'sender side'). The runner already
   *       cleared 'pendingEscalations[askId]' before enqueuing; we forward
   *       the value down via 'askIdMap' to the original asker child.
   *
   *   (b) The askAck arrived from above as part of an inbound-escalate's
   *       proxy chain (CORE→CORE 'receiver side', where an inbound
   *       'escalate' was turned into an upward ask through E.parent). In
   *       this case 'pendingEscalations[askId]' is STILL set — the local
   *       handler's response now needs to be sent back over the wire as
   *       an outbound 'escalateAck' so the originating sender can resume.
   */
  askAck(ctx, t, askId, value) {
    const escalationId = t.pendingEscalations[askId as unknown as number];
    if (escalationId !== undefined) {
      delete t.pendingEscalations[askId as unknown as number];
      const peer: Endpoint =
        t.externalName === "<agent>.<delegate>"
          ? ctx.state.selfEndpoint
          : ctx.state.ffiTargetEndpoint;
      ctx.emit({
        from: ctx.state.selfEndpoint as Endpoint,
        to: peer,
        payload: {
          kind: "escalateAck",
          escalationId,
          value,
        },
      });
      return;
    }
    defaultAskAckProxy<ExternalThread>(ctx, t as Draft<ExternalThread>, askId, value);
  },
};
