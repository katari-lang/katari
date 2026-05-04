import type { MatchBlock } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockMatch (pattern matching).
 *
 * Looks up the subject VarId in scope, tries each arm's pattern in order,
 * and spawns a child UserThread for the matching arm's body block.
 * Result = arm body's result.
 */
export type MatchThread = ThreadBase & {
  kind: "match";
  matchBlock: MatchBlock;
  phase:
    | { kind: "matching" }
    | { kind: "runningArm"; childThreadId: ThreadId };
};
