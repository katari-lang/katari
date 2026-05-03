import { BlockId } from "../ir/types.js";
import { allocateMemoryCell, createScope } from "./memory.js";
import { ScopeId, ThreadId } from "./types/id.js";
import { MachineState } from "./types/state.js";
import { ThreadOrigin, Thread } from "./types/thread.js";
import { Value } from "./types/value.js";

export function createThread(
  machineState: MachineState,
  blockId: BlockId,
  arguments: Map<string, Value>,
  parentScopeId: ScopeId | null,
  parentThreadId: ThreadId | null,
  origin: ThreadOrigin,
): Value {
  const threadId = crypto.randomUUID() as ThreadId;
  const scope = createScope(machineState, parentScopeId);
  const parentThread = parentThreadId
    ? getThread(machineState, parentThreadId)
    : null;
  const parentHandlers = parentThread ? parentThread.parentHandlers : new Map();
  const thread: Thread = {
    id: threadId,
    blockId,
    arguments,
    scopeId: scope.id,
    parentThreadId,
    origin,
    childThreads: new Set(),
    parentHandlers,
    ownHandlers: new Map(),
    status: "running",
    varVersions: new Map(),
    waiters: new Map(),
  };
  if (parentThread) {
    parentThread.childThreads.add({
      childThreadId: threadId,
      childOrigin: origin,
    });
  }
  machineState.threads.set(threadId, thread);

  const block = machineState.irModule.blocks[blockId];
  // block による分岐
  if (block.kind === "blockUser") {
    // 引数がある場合はスコープにセット
    for (const { label, var: varId } of block.body.parameters) {
      const value = arguments.get(label);
      if (!value) {
        throw new Error(`Missing argument for parameter: ${label}`);
      }
      const [memoryKey, memoryCell] = allocateMemoryCell(
        machineState,
        scope.id,
        varId,
      );
      if (memoryKey.version !== 0) {
        throw new Error(
          `Expected initial version 0 for variable ${varId}, got ${memoryKey.version}`,
        );
      }
      scope.memoryCells.set(memoryKeyToString(memoryKey), memoryCell);
    }
  }

  // return result (filled or wait)
  return thread;
}

export function getThread(
  machineState: MachineState,
  threadId: ThreadId,
): Thread {
  const thread = machineState.threads.get(threadId);
  if (!thread) {
    throw new Error(`Thread not found for id: ${threadId}`);
  }
  return thread;
}
