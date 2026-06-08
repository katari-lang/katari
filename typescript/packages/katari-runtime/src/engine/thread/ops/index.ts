// Dispatch table: route an internal event to the appropriate variant op.
//
// Each Thread kind ships its own ops module; this file wires them into a
// single lookup table keyed by `Thread["kind"]`. The six `dispatch*`
// functions resolve the ops object in O(1) and invoke the method.

import type { AskKind } from "../../event.js";
import type { AskId, CallId } from "../../id.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import type { Thread, ThreadKind } from "../types.js";
import { agentOps } from "./agent.js";
import { callAgentOps } from "./callAgent.js";
import { ctorOps } from "./ctor.js";
import { delegateOps } from "./delegate.js";
import { forOps } from "./for.js";
import { getFieldOps } from "./getField.js";
import { handleOps } from "./handle.js";
import { matchOps } from "./match.js";
import { primOps } from "./prim.js";
import { recordOps } from "./record.js";
import { requestOps } from "./request.js";
import { tupleOps } from "./tuple.js";
import type { ThreadOps } from "./types.js";
import { userOps } from "./user.js";

// ─── Lookup table ─────────────────────────────────────────────────────────

const opsTable: Record<ThreadKind, ThreadOps<any>> = {
  agent: agentOps,
  prim: primOps,
  ctor: ctorOps,
  tuple: tupleOps,
  record: recordOps,
  match: matchOps,
  getField: getFieldOps,
  user: userOps,
  for: forOps,
  request: requestOps,
  delegate: delegateOps,
  handle: handleOps,
  callAgent: callAgentOps,
};

function getOps(t: Thread): ThreadOps<any> {
  return opsTable[t.kind];
}

// ─── Per-method dispatch ───────────────────────────────────────────────────

export async function dispatchCreate(ctx: StepCtx, t: Thread): Promise<void> {
  await getOps(t).create(ctx, t);
}

export function dispatchDone(ctx: StepCtx, t: Thread, callId: CallId, value: Value): void {
  getOps(t).done(ctx, t, callId, value);
}

export function dispatchCancel(ctx: StepCtx, t: Thread): void {
  getOps(t).cancel(ctx, t);
}

export function dispatchCancelAck(ctx: StepCtx, t: Thread, callId: CallId): void {
  getOps(t).cancelAck(ctx, t, callId);
}

export function dispatchAsk(
  ctx: StepCtx,
  t: Thread,
  askId: AskId,
  kind: AskKind,
  childCallId: CallId,
): void {
  getOps(t).ask(ctx, t, askId, kind, childCallId);
}

export function dispatchAskAck(ctx: StepCtx, t: Thread, askId: AskId, value: Value): void {
  getOps(t).askAck(ctx, t, askId, value);
}
