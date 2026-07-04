// Failure classification for the substrate's turn loop. A turn's `react` phase mutates only warm state, so
// the substrate must tell apart two kinds of throw out of it:
//
//  - a TRANSIENT infrastructure failure (a DB read blip, a network timeout) — the same class of failure a
//    `commit` can hit — which is retryable: drop + reload + replay the event from the durable outbox; and
//  - a DETERMINISTIC program error — a bug, since a deterministic failure is supposed to surface as a panic,
//    not a throw — which must NOT replay-loop (the event is consumed and dropped).
//
// Without this, a transient DB read during a (post-recovery) resume turn would be misread as a bug and the
// event silently dropped, hanging the run. Code that does I/O inside a react turn (the IR DB read) wraps its
// infra failures as `TransientError`; everything else that throws is treated as a deterministic bug.

/** A transient infrastructure failure raised from within a react turn — retryable like a commit failure. */
export class TransientError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "TransientError";
  }
}

export function isTransientError(error: unknown): error is TransientError {
  return error instanceof TransientError;
}

/** The human message of an unknown thrown value (an `Error`'s message, else its string form). */
export function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
