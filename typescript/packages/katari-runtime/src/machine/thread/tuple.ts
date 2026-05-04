import type { TupleBlock } from "../../ir/types.js";
import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockTuple (tuple construction).
 *
 * Sequential: evaluates element blocks one by one.
 * Parallel: evaluates all element blocks concurrently.
 *
 * Collects results in order → done({ kind: "tuple", elements }).
 */
export type TupleThread = ThreadBase & {
  kind: "tuple";
  tupleBlock: TupleBlock;
  phase:
    | { kind: "evaluating"; nextIndex: number }
    | { kind: "allDispatched" };
  /** Collected element values. null = not yet completed. */
  results: (Value | null)[];
};
