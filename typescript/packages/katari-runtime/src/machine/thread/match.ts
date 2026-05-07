import type { BlockId, IRModule, MatchBlock } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { tryMatch } from "../pattern.js";
import { RecoverableEngineError } from "../../runtime/errors.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
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
 * Executes a BlockMatch (pattern matching).
 *
 * onCall: evaluates subject, finds matching arm, dispatches arm body as child.
 * onChildDone: propagates arm result as own result.
 * CallId = 0 (only one child: the matched arm body).
 */
export class MatchThread extends ChildThread {
  readonly matchBlock: MatchBlock;
  /** IR id of the BlockMatch backing this thread. See UserThread.blockId. */
  readonly blockId: BlockId;

  constructor(init: ChildThreadInit, matchBlock: MatchBlock, blockId: BlockId) {
    super(init);
    this.matchBlock = matchBlock;
    this.blockId = blockId;
  }

  override onCall(machine: MachineState): void {
    const subject = getValueFromScope(machine, this.scopeId, this.matchBlock.subject);

    for (const arm of this.matchBlock.arms) {
      const bindings = tryMatch(arm.pattern, subject);
      if (bindings !== null) {
        for (const [varId, value] of bindings) {
          setValueInScope(machine, this.scopeId, varId, value);
        }
        this.pushArmCall(machine, arm.body);
        return;
      }
    }

    if (this.matchBlock.defaultArm !== undefined) {
      this.pushArmCall(machine, this.matchBlock.defaultArm);
      return;
    }

    // No arm matched the subject and there's no default. The compiler's
    // exhaustiveness checker should have rejected this earlier; reaching
    // here means either a user-supplied IR is malformed or a value of
    // unexpected shape leaked across the API boundary. Either way it's a
    // single-agent problem, so we surface a Recoverable error.
    throw new RecoverableEngineError(
      "MatchThread: no arm matched and no default",
    );
  }

  protected override onChildDone(machine: MachineState, _callId: CallId, value: Value): void {
    machine.queue.push({
      kind: "done",
      parent: this.parent,
      callId: this.parentCallId,
      value,
    });
  }

  private pushArmCall(machine: MachineState, blockId: BlockId): void {
    machine.queue.push({
      kind: "callInline",
      parent: this,
      callId: 0,
      blockId,
      args: {},
      scopeId: this.scopeId,
    });
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedMatchThread {
    return {
      kind: "match",
      ...this.serializeChildCommon(),
      blockId: this.blockId,
    };
  }

  static restoreSkeleton(
    serialized: SerializedMatchThread,
    irModule: IRModule,
  ): MatchThread {
    const thread = Object.create(MatchThread.prototype) as MatchThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      matchBlock: MatchBlock;
      blockId: BlockId;
    };
    const block = resolveBlockPayload(irModule, serialized.blockId, "blockMatch");
    writable.matchBlock = block.matchBlock;
    writable.blockId = serialized.blockId;
    return thread;
  }

  link(
    serialized: SerializedMatchThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
  }
}

export type SerializedMatchThread = SerializedChildThreadCommon & {
  kind: "match";
  blockId: BlockId;
};

// Pattern matching helpers live in `../pattern.ts` and are imported above.
// MatchThread uses `tryMatch` directly; the previous local copies (and the
// `matchLiteral` helper) were extracted so that UserThread's
// `statementBindPattern` case can share the exact same matching semantics.
