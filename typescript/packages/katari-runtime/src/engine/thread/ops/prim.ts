// PrimThread ops. Leaf node — `create` runs the prim synchronously and:
//
//   - on normal return: emits `done` to the parent and the thread
//     terminates naturally (no state retained).
//   - on `RecoverableEngineError`: bubbles up via the universal
//     `primitive.throw` capability (see `emitThrowEscalate`).
//   - on `PrimRaiseRequest`: emits an `ask` for the specific
//     never-returning request the prim chose to raise (e.g.
//     `json_parse_error`), and the thread enters a "waiting-for-cancel"
//     state. The handler that catches the request must `break` out of
//     its enclosing handle scope, which initiates the cancel cascade
//     that finally reaches us; on `cancel` we immediately ack and exit.
//     If somehow an `askAck` comes back instead (the request type is
//     `-> never`, so this shouldn't happen), we drop it defensively.

import type { AgentBlock, BlockId, QualifiedName } from "../../../ir/types.js";
import { RecoverableEngineError } from "../../errors.js";
import type { AskId, CallId } from "../../id.js";
import { executePrim, PrimRaiseRequest } from "../../prim.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import { allocAskId, deleteThread, emitThrowEscalate } from "../common.js";
import type { PrimThread, Thread } from "../types.js";
import { defaultAskProxy } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const primOps: ThreadOps<PrimThread> = {
  create(ctx, t) {
    let value: Value | undefined;
    try {
      // `get_metadata` needs the IR module + closures table to resolve a
      // callable Value back to its `AgentBlock`. Branch here rather than
      // in the pure `executePrim` since that function intentionally has
      // no state access.
      value =
        t.primName === "get_metadata"
          ? executeGetMetadata(ctx, t.args)
          : executePrim(t.primName, t.args);
    } catch (err) {
      if (err instanceof PrimRaiseRequest) {
        emitPrimRaise(ctx, t, err);
        return;
      }
      if (err instanceof RecoverableEngineError) {
        emitThrowEscalate(ctx, t as Thread, err.message);
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
    throw new Error(
      `prim thread received done (callId=${callId}) — no children expected on ${t.id}`,
    );
  },

  /**
   * Cancel hits us either in the cascade triggered by a `break` out of
   * the handle scope that caught our raise, or as part of an unrelated
   * tree teardown. Either way we have no children and nothing to clean
   * up — ack immediately and remove the thread.
   */
  cancel(ctx, t) {
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "cancelAck",
        target: t.parent,
        callId: t.parentCallId,
      });
    }
    deleteThread(ctx, t.id);
  },

  cancelAck(_ctx, t, callId) {
    throw new Error(
      `engine.prim: PrimThread ${t.id} received unexpected cancelAck (callId=${callId}) — no children expected`,
    );
  },

  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<PrimThread>(ctx, t as PrimThread, askId, kind, childCallId),

  /**
   * After a `PrimRaiseRequest` we emit one upward `ask` and never
   * expect a meaningful reply — every request a prim raises today has
   * static return type `never`, so the handler that catches it must
   * `break` rather than `next`. If an `askAck` slips through anyway
   * (e.g. a future relaxation of the rule), drop it as a noop.
   */
  askAck(ctx, t, askId, _value) {
    if (t.pendingAskId !== undefined && t.pendingAskId === askId) {
      ctx.log("debug", "engine.prim: dropped askAck for never-returning request", {
        threadId: t.id,
        askId,
      });
      return;
    }
    // Unknown askId — surface as a debug log; askIdMap forwarding
    // doesn't apply because PrimThread has no children.
    ctx.log("debug", "engine.prim: askAck with no matching pending ask", {
      threadId: t.id,
      askId,
    });
  },
};

/**
 * Convert a `PrimRaiseRequest` into an upward `ask` event of kind
 * `request`. Mirrors `emitThrowEscalate` but parameterised on the
 * request id + args the prim chose. The thread is left alive with
 * `pendingAskId` set so the upcoming cancel cascade can ack cleanly.
 */
function emitPrimRaise(ctx: StepCtx, t: PrimThread, err: PrimRaiseRequest): void {
  if (t.parent === null || t.parentCallId === null) {
    ctx.log("warn", "engine.prim: raise at root thread with no parent", {
      threadId: t.id,
      reqId: err.reqId,
    });
    return;
  }
  const askId: AskId = allocAskId(t as Thread);
  t.pendingAskId = askId;
  ctx.enqueue({
    kind: "ask",
    target: t.parent,
    askId,
    askKind: {
      kind: "request",
      reqId: err.reqId,
      args: { ...err.args },
    },
    childCallId: t.parentCallId,
  });
}

// ─── get_metadata ──────────────────────────────────────────────────────────
//
// Returns the `agent_metadata(name, id, description, input, output)` tagged
// value for any callable. Bridges the Haskell-side static metadata embedded
// in each `AgentBlock` (compiled-in name / description / JSON schemas) with
// the runtime-side dispatch identity (`closure:N` for local agents,
// qualified name otherwise).

function executeGetMetadata(ctx: StepCtx, args: Record<string, Value>): Value {
  const value = args["value"];
  if (value === undefined) {
    throw new RecoverableEngineError("prim get_metadata: missing argument 'value'");
  }

  const [agentBlock, dispatchId] = resolveCallable(ctx, value);

  return {
    kind: "tagged",
    ctorId: "primitive.agent_metadata",
    fields: {
      name: { kind: "string", value: agentBlock.name },
      id: { kind: "string", value: dispatchId },
      description: {
        kind: "string",
        value: agentBlock.description ?? "",
      },
      input: { kind: "string", value: agentBlock.inputSchema },
      output: { kind: "string", value: agentBlock.outputSchema },
    },
  };
}

/**
 * Resolve a runtime callable value to its `AgentBlock` plus the
 * runtime-stable id used to dispatch it. For top-level callables (incl.
 * prims / ctors / externals — all wrapped in a `BlockAgent`) the id is
 * the qualified name (`<module>.<bare>`); for local agents it is
 * `closure:<closureId>`.
 */
function resolveCallable(ctx: StepCtx, value: Value): [AgentBlock, string] {
  switch (value.kind) {
    case "agentLiteral": {
      const blockId = lookupQualified(ctx, value.qualifiedName);
      return [requireAgentBlock(ctx, blockId, value.qualifiedName), value.qualifiedName];
    }
    case "closure": {
      const record = ctx.state.closures[value.closureId];
      if (record === undefined) {
        throw new RecoverableEngineError(
          `prim get_metadata: closure id ${value.closureId} not in state.closures`,
        );
      }
      return [
        requireAgentBlock(ctx, record.blockId, `closure:${value.closureId}`),
        `closure:${value.closureId}`,
      ];
    }
    default:
      throw new RecoverableEngineError(
        `prim get_metadata: expected callable value, got ${value.kind}`,
      );
  }
}

function lookupQualified(ctx: StepCtx, qname: QualifiedName): BlockId {
  const blockId = ctx.state.irModule.entries[qname];
  if (blockId === undefined) {
    throw new RecoverableEngineError(`prim get_metadata: '${qname}' not found in irModule.entries`);
  }
  return blockId;
}

function requireAgentBlock(ctx: StepCtx, blockId: BlockId, hint: string): AgentBlock {
  const block = ctx.state.irModule.blocks[String(blockId)];
  if (block === undefined) {
    throw new RecoverableEngineError(
      `prim get_metadata: block ${blockId} (${hint}) missing from irModule.blocks`,
    );
  }
  if (block.kind !== "blockAgent") {
    throw new RecoverableEngineError(
      `prim get_metadata: block ${blockId} (${hint}) is ${block.kind}, expected blockAgent`,
    );
  }
  return block.body;
}
