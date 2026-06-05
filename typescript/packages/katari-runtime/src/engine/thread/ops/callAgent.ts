// CallAgentThread ops — runtime side of the
// @call_agent[R, effect E](target, args)@ primitive.
//
// On create:
//   1. Resolve the @target@ VALUE into a callable identity (mirrors
//      DelegateThread's value dispatch): an `agentLiteral` dispatches
//      CORE-internal when its qname is in the IR entries (else FFI); a
//      `closure` always dispatches on CORE (fetch its blob for the input
//      schema). The value also carries any generic substitution.
//   2. Read the target's input schema, specialise it to the value's generics,
//      and validate @argsRecord@ against it; collect mismatches into one
//      diagnostic string.
//   3. On success: emit an outbound `delegate` event — @argsRecord@ becomes the
//      target's single argument value, the generics ride along — and wait for
//      the matching `delegateAck` (translated by the runner into a `done`).
//   4. On (a) an un-callable target, or (b) validation errors: raise the
//      `primitive.error_invalid_argument` request upward and enter the
//      "waiting for cancel" state, just like `PrimRaiseRequest` for ordinary
//      prims.
//
// Inbound asks (escalates from the peer) are forwarded upward as
// `ask` events to our parent, mirroring DelegateThread.

import {
  type AgentDefId,
  encodeCoreAgentDefId,
  encodeFfiAgentDefId,
} from "../../../agent-def-id.js";
import type { AgentBlock, BlockId } from "../../../ir/types.js";
import type { Json } from "../../../json.js";
import { valueToRaw } from "../../../value-codec.js";
import { decodeClosureBlob } from "../../closure-codec.js";
import type { Endpoint } from "../../endpoint.js";
import { fillGenericSchema } from "../../generics.js";
import { type AskId, createDelegationId } from "../../id.js";
import { relaxedSchemaFromString, validateAgainstSchema } from "../../schema-validate.js";
import type { StepCtx } from "../../step-ctx.js";
import { mkRecord, mkString, type Value } from "../../value.js";
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

    const schemaErrors = validateArgs(t.argsRecord, resolved.inputSchema, resolved.generics);
    if (schemaErrors.length > 0) {
      raiseCallAgentError(
        ctx,
        t,
        `call_agent: args failed input schema:\n${schemaErrors.join("\n")}`,
      );
      return;
    }

    // Schema validated → emit the delegate event. The args record becomes the
    // target's single argument value; the target's generic substitution rides
    // along so it runs specialised.
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
        argument: mkRecord({ ...t.argsRecord }),
        ...(resolved.generics !== undefined ? { generics: resolved.generics } : {}),
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
      /** The target value's generic substitution, carried through to the
       *  delegate (and used to specialise `inputSchema` before validation). */
      generics?: Record<string, Json>;
      /** The target's input schema (compiled JSON Schema string, possibly
       *  carrying `$generic` placeholders) — from the IR for an agent value,
       *  from the blob for a closure. */
      inputSchema: string;
    }
  | { kind: "error"; message: string };

// Resolve the call target from the supplied VALUE (mirrors DelegateThread's
// value dispatch), additionally surfacing the input schema so create() can
// validate the dynamic args. An agent value dispatches CORE-internal when its
// qname is in the IR entries, else FFI; a closure always dispatches on CORE.
async function resolveTarget(ctx: StepCtx, t: CallAgentThread): Promise<Resolved> {
  const target = t.target;
  if (target.kind === "agentLiteral") {
    const qname = target.qualifiedName;
    const snapshot = target.snapshot;
    const blockId = ctx.state.irModule.entries[qname];
    if (blockId === undefined) {
      return {
        kind: "ok",
        peer: ctx.state.ffiTargetEndpoint,
        agentDefId: encodeFfiAgentDefId({ kind: "qname", value: qname, snapshot }),
        generics: target.generics,
        // An FFI target's schema isn't on the CORE side; skip validation (the
        // sidecar validates). An open schema accepts anything.
        inputSchema: "{}",
      };
    }
    const block = requireAgentBlock(ctx, blockId, qname);
    if (block === null) {
      return { kind: "error", message: `call_agent: target '${qname}' is not an agent block` };
    }
    return {
      kind: "ok",
      peer: ctx.state.selfEndpoint,
      agentDefId: encodeCoreAgentDefId({ kind: "qname", value: qname, snapshot }),
      generics: target.generics,
      inputSchema: block.inputSchema,
    };
  }
  if (target.kind === "closure") {
    let inputSchema: string;
    try {
      inputSchema = decodeClosureBlob(await ctx.materialize(target.ref)).metadata.inputSchema;
    } catch (e) {
      return {
        kind: "error",
        message: `call_agent: closure '${target.ref.id}' not resolvable: ${e instanceof Error ? e.message : String(e)}`,
      };
    }
    return {
      kind: "ok",
      peer: ctx.state.selfEndpoint,
      agentDefId: encodeCoreAgentDefId({ kind: "closureRef", id: target.ref.id }),
      generics: target.generics,
      inputSchema,
    };
  }
  return {
    kind: "error",
    message: `call_agent: target is not a callable value (got ${target.kind})`,
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

function validateArgs(
  argsRecord: Record<string, Value>,
  inputSchema: string,
  generics: Record<string, Json> | undefined,
): string[] {
  let schema: Json;
  try {
    // Specialise the target's schema to its generic substitution first (the
    // value carries it), so `foo[int]`'s args validate against `int`, not the
    // `$generic` placeholder. Then relax string nodes to also accept a
    // `$ref as:"string"` envelope (a promoted content-ref string vs a
    // `{type:"string"}` schema). Callables need no relaxation — agents and
    // closures both serialise as `$agent`, matching the callable schema as-is.
    const filled =
      generics === undefined
        ? inputSchema
        : JSON.stringify(fillGenericSchema(generics, JSON.parse(inputSchema)));
    schema = relaxedSchemaFromString(filled);
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
      reqId: "primitive.error_invalid_argument",
      argument: mkRecord({ message: mkString(message) }),
    },
    childCallId: t.parentCallId,
  });
}
