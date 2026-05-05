import type { ReqId } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import type { ChildThreadBase, CreateThreadInit } from "./types.js";

/**
 * Executes a BlockRequest (handler lookup + dispatch).
 * Placeholder — not implemented.
 */
export type RequestThread = ChildThreadBase & {
  kind: "request";
  reqId: ReqId;
  args: Map<string, Value>;
};

export function createRequestThread(
  machine: MachineState,
  init: CreateThreadInit,
  reqId: ReqId,
  args: Map<string, Value>,
): RequestThread {
  const thread: RequestThread = {
    ...init,
    kind: "request",
    children: new Map(),
    status: "running",
    reqId,
    args,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}
