// DelegateThread ops — sender side of a delegation.
//
// Spawned by a `StatementCall` to a `BlockDelegate`. On create, reads
// the block's `target` and emits an outbound `delegate` event to the
// appropriate peer:
//
//   - `delegateTargetInternal` → selfEndpoint (CORE loopback)
//   - `delegateTargetExternal` → ffiTargetEndpoint
//   - `delegateTargetValue`    → reads the runtime value at the given
//     VarId. `agentLiteral` checks `IRModule.entries` to decide internal
//     vs external; `closure` always uses CORE loopback and carries the
//     closureId so the receiver can resolve its body + captured scope.
//
// Has no children. `delegateAck` arrives via `runner.translateExternal`
// translated into a `done` event. Cancel emits `terminate` and waits.
// Inbound `escalate` from the peer is converted into an upward ask to
// the parent; the eventual `askAck` becomes an outbound `escalateAck`.

import { encodeCoreAgentDefId, encodeFfiAgentDefId } from "../../../agent-def-id.js";
import type { Block, BlockId, DelegateBlock } from "../../../ir/types.js";
import type { Endpoint } from "../../endpoint.js";
import type { CallId } from "../../id.js";
import type { StepCtx } from "../../step-ctx.js";
import { lookupValue } from "../common.js";
import type { DelegateThread } from "../types.js";
import { defaultAskAckProxy, defaultCancelAckUnexpected } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const delegateOps: ThreadOps<DelegateThread> = {
  create(ctx, t) {
    const block = getDelegateBlock(ctx, t.blockId);
    emitInitialDelegate(ctx, t as DelegateThread, block);
  },

  done(_ctx, t, callId: CallId) {
    throw new Error(
      `delegate thread received done (callId=${callId}) — no children expected on ${t.id}`,
    );
  },

  /**
   * Cancel: emit `terminate` to the peer and stay in `cancelling` until
   * the matching ack arrives. Idempotent — duplicate cancels are dropped.
   */
  cancel(ctx, t) {
    if (t.status === "cancelling") return;
    t.status = "cancelling";
    const peer = peerEndpointForDelegate(ctx, t as DelegateThread);
    ctx.emit({
      from: ctx.state.selfEndpoint,
      to: peer,
      payload: { kind: "terminate", delegationId: t.delegationId },
    });
  },

  cancelAck: defaultCancelAckUnexpected,

  /**
   * DelegateThread has no children of its own, so an inbound `ask` is an
   * engine bug. The runner converts inbound `escalate` events directly
   * into upward asks targeting this thread's parent, bypassing this op.
   */
  ask(_ctx, t, askId) {
    throw new Error(
      `delegate thread received ask (askId=${askId}) — DelegateThread has no children`,
    );
  },

  /**
   * AskAck on a DelegateThread comes from the parent in response to an
   * inbound-escalate-turned-upward-ask. Look up the escalationId we held
   * under `inboundEscalations[askId]` and emit the outbound `escalateAck`
   * back to the peer that started the escalation.
   *
   * If no entry is present this is a stale ack (e.g. cancel raced an
   * in-flight handler reply); fall through to the default proxy which
   * logs and drops.
   */
  askAck(ctx, t, askId, value) {
    const escalationId = t.inboundEscalations[askId];
    if (escalationId !== undefined) {
      delete t.inboundEscalations[askId];
      // The owner index entry for this escalationId points at the sender
      // (= the AgentThread that issued the original outbound escalate).
      // Do NOT delete it here — the matching inbound escalateAck is
      // what closes the loop on the sender side.
      const peer = peerEndpointForDelegate(ctx, t as DelegateThread);
      ctx.emit({
        from: ctx.state.selfEndpoint,
        to: peer,
        payload: {
          kind: "escalateAck",
          escalationId,
          value,
        },
      });
      return;
    }
    defaultAskAckProxy<DelegateThread>(ctx, t as DelegateThread, askId, value);
  },
};

// ─── helpers ───────────────────────────────────────────────────────────────

function getDelegateBlock(ctx: StepCtx, blockId: BlockId): DelegateBlock {
  const b = ctx.state.irModule.blocks[String(blockId)] as Block | undefined;
  if (b === undefined) {
    throw new Error(`engine.delegate: block ${blockId} not found`);
  }
  if (b.kind !== "blockDelegate") {
    throw new Error(`engine.delegate: block ${blockId} is not blockDelegate (${b.kind})`);
  }
  return b.body;
}

function emitInitialDelegate(ctx: StepCtx, t: DelegateThread, block: DelegateBlock): void {
  // Register on the sender side so inbound delegateAck / terminateAck
  // can be routed back here.
  ctx.state.pendingDelegateOut[t.delegationId] = t.id;
  const { peer, agentDefId } = resolveTarget(ctx, t, block);
  ctx.emit({
    from: ctx.state.selfEndpoint,
    to: peer,
    payload: {
      kind: "delegate",
      delegationId: t.delegationId,
      agentDefId,
      args: { ...t.args },
    },
  });
}

function resolveTarget(
  ctx: StepCtx,
  t: DelegateThread,
  block: DelegateBlock,
): {
  peer: Endpoint;
  agentDefId: import("../../../agent-def-id.js").AgentDefId;
} {
  const target = block.target;
  switch (target.kind) {
    case "delegateTargetInternal":
      return {
        peer: ctx.state.selfEndpoint,
        agentDefId: encodeCoreAgentDefId({ kind: "qname", value: target.body }),
      };
    case "delegateTargetExternal": {
      const { endpoint, dispatchName } = target.body;
      // dispatchName is the flat opaque registry key from the source
      // `from "ENDPOINT:name"` clause (e.g. "lib.greet", "get_env").
      // QualifiedName is just an alias for `string` in this runtime
      // so we hand it through verbatim.
      switch (endpoint) {
        case "FFI":
          return {
            peer: ctx.state.ffiTargetEndpoint,
            agentDefId: encodeFfiAgentDefId({
              kind: "qname",
              value: dispatchName,
            }),
          };
        case "ENV":
          return {
            peer: ctx.state.envTargetEndpoint,
            agentDefId: encodeFfiAgentDefId({
              kind: "qname",
              value: dispatchName,
            }),
          };
        default:
          throw new Error(
            `engine.delegate: unknown external endpoint ${JSON.stringify(endpoint)} (dispatchName=${JSON.stringify(dispatchName)})`,
          );
      }
    }
    case "delegateTargetValue": {
      const value = lookupValue(ctx, t.scopeId, target.body);
      if (value.kind === "agentLiteral") {
        const qname = value.qualifiedName;
        const inEntries = ctx.state.irModule.entries[qname] !== undefined;
        if (inEntries) {
          return {
            peer: ctx.state.selfEndpoint,
            agentDefId: encodeCoreAgentDefId({ kind: "qname", value: qname }),
          };
        }
        return {
          peer: ctx.state.ffiTargetEndpoint,
          agentDefId: encodeFfiAgentDefId({ kind: "qname", value: qname }),
        };
      }
      if (value.kind === "closure") {
        if (!("closureId" in value)) {
          // A content-ref closure as a delegate target = an escaped closure
          // being invoked; it must be materialized into this shard first
          // (Phase E / #5, not yet wired through delegate).
          throw new Error("engine.delegate: content-ref closure target not yet materializable");
        }
        return {
          peer: ctx.state.selfEndpoint,
          agentDefId: encodeCoreAgentDefId({
            kind: "closure",
            value: value.closureId,
          }),
        };
      }
      throw new Error(
        `engine.delegate: target value at var ${target.body} is not callable (got ${value.kind})`,
      );
    }
  }
}

/**
 * Endpoint the delegate event was originally sent to. We persist the
 * target choice indirectly via the block, so cancel / escalateAck can
 * recompute it. For value targets the runtime value must still be alive
 * in the scope chain (cancel happens before the thread exits).
 */
function peerEndpointForDelegate(ctx: StepCtx, t: DelegateThread): Endpoint {
  const block = getDelegateBlock(ctx, t.blockId);
  return resolveTarget(ctx, t, block).peer;
}
