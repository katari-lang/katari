// PrimThread ops. Leaf node — `create` runs the prim synchronously and
// emits `done` to the parent. No children, no asks, no cancel cascade.

import type { Draft } from "immer";
import type { CallId } from "../../id.js";
import { executePrim } from "../../prim.js";
import { RecoverableEngineError } from "../../errors.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import type { AgentBlock, BlockId, QualifiedName } from "../../../ir/types.js";
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
      // `get_metadata` needs the IR module + closures table to resolve a
      // callable Value back to its `AgentBlock`. Branch here rather than
      // in the pure `executePrim` since that function intentionally has
      // no state access.
      value =
        t.primName === "get_metadata"
          ? executeGetMetadata(ctx, t.args)
          : executePrim(t.primName, t.args);
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

// ─── get_metadata ──────────────────────────────────────────────────────────
//
// Returns the `agent_metadata(name, id, description, input, output)` tagged
// value for any callable. Bridges the Haskell-side static metadata embedded
// in each `AgentBlock` (compiled-in name / description / JSON schemas) with
// the runtime-side dispatch identity (`closure:N` for local agents,
// qualified name otherwise).

function executeGetMetadata(
  ctx: StepCtx,
  args: Record<string, Value>,
): Value {
  const value = args["value"];
  if (value === undefined) {
    throw new RecoverableEngineError(
      "prim get_metadata: missing argument 'value'",
    );
  }

  const [agentBlock, dispatchId] = resolveCallable(ctx, value);

  return {
    kind: "tagged",
    ctorId: "prim.agent_metadata",
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
function resolveCallable(
  ctx: StepCtx,
  value: Value,
): [AgentBlock, string] {
  switch (value.kind) {
    case "agentLiteral": {
      const blockId = lookupQualified(ctx, value.qualifiedName);
      return [
        requireAgentBlock(ctx, blockId, value.qualifiedName),
        value.qualifiedName,
      ];
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
    throw new RecoverableEngineError(
      `prim get_metadata: '${qname}' not found in irModule.entries`,
    );
  }
  return blockId;
}

function requireAgentBlock(
  ctx: StepCtx,
  blockId: BlockId,
  hint: string,
): AgentBlock {
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

