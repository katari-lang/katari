import type { CallData, UserBlock } from "../../ir/types.js";
import type { ScopeId } from "../id.js";
import type { MachineState } from "../machine.js";
import { getScope, getValueFromScope, setValueInScope } from "../scope.js";
import { literalToValue, NULL_VALUE, type Value } from "../value.js";
import type { CallId, ChildThreadBase, CreateThreadInit } from "./types.js";

/**
 * Executes a BlockUser (agent or inline).
 * Processes statements sequentially via a program counter.
 *
 * CallId = pc value at the time the call was issued.
 */
export type UserThread = ChildThreadBase & {
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
  // Bind parameters into the freshly-allocated scope (allocated by the runner).
  const scope = getScope(machine, init.scopeId);
  for (const param of block.parameters) {
    const argValue = args.get(param.label);
    if (argValue !== undefined) {
      scope.values.set(param.var, argValue);
    }
  }

  const thread: UserThread = {
    ...init,
    kind: "user",
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
  if (stmt === undefined) {
    throw new Error(`onChildDoneUser: no statement at callId ${callId}`);
  }
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
    if (stmt === undefined) {
      throw new Error(`runStatements: no statement at pc ${thread.pc}`);
    }

    switch (stmt.kind) {
      case "statementCall": {
        const callId = thread.pc;
        thread.pc++;
        const args = resolveArgs(machine, thread.scopeId, stmt.contents);
        pushCallEvent(machine, thread, callId, stmt.contents, args);
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
        // Direct delivery to the registered boundary. The boundary cancels
        // its remaining children and emits done with `exitValue`. Bypasses
        // any intermediate `then` blocks.
        const target = thread.boundaries[exitKind];
        if (target === null) {
          throw new Error(
            `statementExit: no boundary registered for ${exitKind}`,
          );
        }
        machine.queue.push({
          kind: "return",
          target,
          value: exitValue,
          exitKind,
        });
        return; // Thread stays alive; will be cancelled by the boundary's cascade.
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
    parent: thread.parent,
    callId: thread.parentCallId,
    value,
  });
}

/**
 * Dispatch a statementCall to the appropriate call queue variant.
 * - callTargetBlock → callBlock (top-level callable; new isolated scope)
 * - callTargetValue → callValue (closure; new scope under captured scope)
 */
function pushCallEvent(
  machine: MachineState,
  thread: UserThread,
  callId: CallId,
  call: CallData,
  args: Map<string, Value>,
): void {
  switch (call.target.kind) {
    case "callTargetBlock":
      machine.queue.push({
        kind: "callBlock",
        parent: thread,
        callId,
        blockId: call.target.block,
        args,
      });
      return;
    case "callTargetValue": {
      const value = getValueFromScope(machine, thread.scopeId, call.target.var);
      if (value.kind !== "closure") {
        throw new Error(`pushCallEvent: expected closure, got ${value.kind}`);
      }
      machine.queue.push({
        kind: "callValue",
        parent: thread,
        callId,
        blockId: value.blockId,
        args,
        capturedScopeId: value.scopeId,
      });
      return;
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
