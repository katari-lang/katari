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

import { encodeCoreAgentDefId } from "../../../agent-def-id.js";
import type { AgentBlock, BlockId, QualifiedName } from "../../../ir/types.js";
import { decodeClosureBlob } from "../../closure-codec.js";
import { RecoverableEngineError } from "../../errors.js";
import { fillGenericSchema } from "../../generics.js";
import type { AskId, CallId } from "../../id.js";
import { executePrim, PrimRaiseRequest } from "../../prim.js";
import type { StepCtx } from "../../step-ctx.js";
import { mkString, type Value } from "../../value.js";
import { allocAskId, deleteThread, emitThrowEscalate } from "../common.js";
import type { PrimThread, Thread } from "../types.js";
import { defaultAskProxy } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const primOps: ThreadOps<PrimThread> = {
  async create(ctx, t) {
    let value: Value | undefined;
    try {
      // `get_metadata` needs the IR module + closures table to resolve a
      // callable Value back to its `AgentBlock`. Branch here rather than
      // in `executePrim` since that resolution needs engine state.
      // `executePrim` is async because content-transform prims (concat)
      // may materialize ref bytes; `ctx.materialize` is the injected,
      // deterministic content-addressed read.
      value =
        t.primName === "primitive.get_metadata"
          ? await executeGetMetadata(ctx, t.args)
          : await executePrim(t.primName, t.args, ctx.materialize, ctx.putBlob);
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
// value for any callable. The compiled schema comes from the `AgentBlock` for a
// top-level callable (resolved through `IRModule.entries`), or from the
// closure's self-describing blob for a closure ref (fetched via the injected
// content read). Async because the closure path materializes that blob.

/** The shape get_metadata projects, regardless of callable source. */
type CallableMetadata = {
  name: string;
  description?: string;
  inputSchema: string;
  outputSchema: string;
  /** Dispatch identity surfaced to AI tool calls (qname / closure:<hash>). */
  id: string;
};

async function executeGetMetadata(ctx: StepCtx, args: Record<string, Value>): Promise<Value> {
  const value = args["value"];
  if (value === undefined) {
    throw new RecoverableEngineError("prim get_metadata: missing argument 'value'");
  }
  const meta = await resolveCallableMetadata(ctx, value);
  // If the callable value carries a generic substitution (from a `foo[args]`
  // instantiation), specialise its GenericSchema — replace each `$generic`
  // placeholder with the substituted type's concrete schema.
  const generics =
    value.kind === "agentLiteral" || value.kind === "closure" ? value.generics : undefined;
  const fill = (schemaJson: string): string =>
    generics === undefined
      ? schemaJson
      : JSON.stringify(fillGenericSchema(generics, JSON.parse(schemaJson)));
  return {
    kind: "record",
    ctor: "primitive.agent_metadata",
    entries: {
      name: mkString(meta.name),
      id: mkString(meta.id),
      description: mkString(meta.description ?? ""),
      input: mkString(fill(meta.inputSchema)),
      output: mkString(fill(meta.outputSchema)),
    },
  };
}

async function resolveCallableMetadata(ctx: StepCtx, value: Value): Promise<CallableMetadata> {
  switch (value.kind) {
    case "agentLiteral": {
      const blockId = lookupQualified(ctx, value.qualifiedName);
      const block = requireAgentBlock(ctx, blockId, value.qualifiedName);
      return {
        name: block.name,
        description: block.description,
        inputSchema: block.inputSchema,
        outputSchema: block.outputSchema,
        // The dispatch handle surfaced to tool calls — the external form
        // (`qname@snapshot`), identical to the agent value's wire `$agent`.
        id: encodeCoreAgentDefId({
          kind: "qname",
          value: value.qualifiedName,
          snapshot: value.snapshot,
        }),
      };
    }
    case "closure": {
      // The closure is self-describing: its blob carries the body block's
      // compiled schema, so we fetch + read it without resolving the block
      // against an IR. The `id` is informational (re-dispatch is by the value).
      const content = decodeClosureBlob(await ctx.materialize(value.ref));
      const m = content.metadata;
      return {
        name: m.name,
        description: m.description,
        inputSchema: m.inputSchema,
        outputSchema: m.outputSchema,
        // The dispatch handle, identical to the closure value's wire form +
        // delegate target — `closureref:<ref id>` (cf. a top-level agent's
        // `id` = its qname). The ref id, not the content hash.
        id: encodeCoreAgentDefId({ kind: "closureRef", id: value.ref.id }),
      };
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
