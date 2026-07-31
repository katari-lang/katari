// What counts as a *user-facing* escalation — one a user can answer. Every escalation is durable and uniform
// (the base opens a row for every escalate — a failure, a control escape, a user-facing request — without
// classifying); this predicate is where the classification lives, applied at the READS that need it: the api
// reactor's answerable set (its live load + the durable `answerableEscalations`), the API's open-escalation
// list (`escalation.repository`), and the run-tree's `answerable` mark. So the engine and every durable read
// present the same answerable set, and a failure row never surfaces as answerable.

import { isExclusiveRequest, isStoreRequest } from "./actor/store-responder.js";
import { PANIC_REQUEST } from "./engine/common.js";
import { THROW_REQUEST } from "./engine/throw-signal.js";

/** The `AskKind`s that are control-flow escapes (not capability requests) — an escalation carrying one of
 *  these is an unwind crossing an instance boundary, not something a user answers. */
const CONTROL_ESCAPE_KINDS = new Set(["next", "next-for", "return", "break", "break-for"]);

/** `prelude.supervise.interrupted` — the supervision seam a converter performs to hand control to a
 *  `supervise` provider. Like `throw` / `panic` it is a `-> never` control channel (its answer type is
 *  `never`, so no valid answer exists): with a provider in scope the provider catches it, but with NONE in
 *  scope it must FAIL the run, not open an un-answerable escalation at the run root. So it belongs to the
 *  failure set. */
export const SUPERVISE_INTERRUPTED_REQUEST = "prelude.supervise.interrupted";

/** Whether an escalation's `request` is a *failure* channel — a panic (a deterministic defect, uncatchable),
 *  a `prelude.throw` (a typed anticipated error), or a `prelude.supervise.interrupted` (the supervision seam, also
 *  `-> never`). All fail rather than wait for an answer (their answer type is `never`, so no valid answer
 *  exists): reaching the run root, they fail the run rather than open an answerable escalation. Named once
 *  here so every site that distinguishes "a failure" from "an answerable request" reads the same set —
 *  adding a failure channel updates one place.
 *
 *  WHY A NAME LIST AND NOT THE GENERAL RULE. The general rule is structural: a request whose DECLARED
 *  result is `never` has no valid answer, so it can only be a failure channel — and the runtime could read
 *  that off the snapshot instead of naming the two stdlib requests that satisfy it. That generalisation is
 *  deliberately NOT taken: it buys nothing today (the stdlib declares exactly these two `-> never`
 *  requests) and it would make every user-declared `-> never` request silently un-answerable, which is a
 *  language decision, not a runtime one. The cost of a name list is drift — a third stdlib `-> never`
 *  request would quietly become an un-answerable escalation parked at the run root — so the list is held
 *  to the stdlib by a trip-wire (`test/never-requests.test.ts`), which fails on any new `-> never`
 *  declaration and forces the choice: add it here, or intend it to be user-facing. */
export function isFailureRequest(request: string): boolean {
  return (
    request === PANIC_REQUEST ||
    request === THROW_REQUEST ||
    request === SUPERVISE_INTERRUPTED_REQUEST
  );
}

/** Whether an escalation's `request` names a genuine user-answerable capability — i.e. it is not a failure
 *  channel (panic / throw), not a control-flow escape, and not a RUNTIME-SERVED request (a `prelude.store.*`
 *  KV operation the runtime answers against the durable rows, or `store.exclusive` the runtime serves as the
 *  root serial domain — neither an operator question). The `request` column stores a request ask's qualified
 *  name, or a control ask's bare `kind`; capability names are qualified, so they never collide with the bare
 *  control keywords. So a store escalation is kept out of every user-facing read — the api reactor's
 *  answerable set, `katari ls escalations`, the run-tree's answerable mark — while the api reactor still
 *  recognises and serves it (`isStoreRequest` / `isExclusiveRequest`). */
export function isUserFacingRequest(request: string): boolean {
  return (
    !isFailureRequest(request) &&
    !CONTROL_ESCAPE_KINDS.has(request) &&
    !isStoreRequest(request) &&
    !isExclusiveRequest(request)
  );
}
