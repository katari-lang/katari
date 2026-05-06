import type { BlockId, LiteralValue, MatchBlock, MatchPattern, VarId } from "../../ir/types.js";
import type { ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import type { Value } from "../value.js";
import {
  ChildThread,
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

  constructor(init: ChildThreadInit, matchBlock: MatchBlock) {
    super(init);
    this.matchBlock = matchBlock;
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

    throw new Error("MatchThread: no arm matched and no default");
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
      matchBlock: this.matchBlock,
    };
  }

  static restoreSkeleton(serialized: SerializedMatchThread): MatchThread {
    const thread = Object.create(MatchThread.prototype) as MatchThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as { matchBlock: MatchBlock };
    writable.matchBlock = serialized.matchBlock;
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
  matchBlock: MatchBlock;
};

// ─── Pattern matching ─────────────────────────────────────────────────────────

/**
 * Try to match a value against a pattern.
 * Returns variable bindings on success, null on failure.
 */
function tryMatch(pattern: MatchPattern, value: Value): Map<VarId, Value> | null {
  switch (pattern.kind) {
    case "matchPatternAny":
      return new Map();

    case "matchPatternVariable":
      return new Map([[pattern.contents, value]]);

    case "matchPatternLiteral":
      return matchLiteral(pattern.contents, value) ? new Map() : null;

    case "matchPatternConstructor": {
      const [ctorId, fieldPatterns] = pattern.contents;
      if (value.kind !== "tagged" || value.ctorId !== ctorId) return null;
      const bindings = new Map<VarId, Value>();
      for (const [fieldName, fieldPattern] of fieldPatterns) {
        const fieldValue = value.fields[fieldName];
        if (fieldValue === undefined) return null;
        const subBindings = tryMatch(fieldPattern, fieldValue);
        if (subBindings === null) return null;
        for (const [k, v] of subBindings) bindings.set(k, v);
      }
      return bindings;
    }

    case "matchPatternTuple": {
      if (value.kind !== "tuple") return null;
      if (value.elements.length !== pattern.contents.length) return null;
      const bindings = new Map<VarId, Value>();
      for (let i = 0; i < pattern.contents.length; i++) {
        const subPattern = pattern.contents[i];
        const subValue = value.elements[i];
        if (subPattern === undefined || subValue === undefined) return null;
        const subBindings = tryMatch(subPattern, subValue);
        if (subBindings === null) return null;
        for (const [k, v] of subBindings) bindings.set(k, v);
      }
      return bindings;
    }
  }
}

function matchLiteral(literal: LiteralValue, value: Value): boolean {
  switch (literal.kind) {
    case "literalValueInteger":
      return value.kind === "number" && value.value === literal.integer;
    case "literalValueNumber":
      return value.kind === "number" && value.value === literal.number;
    case "literalValueString":
      return value.kind === "string" && value.value === literal.string;
    case "literalValueBoolean":
      return value.kind === "boolean" && value.value === literal.boolean;
    case "literalValueNull":
      return value.kind === "null";
  }
}
