// Failure classification for the substrate's turn loop. A turn's `react` phase mutates only warm state, so
// the substrate must tell apart two kinds of throw out of it:
//
//  - a TRANSIENT infrastructure failure (a DB read blip, a network timeout) — the same class of failure a
//    `commit` can hit — which is retryable: drop + reload + replay the event from the durable outbox; and
//  - a DETERMINISTIC program error — a bug, since a deterministic failure is supposed to surface as a panic,
//    not a throw — which must NOT replay-loop (the event is consumed and dropped).
//
// Without this, a transient DB read during a (post-recovery) resume turn would be misread as a bug and the
// event silently dropped, hanging the run. Code that does I/O inside a react turn — the IR DB read
// (`db-ir-source`) AND the env store read behind a prim (`env.get_secret`) — wraps its infra failures as
// `TransientError`; everything else that throws is treated as a deterministic bug. The marker itself lives in
// the engine leaf (`engine/transient-error.ts`) so the prim path that PRODUCES it and this actor layer that
// CLASSIFIES it can share it without an engine→actor cycle; it is re-exported here for the actor's callers.

export { asTransient, isTransientError, TransientError } from "../engine/transient-error.js";

/** The human message of an unknown thrown value (an `Error`'s message, else its string form). */
export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
