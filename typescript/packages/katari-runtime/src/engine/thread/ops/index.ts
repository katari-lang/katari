// Dispatch table: route an internal event to the appropriate variant op.
//
// `dispatch*` functions are exhaustive over Thread kinds via ts-pattern.
// Each Thread kind ships its own ops module; this file wires them in.
//
// Phase B (current state): only `prim` and `ctor` ops are implemented.
// Other kinds throw a placeholder error that lists which method/kind
// hasn't landed yet — useful for spotting integration gaps as variants
// come online.

import type { Draft } from "immer";
import { match } from "ts-pattern";
import type { AskKind, ModMap } from "../../event.js";
import type { AskId, CallId } from "../../id.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import type { Thread } from "../types.js";
import { arrayOps } from "./array.js";
import { ctorOps } from "./ctor.js";
import { externalOps } from "./external.js";
import { forOps } from "./for.js";
import { matchOps } from "./match.js";
import { primOps } from "./prim.js";
import { requestOps } from "./request.js";
import { tupleOps } from "./tuple.js";
import { userOps } from "./user.js";
import type { ThreadOps } from "./types.js";

// ─── Per-method dispatch ───────────────────────────────────────────────────

export function dispatchCreate(ctx: StepCtx, t: Draft<Thread>): void {
  match(t)
    .with({ kind: "prim" }, x => primOps.create(ctx, x))
    .with({ kind: "ctor" }, x => ctorOps.create(ctx, x))
    .with({ kind: "tuple" }, x => tupleOps.create(ctx, x))
    .with({ kind: "array" }, x => arrayOps.create(ctx, x))
    .with({ kind: "match" }, x => matchOps.create(ctx, x))
    .with({ kind: "user" }, x => userOps.create(ctx, x))
    .with({ kind: "for" }, x => forOps.create(ctx, x))
    .with({ kind: "request" }, x => requestOps.create(ctx, x))
    .with({ kind: "external" }, x => externalOps.create(ctx, x))
    .otherwise(x => unimplemented("create", x.kind));
}

export function dispatchDone(
  ctx: StepCtx,
  t: Draft<Thread>,
  callId: CallId,
  value: Value,
): void {
  match(t)
    .with({ kind: "prim" }, x => primOps.done(ctx, x, callId, value))
    .with({ kind: "ctor" }, x => ctorOps.done(ctx, x, callId, value))
    .with({ kind: "tuple" }, x => tupleOps.done(ctx, x, callId, value))
    .with({ kind: "array" }, x => arrayOps.done(ctx, x, callId, value))
    .with({ kind: "match" }, x => matchOps.done(ctx, x, callId, value))
    .with({ kind: "user" }, x => userOps.done(ctx, x, callId, value))
    .with({ kind: "for" }, x => forOps.done(ctx, x, callId, value))
    .with({ kind: "request" }, x => requestOps.done(ctx, x, callId, value))
    .with({ kind: "external" }, x => externalOps.done(ctx, x, callId, value))
    .otherwise(x => unimplemented("done", x.kind));
}

export function dispatchCancel(ctx: StepCtx, t: Draft<Thread>): void {
  match(t)
    .with({ kind: "prim" }, x => primOps.cancel(ctx, x))
    .with({ kind: "ctor" }, x => ctorOps.cancel(ctx, x))
    .with({ kind: "tuple" }, x => tupleOps.cancel(ctx, x))
    .with({ kind: "array" }, x => arrayOps.cancel(ctx, x))
    .with({ kind: "match" }, x => matchOps.cancel(ctx, x))
    .with({ kind: "user" }, x => userOps.cancel(ctx, x))
    .with({ kind: "for" }, x => forOps.cancel(ctx, x))
    .with({ kind: "request" }, x => requestOps.cancel(ctx, x))
    .with({ kind: "external" }, x => externalOps.cancel(ctx, x))
    .otherwise(x => unimplemented("cancel", x.kind));
}

export function dispatchCancelAck(
  ctx: StepCtx,
  t: Draft<Thread>,
  callId: CallId,
): void {
  match(t)
    .with({ kind: "prim" }, x => primOps.cancelAck(ctx, x, callId))
    .with({ kind: "ctor" }, x => ctorOps.cancelAck(ctx, x, callId))
    .with({ kind: "tuple" }, x => tupleOps.cancelAck(ctx, x, callId))
    .with({ kind: "array" }, x => arrayOps.cancelAck(ctx, x, callId))
    .with({ kind: "match" }, x => matchOps.cancelAck(ctx, x, callId))
    .with({ kind: "user" }, x => userOps.cancelAck(ctx, x, callId))
    .with({ kind: "for" }, x => forOps.cancelAck(ctx, x, callId))
    .with({ kind: "request" }, x => requestOps.cancelAck(ctx, x, callId))
    .with({ kind: "external" }, x => externalOps.cancelAck(ctx, x, callId))
    .otherwise(x => unimplemented("cancelAck", x.kind));
}

export function dispatchAsk(
  ctx: StepCtx,
  t: Draft<Thread>,
  askId: AskId,
  kind: AskKind,
  payload: Value,
  mods: ModMap | undefined,
  childCallId: CallId,
): void {
  match(t)
    .with({ kind: "prim" }, x => primOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "ctor" }, x => ctorOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "tuple" }, x => tupleOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "array" }, x => arrayOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "match" }, x => matchOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "user" }, x => userOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "for" }, x => forOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "request" }, x => requestOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .with({ kind: "external" }, x => externalOps.ask(ctx, x, askId, kind, payload, mods, childCallId))
    .otherwise(x => unimplemented("ask", x.kind));
}

export function dispatchAskAck(
  ctx: StepCtx,
  t: Draft<Thread>,
  askId: AskId,
  value: Value,
): void {
  match(t)
    .with({ kind: "prim" }, x => primOps.askAck(ctx, x, askId, value))
    .with({ kind: "ctor" }, x => ctorOps.askAck(ctx, x, askId, value))
    .with({ kind: "tuple" }, x => tupleOps.askAck(ctx, x, askId, value))
    .with({ kind: "array" }, x => arrayOps.askAck(ctx, x, askId, value))
    .with({ kind: "match" }, x => matchOps.askAck(ctx, x, askId, value))
    .with({ kind: "user" }, x => userOps.askAck(ctx, x, askId, value))
    .with({ kind: "for" }, x => forOps.askAck(ctx, x, askId, value))
    .with({ kind: "request" }, x => requestOps.askAck(ctx, x, askId, value))
    .with({ kind: "external" }, x => externalOps.askAck(ctx, x, askId, value))
    .otherwise(x => unimplemented("askAck", x.kind));
}

// ─── Stub for unimplemented kinds ──────────────────────────────────────────

function unimplemented(method: keyof ThreadOps<Thread>, kind: Thread["kind"]): never {
  throw new Error(
    `engine: ${kind} thread has no ${method} implementation yet (Phase B in progress)`,
  );
}
