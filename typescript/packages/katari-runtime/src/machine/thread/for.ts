import type { ForBlock, VarId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockFor (for-loop).
 *
 * Sequential: creates one body thread per iteration element, advancing on completion.
 * Parallel: creates all body threads at once.
 *
 * Handles for_break (early exit), for_next (state update + advance),
 * and optional then-block on normal completion.
 */
export type ForThread = ThreadBase & {
  kind: "for";
  forBlock: ForBlock;
  phase:
    | { kind: "iterating"; currentIndex: number }
    | { kind: "allDispatched" }
    | { kind: "runningThen"; childThreadId: ThreadId }
    | { kind: "broken"; value: Value };
  /** Current version of each state variable (incremented on for_next). */
  stateVersions: Map<VarId, number>;
};
