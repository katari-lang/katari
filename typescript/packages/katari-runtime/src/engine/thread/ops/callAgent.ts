// CallAgentThread ops — runtime side of the @call_agent(name, args)@
// primitive.
//
// On create:
//   1. Parse @nameStr@ into a callable identity:
//      - "closure:<id>" → ClosureId, looked up in state.closures
//      - "module.agent" → QualifiedName, looked up in irModule.entries
//   2. Read the target's `AgentBlock` to get `inputSchema` (and the
//      runtime endpoint — internal CORE loopback vs. external FFI).
//   3. Validate @argsRecord@ against the inputSchema; collect all
//      mismatches into one diagnostic string.
//   4. On success: emit an outbound `delegate` event with the args
//      record splatted into the per-label arguments the target
//      expects. Wait for the matching `delegateAck` (translated by
//      the runner into a `done` event).
//   5. On any of (a) unresolvable name, (b) target isn't an AgentBlock,
//      (c) validation errors: raise the `primitive.call_agent_error`
//      request upward and enter "waiting for cancel" state, just like
//      `PrimRaiseRequest` does for ordinary prims.
//
// Inbound asks (escalates from the peer) are forwarded upward as
// `ask` events to our parent, mirroring DelegateThread.

import { encodeCoreAgentDefId, encodeFfiAgentDefId, type AgentDefId } from "../../../agent-def-id.js";
import type { AgentBlock, BlockId, QualifiedName } from "../../../ir/types.js";
import type { Endpoint } from "../../endpoint.js";
import { createDelegationId, type AskId, type CallId, type ClosureId, type EscalationId } from "../../id.js";
import { validateAgainstSchema } from "../../schema-validate.js";
import type { StepCtx } from "../../step-ctx.js";
import { valueToRaw } from "../../../value-codec.js";
import type { Value } from "../../value.js";
import type { CallAgentThread, Thread } from "../types.js";
import { allocAskId, deleteThread, popAskForward } from "../common.js";
import { defaultAskAckProxy, defaultCancelAckUnexpected } from "./defaults.js";
import type { ThreadOps } from "./types.js";
import type { Json } from "../../../json.js";

export const callAgentOps: ThreadOps<CallAgentThread> = {
  create(ctx, t) {
    const resolved = resolveTarget(ctx, t);
    if (resolved.kind === "error") {
      raiseCallAgentError(ctx, t, resolved.message);
      return;
    }

    const schemaErrors = validateArgs(t.argsRecord, resolved.agentBlock);
    if (schemaErrors.length > 0) {
      raiseCallAgentError(
        ctx,
        t,
        `call_agent: args failed input schema:\n${schemaErrors.join("\n")}`,
      );
      return;
    }

    // Schema validated → emit the delegate event. The args record is
    // splatted as the per-label call args the target expects.
    const delegationId = createDelegationId();
    t.delegationId = delegationId;
    ctx.state.pendingDelegateOut[delegationId] = t.id;
    ctx.emit({
      from: ctx.state.selfEndpoint,
      to: resolved.peer,
      payload: {
        kind: "delegate",
        delegationId,
        agentDefId: resolved.agentDefId,
        args: { ...t.argsRecord },
      },
    });
  },

  /**
   * `done` arrives via the runner translating an inbound `delegateAck`.
   * Forward the value upstream as our own done.
   */
  done(ctx, t, _callId, value) {
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "done",
        target: t.parent,
        callId: t.parentCallId,
        value,
      });
    }
    deleteThread(ctx, t.id);
  },

  /**
   * Two cancel cases:
   *   - We have an outstanding delegation (= the happy-path child).
   *     Mirror DelegateThread: emit `terminate` and wait for ack.
   *   - We're in the error-raise state (= no child, only the upward
   *     ask). No child to terminate; immediately ack and exit.
   */
  cancel(ctx, t) {
    if (t.status === "cancelling") return;
    t.status = "cancelling";
    if (t.delegationId !== undefined) {
      ctx.emit({
        from: ctx.state.selfEndpoint,
        to: ctx.state.selfEndpoint, // peer is the same one we delegated to
        payload: { kind: "terminate", delegationId: t.delegationId },
      });
      // The terminateAck path goes through the runner and translates
      // into either a `done` (= still produced a value first) or a
      // `cancelAck`. Either way we finish via the normal `done`/cancel
      // path; nothing more to do here.
      return;
    }
    // Error-raise state: no child to wait on, ack the parent.
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "cancelAck",
        target: t.parent,
        callId: t.parentCallId,
      });
    }
    deleteThread(ctx, t.id);
  },

  cancelAck: defaultCancelAckUnexpected,

  /**
   * No children of our own; inbound `escalate` is translated by the
   * runner into a direct upward ask to our parent, bypassing us. Any
   * ask reaching us is an invariant violation.
   */
  ask(_ctx, t, askId) {
    throw new Error(
      `callAgent thread received ask (askId=${askId}) — CallAgentThread has no children`,
    );
  },

  /**
   * Two `askAck` shapes reach us:
   *   - Ack of an inbound-escalate-turned-upward-ask (mirrors
   *     DelegateThread): emit `escalateAck` back to the peer.
   *   - Ack of our own `call_agent_error` raise (= shouldn't happen
   *     for `-> never` requests but defensively no-op).
   */
  askAck(ctx, t, askId, value) {
    if (t.pendingAskId !== undefined && t.pendingAskId === askId) {
      ctx.log("debug", "engine.callAgent: dropped askAck for never-returning request", {
        threadId: t.id,
        askId,
      });
      return;
    }
    const escalationId = t.inboundEscalations[askId];
    if (escalationId !== undefined) {
      delete t.inboundEscalations[askId];
      ctx.emit({
        from: ctx.state.selfEndpoint,
        to: ctx.state.selfEndpoint,
        payload: { kind: "escalateAck", escalationId, value },
      });
      return;
    }
    defaultAskAckProxy<CallAgentThread>(ctx, t as CallAgentThread, askId, value);
    void popAskForward; // satisfy unused-imports check
  },
};

// ─── helpers ───────────────────────────────────────────────────────────────

type Resolved =
  | {
      kind: "ok";
      peer: Endpoint;
      agentDefId: AgentDefId;
      agentBlock: AgentBlock;
    }
  | { kind: "error"; message: string };

function resolveTarget(ctx: StepCtx, t: CallAgentThread): Resolved {
  const closurePrefix = "closure:";
  if (t.nameStr.startsWith(closurePrefix)) {
    const idStr = t.nameStr.slice(closurePrefix.length);
    const id = Number(idStr);
    if (!Number.isInteger(id) || id < 0) {
      return {
        kind: "error",
        message: `call_agent: bad closure id in '${t.nameStr}'`,
      };
    }
    const closureId = id as ClosureId;
    const record = ctx.state.closures[closureId];
    if (record === undefined) {
      return {
        kind: "error",
        message: `call_agent: closure ${closureId} not in state.closures`,
      };
    }
    const agentBlock = requireAgentBlock(ctx, record.blockId, t.nameStr);
    if (agentBlock === null) {
      return {
        kind: "error",
        message: `call_agent: target '${t.nameStr}' is not an agent block`,
      };
    }
    return {
      kind: "ok",
      peer: ctx.state.selfEndpoint,
      agentDefId: encodeCoreAgentDefId({ kind: "closure", value: closureId }),
      agentBlock,
    };
  }
  if (t.nameStr === "") {
    return {
      kind: "error",
      message: "call_agent: name must be a non-empty string",
    };
  }

  // Otherwise treat as qualified name.
  const qname: QualifiedName = t.nameStr;
  const blockId = ctx.state.irModule.entries[qname];
  if (blockId === undefined) {
    return {
      kind: "error",
      message: `call_agent: name '${qname}' not found in irModule.entries`,
    };
  }
  const agentBlock = requireAgentBlock(ctx, blockId, qname);
  if (agentBlock === null) {
    return {
      kind: "error",
      message: `call_agent: target '${qname}' is not an agent block`,
    };
  }
  // Decide internal vs. external by entries presence + sidecar metadata.
  // For now, every entry resolves to internal CORE loopback (the wrapper
  // agent created by the compiler eventually trampolines to the
  // external / prim / data leaf as needed).
  return {
    kind: "ok",
    peer: ctx.state.selfEndpoint,
    agentDefId: encodeCoreAgentDefId({ kind: "qname", value: qname }),
    agentBlock,
  };
}

function requireAgentBlock(
  ctx: StepCtx,
  blockId: BlockId,
  hint: string,
): AgentBlock | null {
  const block = ctx.state.irModule.blocks[String(blockId)];
  if (block === undefined) {
    ctx.log("warn", "callAgent: block missing from irModule.blocks", {
      blockId,
      hint,
    });
    return null;
  }
  if (block.kind !== "blockAgent") {
    return null;
  }
  return block.body;
}

function validateArgs(
  argsRecord: Record<string, Value>,
  agentBlock: AgentBlock,
): string[] {
  let schema: Json;
  try {
    schema = JSON.parse(agentBlock.inputSchema) as Json;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return [`failed to parse inputSchema as JSON: ${msg}`];
  }
  // Convert each Value to its raw wire form. The schema is a plain
  // JSON Schema document; validation operates on raw JSON, not on
  // Value objects.
  const rawArgs: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(argsRecord)) {
    rawArgs[k] = valueToRaw(v);
  }
  return validateAgainstSchema(rawArgs, schema);
}

function raiseCallAgentError(
  ctx: StepCtx,
  t: CallAgentThread,
  message: string,
): void {
  if (t.parent === null || t.parentCallId === null) {
    ctx.log("warn", "engine.callAgent: error at root thread with no parent", {
      threadId: t.id,
      message,
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
      reqId: "primitive.call_agent_error",
      args: {
        message: { kind: "string", value: message },
      },
    },
    childCallId: t.parentCallId,
  });
}

// Suppress unused-imports check for the type re-exports used in the
// `Resolved` discriminated union above (TS can otherwise mark them as
// unused even though they're referenced inside the type alias).
void (null as unknown as EscalationId);
void (null as unknown as CallId);
