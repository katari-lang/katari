// What counts as a *user-facing* escalation — one a user can answer. Shared by the actor's recovery
// rehydration (`reactivate`) and the API's open-escalation list (`escalation.repository`), so both agree:
// the engine and the durable Layer 1 read present the same set.

import { PANIC_REQUEST } from "./engine/common.js";

/** The `AskKind`s that are control-flow escapes (not capability requests) — an escalation carrying one of
 *  these is an unwind crossing an instance boundary, not something a user answers. */
const CONTROL_ESCAPE_KINDS = new Set(["next", "next-for", "return", "break", "break-for"]);

/** Whether an escalation's `request` names a genuine user-answerable capability — i.e. it is not a panic
 *  and not a control-flow escape (both fail the run rather than wait for an answer). The `request` column
 *  stores a request ask's qualified name, or a control ask's bare `kind`; capability names are qualified,
 *  so they never collide with the bare control keywords. */
export function isUserFacingRequest(request: string): boolean {
  return request !== PANIC_REQUEST && !CONTROL_ESCAPE_KINDS.has(request);
}
