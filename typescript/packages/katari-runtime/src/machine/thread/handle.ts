import type { HandleBlock } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import type { CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Executes a BlockHandle (effect handler scope).
 * Placeholder — not implemented.
 */
export type HandleThread = ThreadBase & {
  kind: "handle";
  block: HandleBlock;
};

export function createHandleThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: HandleBlock,
): HandleThread {
  const thread: HandleThread = {
    ...init,
    kind: "handle",
    scopeId: init.scopeId,
    children: new Map(),
    status: "running",
    block,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}
