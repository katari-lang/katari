import type { ArrayBlock } from "../../ir/types.js";
import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockArray (array construction).
 *
 * Sequential: evaluates element blocks one by one.
 * Parallel: evaluates all element blocks concurrently.
 *
 * Collects results in order → done({ kind: "array", elements }).
 */
export type ArrayThread = ThreadBase & {
  kind: "array";
  arrayBlock: ArrayBlock;
  phase:
    | { kind: "evaluating"; nextIndex: number }
    | { kind: "allDispatched" };
  /** Collected element values. null = not yet completed. */
  results: (Value | null)[];
};
