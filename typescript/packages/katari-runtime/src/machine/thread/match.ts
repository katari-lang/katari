import type { BlockId, LiteralValue, MatchBlock, MatchPattern, VarId } from "../../ir/types.js";
import type { MachineState } from "../machine.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import type { Value } from "../value.js";
import type { CallId, ChildThreadBase, CreateThreadInit } from "./types.js";

/**
 * Executes a BlockMatch (pattern matching).
 *
 * onCall: evaluates subject, finds matching arm, dispatches arm body as child.
 * onChildDone: propagates arm result as own result.
 * CallId = 0 (only one child: the matched arm body).
 */
export type MatchThread = ChildThreadBase & {
  kind: "match";
  matchBlock: MatchBlock;
};

export function createMatchThread(
  machine: MachineState,
  init: CreateThreadInit,
  matchBlock: MatchBlock,
): MatchThread {
  const thread: MatchThread = {
    ...init,
    kind: "match",
    children: new Map(),
    status: "running",
    matchBlock,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallMatch(machine: MachineState, thread: MatchThread): void {
  const subject = getValueFromScope(machine, thread.scopeId, thread.matchBlock.subject);
  const arms = thread.matchBlock.arms;

  for (const arm of arms) {
    const bindings = tryMatch(arm.pattern, subject);
    if (bindings !== null) {
      for (const [varId, value] of bindings) {
        setValueInScope(machine, thread.scopeId, varId, value);
      }
      pushArmCall(machine, thread, arm.body);
      return;
    }
  }

  // Default arm
  if (thread.matchBlock.defaultArm !== undefined) {
    pushArmCall(machine, thread, thread.matchBlock.defaultArm);
    return;
  }

  throw new Error("MatchThread: no arm matched and no default");
}

export function onChildDoneMatch(machine: MachineState, thread: MatchThread, _callId: CallId, value: Value): void {
  machine.queue.push({
    kind: "done",
    parent: thread.parent,
    callId: thread.parentCallId,
    value,
  });
}

function pushArmCall(machine: MachineState, thread: MatchThread, blockId: BlockId): void {
  machine.queue.push({
    kind: "callInline",
    parent: thread,
    callId: 0,
    blockId,
    args: new Map(),
    scopeId: thread.scopeId,
  });
}

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
