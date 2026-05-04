import type { ReqId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { Value } from "../value.js";
import type { ThreadBase } from "./types.js";

/**
 * Executes a BlockRequest (handler lookup + dispatch).
 *
 * Searches inheritedHandlers for the matching reqId, creates a handler body
 * thread as a child, and relays the handler's result (done/next/break) to parent.
 *
 * Future: if no handler is found, escalation to external agent.
 */
export type RequestThread = ThreadBase & {
  kind: "request";
  reqId: ReqId;
  /** Labeled arguments resolved at call site. */
  arguments: Map<string, Value>;
  phase:
    | { kind: "dispatching" }
    | { kind: "awaitingHandler"; handlerThreadId: ThreadId };
};
