import type { HandleBlock } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import type { ChildThreadBase, CreateThreadInit } from "./types.js";

/**
 * Executes a BlockHandle (effect handler scope).
 * Placeholder — not implemented.
 */
export type HandleThread = ChildThreadBase & {
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
    children: new Map(),
    status: "running",
    block,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}
