// CallAgentThread ops — runtime side of the @call_agent(name, args)@
// primitive.
//
// On create:
//   1. Resolve @nameStr@ into a callable identity. @nameStr@ is always the
//      EXTERNAL dispatch handle — exactly what `get_metadata` returns and an
//      agent value carries on the wire (call_agent is only for an id that came
//      through a string/RawValue; a statically-known agent is called by value):
//      - "module.agent@snapshot" → a top-level callable. The bare qname (sans
//        `@snapshot`) keys irModule.entries; a BARE id is rejected (it's the
//        internal namespace — ambiguous as a wire id).
//      - "closureref:<id>" → a content-ref closure: fetch its blob (the input
//        schema lives there) + dispatch by the ref; CORE materializes it.
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

import {
  type AgentDefId,
  decodeCoreAgentDefId,
  encodeCoreAgentDefId,
} from "../../../agent-def-id.js";
import type { AgentBlock, BlockId, QualifiedName } from "../../../ir/types.js";
import type { Json } from "../../../json.js";
import { valueToRaw } from "../../../value-codec.js";
import { decodeClosureBlob } from "../../closure-codec.js";
import type { Endpoint } from "../../endpoint.js";
import { type AskId, createDelegationId } from "../../id.js";
import { relaxedSchemaFromString, validateAgainstSchema } from "../../schema-validate.js";
import type { StepCtx } from "../../step-ctx.js";
import { mkString, type RefRep, type Value } from "../../value.js";
import { allocAskId, deleteThread } from "../common.js";
import type { CallAgentThread, Thread } from "../types.js";
import { defaultAskAckProxy, defaultCancelAckUnexpected } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const callAgentOps: ThreadOps<CallAgentThread> = {
  async create(ctx, t) {
    const resolved = await resolveTarget(ctx, t);
    if (resolved.kind === "error") {
      raiseCallAgentError(ctx, t, resolved.message);
      return;
    }

    const schemaErrors = validateArgs(t.argsRecord, resolved.inputSchema);
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
  ask(_ctx, _t, askId) {
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
  },
};

// ─── helpers ───────────────────────────────────────────────────────────────

type Resolved =
  | {
      kind: "ok";
      peer: Endpoint;
      agentDefId: AgentDefId;
      /** The target's input schema (compiled JSON Schema string) for arg
       *  validation — from the IR for a qname, from the blob for a closure. */
      inputSchema: string;
    }
  | { kind: "error"; message: string };

async function resolveTarget(ctx: StepCtx, t: CallAgentThread): Promise<Resolved> {
  // A content-ref closure (the dispatch handle a closure value / `get_metadata`
  // carries). Fetch its blob to read the declared input schema — the body block
  // lives in the blob, not the IR — then dispatch by the ref id; CORE
  // materializes it into a fresh shard on the inbound delegate.
  const closureRefPrefix = "closureref:";
  if (t.nameStr.startsWith(closureRefPrefix)) {
    const refId = t.nameStr.slice(closureRefPrefix.length);
    if (refId === "") {
      return { kind: "error", message: `call_agent: empty closure ref in '${t.nameStr}'` };
    }
    const ref: RefRep = { kind: "ref", module: "core", id: refId, hash: "", size: 0 };
    let inputSchema: string;
    try {
      inputSchema = decodeClosureBlob(await ctx.materialize(ref)).metadata.inputSchema;
    } catch (e) {
      return {
        kind: "error",
        message: `call_agent: closure ref '${refId}' not resolvable: ${e instanceof Error ? e.message : String(e)}`,
      };
    }
    return {
      kind: "ok",
      peer: ctx.state.selfEndpoint,
      agentDefId: encodeCoreAgentDefId({ kind: "closureRef", id: refId }),
      inputSchema,
    };
  }
  if (t.nameStr === "") {
    return {
      kind: "error",
      message: "call_agent: name must be a non-empty string",
    };
  }

  // Otherwise a qualified name. call_agent only ever takes an id that arrived
  // as a string / RawValue — i.e. the EXTERNAL form, which always carries its
  // snapshot (`qualified.name@snapshot`). A bare qname is the INTERNAL id and is
  // rejected: a statically-known agent is dispatched by calling its (first-class)
  // value directly — call_agent is only for an id you got as a string, which is
  // always `get_metadata.id` (external). (The in-shard `closure:N` form is
  // engine-internal and never a user-facing name.)
  const decoded = decodeCoreAgentDefId(t.nameStr as AgentDefId);
  if (decoded.kind !== "qname") {
    return { kind: "error", message: `call_agent: '${t.nameStr}' is not an agent name` };
  }
  if (decoded.snapshot === undefined) {
    return {
      kind: "error",
      message: `call_agent: '${t.nameStr}' is a bare name — call_agent needs the external id (\`qualified.name@snapshot\` / \`closureref:<id>\`, e.g. from get_metadata)`,
    };
  }
  // The bare id (sans `@snapshot`) is the IR-entries lookup key; the snapshot
  // rides through to the delegate target.
  const qname: QualifiedName = decoded.value;
  const snapshot = decoded.snapshot;
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
    agentDefId: encodeCoreAgentDefId({ kind: "qname", value: qname, snapshot }),
    inputSchema: agentBlock.inputSchema,
  };
}

function requireAgentBlock(ctx: StepCtx, blockId: BlockId, hint: string): AgentBlock | null {
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

function validateArgs(argsRecord: Record<string, Value>, inputSchema: string): string[] {
  let schema: Json;
  try {
    // Relax string nodes to also accept a `$ref as:"string"` envelope: a
    // runtime arg may be a promoted (content-ref) string while the schema says
    // `{type:"string"}`. Callables need no relaxation — agents and closures
    // both serialise as `$agent`, matching the callable schema as-is.
    schema = relaxedSchemaFromString(inputSchema);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return [`failed to parse inputSchema as JSON: ${msg}`];
  }
  // Convert each Value to its raw wire form. The schema is a plain JSON Schema
  // document; validation operates on raw JSON, not on Value objects.
  const rawArgs: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(argsRecord)) {
    rawArgs[k] = valueToRaw(v);
  }
  return validateAgainstSchema(rawArgs, schema);
}

function raiseCallAgentError(ctx: StepCtx, t: CallAgentThread, message: string): void {
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
        message: mkString(message),
      },
    },
    childCallId: t.parentCallId,
  });
}
