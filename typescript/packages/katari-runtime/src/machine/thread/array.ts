import type { ArrayBlock, BlockId, IRModule } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  resolveBlockPayload,
  type CallId,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockArray (array construction).
 *
 * Sequential: evaluates element blocks one by one.
 * Parallel:   evaluates all element blocks concurrently.
 *
 * CallId = element index (0, 1, 2, ...).
 */
export class ArrayThread extends ChildThread {
  readonly block: ArrayBlock;
  /** IR id of the BlockArray backing this thread. See UserThread.blockId. */
  readonly blockId: BlockId;
  /** Collected results from children. */
  private readonly collected: Map<CallId, Value> = new Map();
  /** Sequential mode: next element index to dispatch. */
  private nextIndex: number = 0;

  constructor(init: ChildThreadInit, block: ArrayBlock, blockId: BlockId) {
    super(init);
    this.block = block;
    this.blockId = blockId;
  }

  override onCall(machine: MachineState): void {
    const elements = this.block.elements;
    if (elements.length === 0) {
      machine.queue.push({
        kind: "done",
        parent: this.parent,
        callId: this.parentCallId,
        value: { kind: "array", elements: [] },
      });
      return;
    }

    if (this.block.parallel) {
      for (let i = 0; i < elements.length; i++) {
        this.pushElementCall(machine, i, elementAt(elements, i));
      }
    } else {
      this.pushElementCall(machine, 0, elementAt(elements, 0));
    }
  }

  protected override onChildDone(machine: MachineState, callId: CallId, value: Value): void {
    this.collected.set(callId, value);
    const elements = this.block.elements;

    if (this.block.parallel) {
      if (this.collected.size >= elements.length) {
        this.emitDone(machine, elements);
      }
      return;
    }

    this.nextIndex++;
    if (this.nextIndex >= elements.length) {
      this.emitDone(machine, elements);
      return;
    }
    this.pushElementCall(machine, this.nextIndex, elementAt(elements, this.nextIndex));
  }

  private pushElementCall(machine: MachineState, index: number, blockId: BlockId): void {
    machine.queue.push({
      kind: "callInline",
      parent: this,
      callId: index,
      blockId,
      args: {},
      scopeId: this.scopeId,
    });
  }

  private emitDone(machine: MachineState, elements: BlockId[]): void {
    const values = elements.map((_, i) => {
      const v = this.collected.get(i);
      if (v === undefined) {
        throw new Error(`ArrayThread.emitDone: missing element ${i}`);
      }
      return v;
    });
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value: { kind: "array", elements: values },
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedArrayThread {
    return {
      kind: "array",
      ...this.serializeChildCommon(),
      blockId: this.blockId,
      collected: [...this.collected.entries()],
      nextIndex: this.nextIndex,
    };
  }

  static restoreSkeleton(
    serialized: SerializedArrayThread,
    irModule: IRModule,
  ): ArrayThread {
    const thread = Object.create(ArrayThread.prototype) as ArrayThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      block: ArrayBlock;
      blockId: BlockId;
      collected: Map<CallId, Value>;
      nextIndex: number;
    };
    const block = resolveBlockPayload(irModule, serialized.blockId, "blockArray");
    writable.block = block.arrayBlock;
    writable.blockId = serialized.blockId;
    writable.collected = new Map(serialized.collected);
    writable.nextIndex = serialized.nextIndex;
    return thread;
  }

  link(
    serialized: SerializedArrayThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedArrayThread = SerializedChildThreadCommon & {
  kind: "array";
  blockId: BlockId;
  collected: [CallId, Value][];
  nextIndex: number;
};

function elementAt(elements: BlockId[], index: number): BlockId {
  const blockId = elements[index];
  if (blockId === undefined) {
    throw new Error(`ArrayThread: element ${index} out of bounds`);
  }
  return blockId;
}
