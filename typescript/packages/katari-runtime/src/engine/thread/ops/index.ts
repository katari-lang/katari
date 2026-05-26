// Dispatch table: route an internal event to the appropriate variant op.
//
// `dispatch*` functions are exhaustive over Thread kinds via ts-pattern.
// Each Thread kind ships its own ops module; this file wires them in.
//
// Phase B (current state): only `prim` and `ctor` ops are implemented.
// Other kinds throw a placeholder error that lists which method/kind
// hasn't landed yet — useful for spotting integration gaps as variants
// come online.

import { match } from "ts-pattern";
import type { AskKind } from "../../event.js";
import type { AskId, CallId } from "../../id.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import type { Thread } from "../types.js";
import { agentOps } from "./agent.js";
import { arrayOps } from "./array.js";
import { callAgentOps } from "./callAgent.js";
import { ctorOps } from "./ctor.js";
import { delegateOps } from "./delegate.js";
import { forOps } from "./for.js";
import { handleOps } from "./handle.js";
import { matchOps } from "./match.js";
import { primOps } from "./prim.js";
import { requestOps } from "./request.js";
import { recordOps } from "./record.js";
import { tupleOps } from "./tuple.js";
import { userOps } from "./user.js";

// ─── Per-method dispatch ───────────────────────────────────────────────────

export function dispatchCreate(ctx: StepCtx, t: Thread): void {
  match(t)
    .with({ kind: "agent" }, x => agentOps.create(ctx, x))
    .with({ kind: "prim" }, x => primOps.create(ctx, x))
    .with({ kind: "ctor" }, x => ctorOps.create(ctx, x))
    .with({ kind: "tuple" }, x => tupleOps.create(ctx, x))
    .with({ kind: "array" }, x => arrayOps.create(ctx, x))
    .with({ kind: "record" }, x => recordOps.create(ctx, x))
    .with({ kind: "match" }, x => matchOps.create(ctx, x))
    .with({ kind: "user" }, x => userOps.create(ctx, x))
    .with({ kind: "for" }, x => forOps.create(ctx, x))
    .with({ kind: "request" }, x => requestOps.create(ctx, x))
    .with({ kind: "delegate" }, x => delegateOps.create(ctx, x))
    .with({ kind: "handle" }, x => handleOps.create(ctx, x))
    .with({ kind: "callAgent" }, x => callAgentOps.create(ctx, x))
    .exhaustive();
}

export function dispatchDone(
  ctx: StepCtx,
  t: Thread,
  callId: CallId,
  value: Value,
): void {
  match(t)
    .with({ kind: "agent" }, x => agentOps.done(ctx, x, callId, value))
    .with({ kind: "prim" }, x => primOps.done(ctx, x, callId, value))
    .with({ kind: "ctor" }, x => ctorOps.done(ctx, x, callId, value))
    .with({ kind: "tuple" }, x => tupleOps.done(ctx, x, callId, value))
    .with({ kind: "array" }, x => arrayOps.done(ctx, x, callId, value))
    .with({ kind: "record" }, x => recordOps.done(ctx, x, callId, value))
    .with({ kind: "match" }, x => matchOps.done(ctx, x, callId, value))
    .with({ kind: "user" }, x => userOps.done(ctx, x, callId, value))
    .with({ kind: "for" }, x => forOps.done(ctx, x, callId, value))
    .with({ kind: "request" }, x => requestOps.done(ctx, x, callId, value))
    .with({ kind: "delegate" }, x => delegateOps.done(ctx, x, callId, value))
    .with({ kind: "handle" }, x => handleOps.done(ctx, x, callId, value))
    .with({ kind: "callAgent" }, x => callAgentOps.done(ctx, x, callId, value))
    .exhaustive();
}

export function dispatchCancel(ctx: StepCtx, t: Thread): void {
  match(t)
    .with({ kind: "agent" }, x => agentOps.cancel(ctx, x))
    .with({ kind: "prim" }, x => primOps.cancel(ctx, x))
    .with({ kind: "ctor" }, x => ctorOps.cancel(ctx, x))
    .with({ kind: "tuple" }, x => tupleOps.cancel(ctx, x))
    .with({ kind: "array" }, x => arrayOps.cancel(ctx, x))
    .with({ kind: "record" }, x => recordOps.cancel(ctx, x))
    .with({ kind: "match" }, x => matchOps.cancel(ctx, x))
    .with({ kind: "user" }, x => userOps.cancel(ctx, x))
    .with({ kind: "for" }, x => forOps.cancel(ctx, x))
    .with({ kind: "request" }, x => requestOps.cancel(ctx, x))
    .with({ kind: "delegate" }, x => delegateOps.cancel(ctx, x))
    .with({ kind: "handle" }, x => handleOps.cancel(ctx, x))
    .with({ kind: "callAgent" }, x => callAgentOps.cancel(ctx, x))
    .exhaustive();
}

export function dispatchCancelAck(
  ctx: StepCtx,
  t: Thread,
  callId: CallId,
): void {
  match(t)
    .with({ kind: "agent" }, x => agentOps.cancelAck(ctx, x, callId))
    .with({ kind: "prim" }, x => primOps.cancelAck(ctx, x, callId))
    .with({ kind: "ctor" }, x => ctorOps.cancelAck(ctx, x, callId))
    .with({ kind: "tuple" }, x => tupleOps.cancelAck(ctx, x, callId))
    .with({ kind: "array" }, x => arrayOps.cancelAck(ctx, x, callId))
    .with({ kind: "record" }, x => recordOps.cancelAck(ctx, x, callId))
    .with({ kind: "match" }, x => matchOps.cancelAck(ctx, x, callId))
    .with({ kind: "user" }, x => userOps.cancelAck(ctx, x, callId))
    .with({ kind: "for" }, x => forOps.cancelAck(ctx, x, callId))
    .with({ kind: "request" }, x => requestOps.cancelAck(ctx, x, callId))
    .with({ kind: "delegate" }, x => delegateOps.cancelAck(ctx, x, callId))
    .with({ kind: "handle" }, x => handleOps.cancelAck(ctx, x, callId))
    .with({ kind: "callAgent" }, x => callAgentOps.cancelAck(ctx, x, callId))
    .exhaustive();
}

export function dispatchAsk(
  ctx: StepCtx,
  t: Thread,
  askId: AskId,
  kind: AskKind,
  childCallId: CallId,
): void {
  match(t)
    .with({ kind: "agent" }, x => agentOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "prim" }, x => primOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "ctor" }, x => ctorOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "tuple" }, x => tupleOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "array" }, x => arrayOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "record" }, x => recordOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "match" }, x => matchOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "user" }, x => userOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "for" }, x => forOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "request" }, x => requestOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "delegate" }, x => delegateOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "handle" }, x => handleOps.ask(ctx, x, askId, kind, childCallId))
    .with({ kind: "callAgent" }, x => callAgentOps.ask(ctx, x, askId, kind, childCallId))
    .exhaustive();
}

export function dispatchAskAck(
  ctx: StepCtx,
  t: Thread,
  askId: AskId,
  value: Value,
): void {
  match(t)
    .with({ kind: "agent" }, x => agentOps.askAck(ctx, x, askId, value))
    .with({ kind: "prim" }, x => primOps.askAck(ctx, x, askId, value))
    .with({ kind: "ctor" }, x => ctorOps.askAck(ctx, x, askId, value))
    .with({ kind: "tuple" }, x => tupleOps.askAck(ctx, x, askId, value))
    .with({ kind: "array" }, x => arrayOps.askAck(ctx, x, askId, value))
    .with({ kind: "record" }, x => recordOps.askAck(ctx, x, askId, value))
    .with({ kind: "match" }, x => matchOps.askAck(ctx, x, askId, value))
    .with({ kind: "user" }, x => userOps.askAck(ctx, x, askId, value))
    .with({ kind: "for" }, x => forOps.askAck(ctx, x, askId, value))
    .with({ kind: "request" }, x => requestOps.askAck(ctx, x, askId, value))
    .with({ kind: "delegate" }, x => delegateOps.askAck(ctx, x, askId, value))
    .with({ kind: "handle" }, x => handleOps.askAck(ctx, x, askId, value))
    .with({ kind: "callAgent" }, x => callAgentOps.askAck(ctx, x, askId, value))
    .exhaustive();
}
