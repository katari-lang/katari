// ThreadOps: the per-variant method record. Each Thread kind exports a
// `ThreadOps<KindName>` value that fills in:
//
//   - create:   first dispatch after spawn — kick off the variant's body
//   - done:     a child completed normally
//   - cancel:   cancel was requested (default: cascade to children)
//   - cancelAck: a child finished cancellation (used for targeted cancels)
//   - ask:      an ask bubbled up — catch or proxy to parent
//   - askAck:   an askAck arrived — typically forward via askIdMap
//
// All ops mutate `ctx.state` (Immer draft). Outbound events / errors / logs
// go via `ctx.emit` / `ctx.recordError` / `ctx.log`. Internal events go via
// `ctx.enqueue`.

import type { AskKind } from "../../event.js";
import type { AskId, CallId } from "../../id.js";
import type { StepCtx } from "../../step-ctx.js";
import type { Value } from "../../value.js";
import type { Thread } from "../types.js";

export type ThreadOps<T extends Thread> = {
  /**
   * First dispatch after the thread is registered in state.threads.
   *
   * May be async: the prim variant awaits content-transform materialize.
   * Other variants stay synchronous (`void`), assignable to the union —
   * only the dispatcher / runner `await` the result.
   */
  create(ctx: StepCtx, t: T): void | Promise<void>;
  /** A direct child completed normally with `value`. */
  done(ctx: StepCtx, t: T, callId: CallId, value: Value): void;
  /**
   * cancel was requested. Default behaviour (in `defaultOps`) is the cascade
   * via `beginCancel`; variants override to send custom outbound events
   * first (e.g. DelegateThread emits a terminate to FFI before waiting).
   */
  cancel(ctx: StepCtx, t: T): void;
  /** A direct child cancellation completed (used for targeted cancel). */
  cancelAck(ctx: StepCtx, t: T, callId: CallId): void;
  /**
   * An ask bubbled up from `childCallId`. The variant decides whether to
   * catch (process locally + emit askAck or convert to done) or to proxy
   * to its own parent via `proxyAskToParent` from `common.ts`.
   *
   * Kind-specific data (value, args, mods, reqId) lives on `askKind`.
   */
  ask(ctx: StepCtx, t: T, askId: AskId, askKind: AskKind, childCallId: CallId): void;
  /**
   * An askAck addressed to this thread arrived. Typically forwarded via
   * `proxyAskAckToChild`; variants that originate asks (RequestThread)
   * intercept and convert to `done`.
   */
  askAck(ctx: StepCtx, t: T, askId: AskId, value: Value): void;
};
