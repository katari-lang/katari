import type { BlockId, CallData, ExitKind, UserBlock } from "../../ir/types.js";
import type { ScopeId } from "../id.js";
import type { MachineState } from "../machine.js";
import { createScope, getValueFromScope, setValueInScope } from "../scope.js";
import { literalToValue, NULL_VALUE, type Value } from "../value.js";
import type { CallId, CreateThreadInit, ThreadBase } from "./types.js";

/**
 * Executes a BlockUser (agent or inline).
 * Processes statements sequentially via a program counter.
 *
 * CallId = pc value at the time the call was issued.
 */
export type UserThread = ThreadBase & {
  kind: "user";
  block: UserBlock;
  /** Index of the next statement to execute. */
  pc: number;
};

export function createUserThread(
  machine: MachineState,
  init: CreateThreadInit,
  block: UserBlock,
  args: Map<string, Value>,
): UserThread {
  // Agent blocks get fresh scope (parent = null for isolation), inline blocks use provided scopeId
  const scopeId =
    block.kind === "blockKindAgent"
      ? createScope(machine, null).id
      : init.scopeId;

  // Bind parameters into scope
  const scope = machine.scopes.get(scopeId)!;
  for (const param of block.parameters) {
    const argValue = args.get(param.label);
    if (argValue !== undefined) {
      scope.values.set(param.var, argValue);
    }
  }

  const thread: UserThread = {
    ...init,
    kind: "user",
    scopeId,
    children: new Map(),
    status: "running",
    block,
    pc: 0,
  };
  machine.threads.set(thread.id, thread);
  return thread;
}

export function onCallUser(machine: MachineState, thread: UserThread): void {
  runStatements(machine, thread);
}

export function onChildDoneUser(machine: MachineState, thread: UserThread, callId: CallId, value: Value): void {
  // callId = statement index (pc at call time)
  const stmt = thread.block.statements[callId];
  if (stmt.kind === "statementCall" && stmt.contents.output !== undefined) {
    setValueInScope(machine, thread.scopeId, stmt.contents.output, value);
  }
  runStatements(machine, thread);
}

/** Process statements from current pc until call or end. */
function runStatements(machine: MachineState, thread: UserThread): void {
  const { statements, trailing } = thread.block;

  while (thread.pc < statements.length) {
    const stmt = statements[thread.pc];

    switch (stmt.kind) {
      case "statementCall": {
        const callId = thread.pc;
        thread.pc++;
        const { blockId, scopeId } = resolveCallTarget(machine, thread.scopeId, stmt.contents);
        const args = resolveArgs(machine, thread.scopeId, stmt.contents);
        machine.queue.push({
          kind: "call",
          parent: thread,
          callId,
          blockId,
          args,
          scopeId,
        });
        return; // wait for child completion
      }

      case "statementLoadLiteral": {
        const { output, value } = stmt.contents;
        setValueInScope(machine, thread.scopeId, output, literalToValue(value));
        thread.pc++;
        continue;
      }

      case "statementMakeClosure": {
        const { output, block } = stmt.contents;
        setValueInScope(machine, thread.scopeId, output, {
          kind: "closure",
          blockId: block,
          scopeId: thread.scopeId,
        });
        thread.pc++;
        continue;
      }

      case "statementBindPattern":
        throw new Error("runStatements: statementBindPattern not implemented");

      case "statementExit": {
        const exitValue = getValueFromScope(machine, thread.scopeId, stmt.contents.value);
        const exitKind = stmt.contents.exitKind;
        if (isBoundaryForUser(thread, exitKind)) {
          // This thread IS the boundary — emit done directly
          machine.queue.push({
            kind: "done",
            parent: thread.parent!,
            callId: thread.parentCallId!,
            value: exitValue,
          });
        } else {
          // Propagate return upward
          machine.queue.push({
            kind: "return",
            parent: thread.parent!,
            callId: thread.parentCallId!,
            value: exitValue,
            exitKind,
          });
        }
        return; // Thread stays alive, will be cancelled by parent
      }

      case "statementCont":
        throw new Error("runStatements: statementCont not implemented");
    }
  }

  // All statements executed — return trailing value
  const value = trailing !== undefined
    ? getValueFromScope(machine, thread.scopeId, trailing)
    : NULL_VALUE;
  machine.queue.push({
    kind: "done",
    parent: thread.parent!,
    callId: thread.parentCallId!,
    value,
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function isBoundaryForUser(thread: UserThread, exitKind: ExitKind): boolean {
  return exitKind === "exitKindReturn" && thread.block.kind === "blockKindAgent";
}

function resolveCallTarget(
  machine: MachineState,
  scopeId: ScopeId,
  call: CallData,
): { blockId: BlockId; scopeId: ScopeId } {
  const target = call.target;
  switch (target.kind) {
    case "callTargetBlock":
      return { blockId: target.block, scopeId };
    case "callTargetValue": {
      const value = getValueFromScope(machine, scopeId, target.var);
      if (value.kind !== "closure") {
        throw new Error(`resolveCallTarget: expected closure, got ${value.kind}`);
      }
      return { blockId: value.blockId, scopeId: value.scopeId };
    }
  }
}

function resolveArgs(machine: MachineState, scopeId: ScopeId, call: CallData): Map<string, Value> {
  const args = new Map<string, Value>();
  for (const arg of call.arguments) {
    const value = getValueFromScope(machine, scopeId, arg.var);
    args.set(arg.label, value);
  }
  return args;
}
