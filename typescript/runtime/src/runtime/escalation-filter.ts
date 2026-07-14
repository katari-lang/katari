// What counts as a *user-facing* escalation — one a user can answer. Every escalation is durable and uniform
// (the base opens a row for every escalate — a failure, a control escape, a user-facing request — without
// classifying); this predicate is where the classification lives, applied at the READS that need it: the api
// reactor's answerable set (its live load + the durable `answerableEscalations`), the API's open-escalation
// list (`escalation.repository`), and the run-tree's `answerable` mark. So the engine and every durable read
// present the same answerable set, and a failure row never surfaces as answerable.

import { PANIC_REQUEST } from "./engine/common.js";
import { THROW_REQUEST } from "./engine/throw-signal.js";

/** The `AskKind`s that are control-flow escapes (not capability requests) — an escalation carrying one of
 *  these is an unwind crossing an instance boundary, not something a user answers. */
const CONTROL_ESCAPE_KINDS = new Set(["next", "next-for", "return", "break", "break-for"]);

/** `prelude.replay.interrupted` — the replay seam a converter performs to hand control to a `replay`
 *  provider. Like `throw` / `panic` it is a `-> never` control channel (its answer type is `never`, so no
 *  valid answer exists): with a provider in scope the provider catches it, but with NONE in scope it must
 *  FAIL the run, not open an un-answerable escalation at the run root. So it belongs to the failure set. */
export const REPLAY_INTERRUPTED_REQUEST = "prelude.replay.interrupted";

/** Whether an escalation's `request` is a *failure* channel — a panic (a deterministic defect, uncatchable),
 *  a `prelude.throw` (a typed anticipated error), or a `prelude.replay.interrupted` (the replay seam, also
 *  `-> never`). All fail rather than wait for an answer (their answer type is `never`, so no valid answer
 *  exists): reaching the run root, they fail the run rather than open an answerable escalation. Named once
 *  here so every site that distinguishes "a failure" from "an answerable request" reads the same set —
 *  adding a failure channel updates one place. */
export function isFailureRequest(request: string): boolean {
  return (
    request === PANIC_REQUEST || request === THROW_REQUEST || request === REPLAY_INTERRUPTED_REQUEST
  );
}

/** Whether an escalation's `request` names a genuine user-answerable capability — i.e. it is not a failure
 *  channel (panic / throw) and not a control-flow escape. The `request` column stores a request ask's
 *  qualified name, or a control ask's bare `kind`; capability names are qualified, so they never collide
 *  with the bare control keywords. */
export function isUserFacingRequest(request: string): boolean {
  return !isFailureRequest(request) && !CONTROL_ESCAPE_KINDS.has(request);
}
