// DelegateThread ops — sender side of a delegation (and the launcher of an
// in-shard closure call).
//
// Spawned by a `StatementCall` to a `BlockDelegate`. On create, reads the
// block's `target`:
//
//   - `delegateTargetInternal` → outbound `delegate` to selfEndpoint (CORE loopback)
//   - `delegateTargetExternal` → outbound `delegate` to ffiTargetEndpoint
//   - `delegateTargetValue`    → reads the runtime value at the given VarId:
//       · `agentLiteral` → outbound `delegate` (CORE-internal if its qname is in
//         `IRModule.entries`, else FFI) — a true cross-entity delegation.
//       · `closure` → spawns the closure's body as a thread IN THE CURRENT shard
//         over the captured scope (the global store), with NO delegate event.
//         The DelegateThread becomes a transparent proxy: it forwards the body's
//         `done` to its parent and cascades cancel to it; the body's control /
//         request asks bubble up through it (docs/2026-06-08-scope-closure-entity.md).
//
// For the cross-shard case the DelegateThread has no children — `delegateAck`
// arrives via `runner.translateExternal` (routed straight to the parent), and an
// inbound `escalate` is converted into an upward ask. For the in-shard closure
// case it owns exactly one child (the body AgentThread).

import { encodeCoreAgentDefId, encodeFfiAgentDefId } from "../../../agent-def-id.js";
import type { Block, BlockId, DelegateBlock } from "../../../ir/types.js";
import type { Endpoint } from "../../endpoint.js";
import { type CallId, createDelegationId } from "../../id.js";
import { spawnAgentRoot } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import {
  allocCallId,
  beginCancel,
  commonRemoveChild,
  hasChildren,
  lookupValue,
  proxyAskToParent,
} from "../common.js";
import type { DelegateThread, Thread } from "../types.js";
import { defaultAskAckProxy } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const delegateOps: ThreadOps<DelegateThread> = {
  create(ctx, t) {
    const block = getDelegateBlock(ctx, t.blockId);
    // An in-shard closure call resolves to a closure value at create time and
    // spawns the body locally (no delegate). Everything else emits a delegate.
    if (block.target.kind === "delegateTargetValue") {
      const value = lookupValue(ctx, t.scopeId, block.target.body);
      if (value.kind === "closure") {
        spawnClosureBody(ctx, t as DelegateThread, value.closureId);
        return;
      }
    }
    emitInitialDelegate(ctx, t as DelegateThread, block);
  },

  /**
   * Reached only for an in-shard closure call: our body AgentThread child
   * finished. Remove the child, then forward its value to our parent — whose
   * `commonRemoveChild` deletes US (mirrors how a cross-shard delegateAck's
   * `done` is routed straight to the parent, which then cleans up this thread).
   */
  done(ctx, t, callId: CallId, value) {
    if (!commonRemoveChild(ctx, t as DelegateThread, callId)) return;
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({ kind: "done", target: t.parent, callId: t.parentCallId, value });
    }
  },

  /**
   * Cancel. In-shard closure call: cascade cancel to the body child and finish
   * via the standard `cancelAck` path. Cross-shard delegate: emit `terminate`
   * and stay `cancelling` until the matching ack. Idempotent.
   */
  cancel(ctx, t) {
    if (t.status === "cancelling") return;
    if (hasChildren(t)) {
      beginCancel(ctx, t as Thread);
      return;
    }
    t.status = "cancelling";
    const peer = peerEndpointForDelegate(ctx, t as DelegateThread);
    ctx.emit({
      from: ctx.state.selfEndpoint,
      to: peer,
      payload: { kind: "terminate", delegationId: t.delegationId },
    });
  },

  /** In-shard closure call: the body child finished cancelling — the common
   *  bookkeeping fires `finishCancelling` (→ cancelAck to our parent). */
  cancelAck(ctx, t, callId) {
    commonRemoveChild(ctx, t as DelegateThread, callId);
  },

  /**
   * In-shard closure call: a control / request ask from the body child bubbles
   * here — proxy it up to our parent. (Cross-shard delegates have no children;
   * an inbound `escalate` is converted by the runner into an upward ask directly,
   * bypassing this op, so reaching here always means the in-shard case.)
   */
  ask(ctx, t, askId, kind, childCallId) {
    proxyAskToParent(ctx, t as Thread, childCallId, askId, kind);
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

/**
 * In-shard closure call: spawn the closure's body as a NON-root AgentThread
 * child of this DelegateThread, over the captured scope (resolved from the
 * CORE-global store). No delegate event, no serialize — the body runs in the
 * current shard's thread tree; its control / request asks bubble up through us
 * (a transparent proxy). Raises a recoverable throw if the closure is gone (its
 * owner entity was released).
 */
function spawnClosureBody(
  ctx: StepCtx,
  t: DelegateThread,
  closureId: import("../../id.js").ClosureId,
): void {
  const record = ctx.store.closures[closureId];
  if (record === undefined) {
    // The closure's owner entity may have terminated → cascade-dropped it.
    // Surface as a recoverable throw via the parent's handle chain.
    const askId = t.nextAskId as number as import("../../id.js").AskId;
    t.nextAskId = ((t.nextAskId as number) + 1) as import("../../id.js").AskId;
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "ask",
        target: t.parent,
        askId,
        askKind: {
          kind: "request",
          reqId: "primitive.throw",
          argument: {
            kind: "record",
            entries: {
              msg: {
                kind: "string",
                rep: {
                  kind: "inline",
                  text: `closure ${closureId} not found (its owner entity may have been released)`,
                },
              },
            },
          },
        },
        childCallId: t.parentCallId,
      });
    }
    return;
  }
  const callId = allocCallId(t as Thread);
  spawnAgentRoot(ctx, {
    blockId: record.blockId,
    argument: t.argument,
    delegationId: createDelegationId(), // synthetic — a non-root agent never registers it
    capturedScopeId: record.scopeId,
    parent: { threadId: t.id, callId },
  });
}

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
  const { peer, agentDefId, generics } = resolveTarget(ctx, t, block);
  ctx.emit({
    from: ctx.state.selfEndpoint,
    to: peer,
    payload: {
      kind: "delegate",
      delegationId: t.delegationId,
      agentDefId,
      argument: t.argument,
      ...(generics !== undefined ? { generics } : {}),
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
  generics?: Record<string, import("../../../json.js").Json>;
} {
  const target = block.target;
  switch (target.kind) {
    case "delegateTargetInternal":
      // A CORE agent: bare alone can't say which snapshot to run — stamp the
      // issuing shard's snapshot to produce the external target form.
      return {
        peer: ctx.state.selfEndpoint,
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: target.body,
          snapshot: ctx.state.snapshot,
        }),
      };
    case "delegateTargetExternal": {
      const { endpoint, dispatchName } = target.body;
      // dispatchName is the flat opaque registry key from the source
      // `from "ENDPOINT:name"` clause (e.g. "lib.greet", "get_env").
      // QualifiedName is just an alias for `string` in this runtime
      // so we hand it through verbatim.
      switch (endpoint) {
        case "FFI":
          // FFI picks the per-snapshot sidecar — stamp the issuing shard's
          // snapshot (FfiMux routes on it; the lane then strips it for the
          // sidecar's bare-qname handler registry).
          return {
            peer: ctx.state.ffiTargetEndpoint,
            agentDefId: encodeFfiAgentDefId({
              kind: "qname",
              value: dispatchName,
              snapshot: ctx.state.snapshot,
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
        // An agent value already carries its snapshot (the external form) —
        // hand it through verbatim (no re-stamp). `qualifiedName` (the internal
        // id) decides CORE vs FFI via the IR entries; the snapshot rides along.
        const qname = value.qualifiedName;
        const snapshot = value.snapshot;
        const inEntries = ctx.state.irModule.entries[qname] !== undefined;
        if (inEntries) {
          return {
            peer: ctx.state.selfEndpoint,
            agentDefId: encodeCoreAgentDefId({ kind: "qname", value: qname, snapshot }),
            generics: value.generics,
          };
        }
        return {
          peer: ctx.state.ffiTargetEndpoint,
          agentDefId: encodeFfiAgentDefId({ kind: "qname", value: qname, snapshot }),
          generics: value.generics,
        };
      }
      // A closure target is handled by `spawnClosureBody` at create time (an
      // in-shard spawn, never a delegate), so it must not reach resolveTarget.
      throw new Error(
        `engine.delegate: target value at var ${target.body} is not delegatable (got ${value.kind})`,
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
