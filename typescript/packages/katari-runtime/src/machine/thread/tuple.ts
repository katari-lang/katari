import type { BlockId, TupleBlock } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  type CallId,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";

/**
 * Executes a BlockTuple (tuple construction).
 *
 * Sequential: evaluates element blocks one by one.
 * Parallel:   evaluates all element blocks concurrently.
 *
 * CallId = element index (0, 1, 2, ...).
 */
export class TupleThread extends ChildThread {
  readonly block: TupleBlock;
  private readonly collected: Map<CallId, Value> = new Map();
  private nextIndex: number = 0;

  constructor(init: ChildThreadInit, block: TupleBlock) {
    super(init);
    this.block = block;
  }

  override onCall(machine: MachineState): void {
    const elements = this.block.elements;
    if (elements.length === 0) {
      machine.queue.push({
        kind: "done",
        parent: this.parent,
        callId: this.parentCallId,
        value: { kind: "tuple", elements: [] },
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
        throw new Error(`TupleThread.emitDone: missing element ${i}`);
      }
      return v;
    });
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value: { kind: "tuple", elements: values },
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedTupleThread {
    return {
      kind: "tuple",
      ...this.serializeChildCommon(),
      block: this.block,
      collected: [...this.collected.entries()],
      nextIndex: this.nextIndex,
    };
  }

  static restoreSkeleton(serialized: SerializedTupleThread): TupleThread {
    const thread = Object.create(TupleThread.prototype) as TupleThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      block: TupleBlock;
      collected: Map<CallId, Value>;
      nextIndex: number;
    };
    writable.block = serialized.block;
    writable.collected = new Map(serialized.collected);
    writable.nextIndex = serialized.nextIndex;
    return thread;
  }

  link(
    serialized: SerializedTupleThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedTupleThread = SerializedChildThreadCommon & {
  kind: "tuple";
  block: TupleBlock;
  collected: [CallId, Value][];
  nextIndex: number;
};

function elementAt(elements: BlockId[], index: number): BlockId {
  const blockId = elements[index];
  if (blockId === undefined) {
    throw new Error(`TupleThread: element ${index} out of bounds`);
  }
  return blockId;
}
