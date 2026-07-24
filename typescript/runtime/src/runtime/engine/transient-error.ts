// The retryable-infra-failure signal, the sibling of `KatariThrow` (throw-signal.ts) on the prim / engine
// side: where a `KatariThrow` is an anticipated DOMAIN failure (catchable) and every other prim error is a
// deterministic panic (a bug), a `TransientError` is neither — it marks a TRANSIENT infrastructure failure (a
// DB read blip, a network timeout) that a retry can clear. Any host I/O a react turn performs (the IR DB read
// in `db-ir-source`, the env store read behind `env.get_secret`) wraps its infra failures as this, so the
// substrate's react-turn loop can tell "retry from durable state" apart from "a deterministic bug — drop the
// event". This module is import-leaf (like `throw-signal.ts`) so both the engine leaves that PRODUCE the
// failure and the actor layer that CLASSIFIES it share the marker without a cycle.

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

/** Run a react-turn host I/O read, re-raising any infra failure as a `TransientError` so the substrate's
 *  commit-retry policy (not its drop-the-event bug policy) handles it. The ONE wrap seam both the IR DB read
 *  and the env store read go through, so "infra failure ⇒ retryable" is expressed once, not per call site. */
export async function asTransient<T>(what: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (error) {
    throw new TransientError(`${what} failed`, { cause: error });
  }
}
