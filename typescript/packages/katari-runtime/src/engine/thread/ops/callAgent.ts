// CallAgentThread ops — runtime side of the
// @call_agent[R, effect E](target, args)@ primitive.
//
// On create:
//   1. Resolve the @target@ VALUE into a callable identity (mirrors
//      DelegateThread's value dispatch): an `agentLiteral` dispatches
//      CORE-internal when its qname is in the IR entries (else FFI); a
//      `closure` resolves through the CORE-global closure store and is invoked
//      IN-SHARD (no delegate). The value also carries any generic substitution.
//   2. Read the target's input schema, specialise it to the value's generics,
//      and validate @argsRecord@ against it; collect mismatches into one
//      diagnostic string.
//   3. On success: for an agent target, emit an outbound `delegate` event and
//      wait for the `delegateAck` (translated by the runner into a `done`); for
//      a closure target, spawn the body as a thread in the current shard over
//      the captured scope (the body `done`s us directly).
//   4. On (a) an un-callable target, or (b) validation errors: raise the
//      `primitive.error_invalid_argument` request upward and enter the
//      "waiting for cancel" state, like `PrimRaiseRequest` for ordinary prims.

import {
  type AgentDefId,
  encodeCoreAgentDefId,
  encodeFfiAgentDefId,
} from "../../../agent-def-id.js";
import type { AgentBlock, BlockId } from "../../../ir/types.js";
import type { Json } from "../../../json.js";
import { valueToRaw } from "../../../value-codec.js";
import type { Endpoint } from "../../endpoint.js";
import { fillGenericSchema } from "../../generics.js";
import { type AskId, type ClosureId, createDelegationId } from "../../id.js";
import { relaxedSchemaFromString, validateAgainstSchema } from "../../schema-validate.js";
import { spawnAgentRoot } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import { mkRecord, mkString, type Value } from "../../value.js";
import {
  allocAskId,
  allocCallId,
  beginCancel,
  commonRemoveChild,
  deleteThread,
  hasChildren,
  proxyAskToParent,
} from "../common.js";
import type { CallAgentThread, Thread } from "../types.js";
import { defaultAskAckProxy } from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const callAgentOps: ThreadOps<CallAgentThread> = {
  create(ctx, t) {
    const resolved = resolveTarget(ctx, t);
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

    if (resolved.kind === "closure") {
      // In-shard closure call: spawn the body as our child over the captured
      // scope (the global store). The args record is the body's single argument;
      // the target's generics become the body's ambient substitution.
      const record = ctx.store.closures[resolved.closureId];
      if (record === undefined) {
        raiseCallAgentError(
          ctx,
          t,
          `call_agent: closure '${resolved.closureId}' not found (its owner entity may have been released)`,
        );
        return;
      }
      const callId = allocCallId(t as Thread);
      spawnAgentRoot(ctx, {
        blockId: record.blockId,
        argument: mkRecord({ ...t.argsRecord }),
        delegationId: createDelegationId(), // synthetic — non-root agent
        capturedScopeId: record.scopeId,
        parent: { threadId: t.id, callId },
        ...(resolved.generics !== undefined ? { ambientGenerics: resolved.generics } : {}),
      });
      return;
    }

    // Agent target → emit the delegate event. The args record becomes the
    // target's single argument value; its generic substitution rides along.
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
   * For an in-shard closure call, our body AgentThread child finished — remove
   * it and forward its value to our parent, whose `commonRemoveChild` deletes US
   * (mirrors the cross-shard ack, which the runner routes straight to the parent).
   */
  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as CallAgentThread, callId)) return;
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({ kind: "done", target: t.parent, callId: t.parentCallId, value });
    }
  },

  /**
   * Three cancel cases:
   *   - In-shard closure call (we own the body child): cascade cancel to it.
   *   - Outstanding delegation (agent target): emit `terminate` and wait.
   *   - Error-raise state (no child, only the upward ask): ack and exit.
   */
  cancel(ctx, t) {
    if (t.status === "cancelling") return;
    if (hasChildren(t)) {
      beginCancel(ctx, t as Thread);
      return;
    }
    t.status = "cancelling";
    if (t.delegationId !== undefined) {
      ctx.emit({
        from: ctx.state.selfEndpoint,
        to: ctx.state.selfEndpoint, // peer is the same one we delegated to
        payload: { kind: "terminate", delegationId: t.delegationId },
      });
      // The terminateAck path goes through the runner and translates
      // into either a `done` or a `cancelAck`; nothing more to do here.
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

  /** In-shard closure call: the body child finished cancelling — common
   *  bookkeeping fires `finishCancelling` (→ cancelAck to our parent). */
  cancelAck(ctx, t, callId) {
    commonRemoveChild(ctx, t as CallAgentThread, callId);
  },

  /**
   * In-shard closure call: a control / request ask from the body child bubbles
   * here — proxy it up to our parent. (Cross-shard delegates have no children;
   * an inbound `escalate` is converted by the runner into an upward ask directly,
   * so reaching here always means the in-shard case.)
   */
  ask(ctx, t, askId, kind, childCallId) {
    proxyAskToParent(ctx, t as Thread, childCallId, askId, kind);
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
       *  carrying `$generic` placeholders) — from the IR for an agent value. */
      inputSchema: string;
    }
  | {
      kind: "closure";
      closureId: ClosureId;
      generics?: Record<string, Json>;
      inputSchema: string;
    }
  | { kind: "error"; message: string };

// Resolve the call target from the supplied VALUE (mirrors DelegateThread's
// value dispatch), additionally surfacing the input schema so create() can
// validate the dynamic args. An agent value dispatches CORE-internal when its
// qname is in the IR entries, else FFI; a closure resolves through the CORE-global
// store and is invoked in-shard.
function resolveTarget(ctx: StepCtx, t: CallAgentThread): Resolved {
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
    const record = ctx.store.closures[target.closureId];
    if (record === undefined) {
      return {
        kind: "error",
        message: `call_agent: closure '${target.closureId}' not found (its owner entity may have been released)`,
      };
    }
    const block = requireAgentBlock(ctx, record.blockId, `closure:${target.closureId}`);
    if (block === null) {
      return {
        kind: "error",
        message: `call_agent: closure '${target.closureId}' body is not an agent block`,
      };
    }
    return {
      kind: "closure",
      closureId: target.closureId,
      generics: target.generics,
      inputSchema: block.inputSchema,
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
