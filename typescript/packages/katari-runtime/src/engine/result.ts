// Result: the value returned by `applyEvent`. Carries the new State plus
// the side-effects that occurred while processing the event.
//
// `applyEvent` is conceptually `(State, Event) => Result`, with no
// in-place mutation. Each top-level Result represents the full transition
// of one inbound event including any internal queue draining.

import type { Diff } from "./diff.js";
import type { Event } from "./event.js";
import type { LogEntry } from "./logger.js";
import type { State } from "./state.js";

export type Result = {
  state: State;
  /** Events whose `to` is not the engine's selfEndpoint. Caller forwards. */
  outbound: Event[];
  /** Log entries captured during processing. */
  logs: LogEntry[];
  /** Domain diffs (translated from Immer patches) for incremental persist. */
  diffs: Diff[];
};

/** Build an initial empty Result around `state`. Useful for accumulators. */
export function emptyResult(state: State): Result {
  return {
    state,
    outbound: [],
    logs: [],
    diffs: [],
  };
}
