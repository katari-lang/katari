// UserThread ops — pure statement-execution unit.
//
// Drives a BlockUser by running statements sequentially via `pc`. The
// thread does NOT catch any asks — `return` / `break` / `break-for` /
// `next` / `next-for` / `request` all bubble up through `proxyAskToParent`.
// Boundary catches live on AgentThread (return) / HandleThread (break,
// next) / ForThread (break-for, next-for) instead.
//
// `request` calls are dispatched the usual way: a `RequestThread` is
// spawned, which itself emits a `request` ask up the chain.
//
// Cross-agent dispatch lives here too:
//   - `statementAgentCall`        → outbound core→core `delegate` event
//                                   targeting a top-level qualified name
//   - `statementAgentCallClosure` → outbound core→core `delegate` event
//                                   carrying the captured agent's body
//                                   blockId resolved from the closure
//
// The runner picks the outbound `delegate` up via `translateExternal` on
// the next iteration and spawns a fresh AgentThread. A local
// ExternalThread is registered as the receiver of the eventual
// `delegateAck`, which becomes a `done` to this UserThread.

import type { Draft } from "immer";
import type {
  Block,
  BlockId,
  CallData,
  Statement,
  UserBlock,
  VarId,
} from "../../../ir/types.js";
import type { CallId, ScopeId, ThreadId } from "../../id.js";
import type { AskKind, ModMap } from "../../event.js";
import { RecoverableEngineError } from "../../errors.js";
import { tryMatch } from "../../pattern.js";
import { spawnChild, spawnExternalForAgentDelegate } from "../../spawn.js";
import { createDelegationId } from "../../id.js";
import type { StepCtx } from "../../step-ctx.js";
import { literalToValue, NULL_VALUE, type Value } from "../../value.js";
import {
  allocAskId,
  commonRemoveChild,
  lookupValue,
  setValueInScope,
} from "../common.js";
import type { UserThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultAskProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import type { ThreadOps } from "./types.js";

export const userOps: ThreadOps<UserThread> = {
  create(ctx, t) {
    const block = getUserBlock(ctx, t.blockId);
    runStatements(ctx, t as Draft<UserThread>, block);
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as Draft<UserThread>, callId)) return;
    const block = getUserBlock(ctx, t.blockId);
    // Carry the call's output VarId, if any.
    const stmt = block.statements[callId as number];
    if (stmt !== undefined) {
      const output = outputVarOf(stmt);
      if (output !== undefined) {
        setValueInScope(ctx, t.scopeId, output, value);
      }
    }
    runStatements(ctx, t as Draft<UserThread>, block);
  },

  cancel: (ctx, t) => defaultCancel<UserThread>(ctx, t as Draft<UserThread>),
  cancelAck: defaultCancelAckUnexpected,

  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<UserThread>(ctx, t as Draft<UserThread>, askId, kind, childCallId),

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<UserThread>(ctx, t as Draft<UserThread>, askId, value),
};

function outputVarOf(stmt: Statement): VarId | undefined {
  switch (stmt.kind) {
    case "statementCall":
    case "statementAgentCall":
    case "statementAgentCallClosure":
      return stmt.body.output;
    default:
      return undefined;
  }
}

// ─── helpers ───────────────────────────────────────────────────────────────

function getUserBlock(ctx: StepCtx, blockId: BlockId): UserBlock {
  const b = ctx.state.irModule.blocks[String(blockId)] as Block | undefined;
  if (b === undefined) {
    throw new Error(`engine.user: block ${blockId} not found`);
  }
  if (b.kind !== "blockUser") {
    throw new Error(`engine.user: block ${blockId} is not a user block (${b.kind})`);
  }
  return b.body;
}

function runStatements(
  ctx: StepCtx,
  t: Draft<UserThread>,
  block: UserBlock,
): void {
  const statements = block.statements;

  while (t.pc < statements.length) {
    const stmt = statements[t.pc];
    if (stmt === undefined) {
      throw new Error(`engine.user: no statement at pc ${t.pc}`);
    }

    const advance = handleStatement(ctx, t, stmt);
    if (advance === "wait") return;

    if (advance === "advance") {
      t.pc += 1;
    }
  }

  // All statements done — emit our trailing value as `done` to parent.
  // UserThreads are never roots in the new design (AgentThread always
  // wraps); if parent is null, the test scaffolding spawned us directly
  // and we just disappear.
  const value = block.trailing !== undefined
    ? lookupValue(ctx, t.scopeId, block.trailing)
    : NULL_VALUE;
  if (t.parent !== null && t.parentCallId !== null) {
    ctx.enqueue({
      kind: "done",
      target: t.parent,
      callId: t.parentCallId,
      value,
    });
    return;
  }
  ctx.log("debug", "engine.user: parentless UserThread completed", {
    threadId: t.id,
  });
  delete ctx.state.threads[t.id];
}

type StatementOutcome = "advance" | "wait";

function handleStatement(
  ctx: StepCtx,
  t: Draft<UserThread>,
  stmt: Statement,
): StatementOutcome {
  switch (stmt.kind) {
    case "statementCall": {
      const callId = t.pc as CallId;
      t.pc += 1;
      pushCallEvent(ctx, t, callId, stmt.body);
      return "wait";
    }
    case "statementLoadLiteral": {
      setValueInScope(ctx, t.scopeId, stmt.body.output, literalToValue(stmt.body.value));
      return "advance";
    }
    case "statementMakeClosure": {
      const closureId = (ctx.state.nextClosureId as number) as import("../../id.js").ClosureId;
      ctx.state.nextClosureId = (ctx.state.nextClosureId as number) + 1;
      ctx.state.closures[closureId as unknown as number] = {
        id: closureId,
        blockId: stmt.body.block,
        scopeId: t.scopeId,
      };
      setValueInScope(ctx, t.scopeId, stmt.body.output, {
        kind: "closure",
        closureId,
      });
      return "advance";
    }
    case "statementBindPattern": {
      const incoming = lookupValue(ctx, t.scopeId, stmt.body.source);
      const bindings = tryMatch(stmt.body.pattern, incoming);
      if (bindings === null) {
        ctx.recordError(
          new RecoverableEngineError(
            "statementBindPattern: refutable pattern reached runtime (compiler bug)",
          ),
        );
        return "wait";
      }
      for (const [varId, value] of Object.entries(bindings)) {
        setValueInScope(ctx, t.scopeId, Number(varId), value);
      }
      return "advance";
    }
    case "statementExit": {
      const value = lookupValue(ctx, t.scopeId, stmt.body.value);
      const askKind = exitKindToAsk(stmt.body.exitKind, value);
      emitAskUpwards(ctx, t, askKind);
      return "wait";
    }
    case "statementCont": {
      const value = stmt.body.value !== undefined
        ? lookupValue(ctx, t.scopeId, stmt.body.value)
        : NULL_VALUE;
      const mods = resolveModifiers(ctx, t.scopeId, stmt.body.modifiers);
      const askKind = contKindToAsk(stmt.body.contKind, value, mods);
      emitAskUpwards(ctx, t, askKind);
      return "wait";
    }
    case "statementAgentCall": {
      const callId = t.pc as CallId;
      t.pc += 1;
      const args: Record<string, Value> = {};
      for (const a of stmt.body.arguments) {
        args[a.label] = lookupValue(ctx, t.scopeId, a.var);
      }
      pushAgentDelegate(ctx, t, callId, args, {
        module_: stmt.body.target.module_,
        name: stmt.body.target.name,
      });
      return "wait";
    }
    case "statementAgentCallClosure": {
      const callId = t.pc as CallId;
      t.pc += 1;
      const closureValue = lookupValue(ctx, t.scopeId, stmt.body.target);
      if (closureValue.kind !== "closure") {
        ctx.recordError(
          new RecoverableEngineError(
            `engine.user: statementAgentCallClosure expected closure, got ${closureValue.kind}`,
          ),
        );
        return "wait";
      }
      const closure = ctx.state.closures[closureValue.closureId as unknown as number];
      if (closure === undefined) {
        throw new Error(
          `engine.user: closure ${closureValue.closureId} not found`,
        );
      }
      const args: Record<string, Value> = {};
      for (const a of stmt.body.arguments) {
        args[a.label] = lookupValue(ctx, t.scopeId, a.var);
      }
      // Closure-based dispatch: encode the underlying blockId as a
      // synthetic qualified name (`<closure>.<blockId>`); the runner's
      // `resolveDelegateTarget` decodes it.
      pushAgentDelegate(ctx, t, callId, args, {
        module_: "<closure>",
        name: String(closure.blockId as unknown as number),
      });
      return "wait";
    }
  }
}

/**
 * Issue a core→core agent delegate. Spawns a phantom ExternalThread as a
 * child of `t` at `parentCallId = callId`, registers it under
 * `state.pendingDelegateOut[delegationId]`, and emits the outbound
 * `delegate` event from=to=self. The runner's `translateExternal` picks
 * the event up on the next iteration, spawns a fresh AgentThread root,
 * and registers it under `state.delegations[delegationId]` /
 * `state.delegationSenders[delegationId] = self`.
 *
 * When the AgentThread completes, `emitAgentRootCompletion` emits a
 * `delegateAck` outbound to `delegationSenders` (= self). On the next
 * iteration `translateExternal` finds the phantom in
 * `pendingDelegateOut`, fires `done` to its parent (this UserThread),
 * and the inherited `done` handler binds the value to the call's output
 * VarId.
 */
function pushAgentDelegate(
  ctx: StepCtx,
  t: Draft<UserThread>,
  callId: CallId,
  args: Record<string, Value>,
  target: { module_: string; name: string },
): void {
  const delegationId = createDelegationId();
  spawnExternalForAgentDelegate(ctx, {
    parentId: t.id,
    parentCallId: callId,
    delegationId,
    args,
  });
  ctx.emit({
    from: ctx.state.selfEndpoint,
    to: ctx.state.selfEndpoint,
    payload: {
      kind: "delegate",
      targetBlock: target,
      args,
      delegationId,
    },
  });
}

function pushCallEvent(
  ctx: StepCtx,
  t: Draft<UserThread>,
  callId: CallId,
  call: CallData,
): void {
  const args = resolveArgs(ctx, t.scopeId, call);
  switch (call.target.kind) {
    case "callTargetBlock": {
      const block = ctx.state.irModule.blocks[String(call.target.block)] as Block | undefined;
      if (block === undefined) {
        throw new Error(`engine.user: block ${call.target.block} not found`);
      }
      const scopeMode = isStructuralBlock(block.kind)
        ? { mode: "inline" as const, parentScopeId: t.scopeId }
        : { mode: "isolated" as const };
      const childId = spawnChild(ctx, {
        parentId: t.id,
        parentCallId: callId,
        blockId: call.target.block as BlockId,
        callArgs: args,
        scopeMode,
      });
      writeArgsIntoChildScope(ctx, childId, block, args);
      return;
    }
    case "callTargetValue": {
      const value = lookupValue(ctx, t.scopeId, call.target.var);
      if (value.kind !== "closure") {
        ctx.recordError(
          new RecoverableEngineError(
            `engine.user: callTargetValue expected closure, got ${value.kind}`,
          ),
        );
        return;
      }
      const closure = ctx.state.closures[value.closureId as unknown as number];
      if (closure === undefined) {
        throw new Error(`engine.user: closure ${value.closureId} not found`);
      }
      const calledBlock = ctx.state.irModule.blocks[String(closure.blockId)] as Block | undefined;
      if (calledBlock === undefined) {
        throw new Error(`engine.user: block ${closure.blockId} not found (closure call)`);
      }
      const childId = spawnChild(ctx, {
        parentId: t.id,
        parentCallId: callId,
        blockId: closure.blockId as BlockId,
        callArgs: args,
        scopeMode: { mode: "captured", capturedScopeId: closure.scopeId },
      });
      writeArgsIntoChildScope(ctx, childId, calledBlock, args);
      return;
    }
  }
}

function isStructuralBlock(kind: Block["kind"]): boolean {
  switch (kind) {
    case "blockHandle":
    case "blockFor":
    case "blockMatch":
    case "blockTuple":
    case "blockArray":
      return true;
    default:
      return false;
  }
}

function resolveArgs(
  ctx: StepCtx,
  scopeId: ScopeId,
  call: CallData,
): Record<string, Value> {
  const out: Record<string, Value> = {};
  for (const arg of call.arguments) {
    out[arg.label] = lookupValue(ctx, scopeId, arg.var);
  }
  return out;
}

function resolveModifiers(
  ctx: StepCtx,
  scopeId: ScopeId,
  mods: [VarId, VarId][],
): ModMap {
  const out: ModMap = {};
  for (const [target, source] of mods) {
    out[target] = lookupValue(ctx, scopeId, source);
  }
  return out;
}

function exitKindToAsk(
  kind: import("../../../ir/types.js").ExitKind,
  value: Value,
): AskKind {
  switch (kind) {
    case "exitKindReturn":
      return { kind: "return", value };
    case "exitKindBreak":
      return { kind: "break", value };
    case "exitKindForBreak":
      return { kind: "break-for", value };
  }
}

function contKindToAsk(
  kind: import("../../../ir/types.js").ContKind,
  value: Value,
  mods: ModMap,
): AskKind {
  switch (kind) {
    case "contKindNext":
      return { kind: "next", value, mods };
    case "contKindForNext":
      return { kind: "next-for", value, mods };
  }
}

function emitAskUpwards(
  ctx: StepCtx,
  t: Draft<UserThread>,
  askKind: AskKind,
): void {
  if (t.parent === null) {
    ctx.recordError(
      new RecoverableEngineError(
        `engine.user: ask "${askKind.kind}" issued from a parentless thread`,
      ),
    );
    return;
  }
  const askId = allocAskId(t);
  ctx.enqueue({
    kind: "ask",
    target: t.parent,
    askId,
    askKind,
    childCallId: t.parentCallId!,
  });
}

/**
 * The caller (this UserThread) just spawned a child via spawnChild;
 * the child's scope is a fresh empty scope. Walk the called block's
 * parameter list and copy the call args into the child's scope under
 * each parameter's VarId.
 */
function writeArgsIntoChildScope(
  ctx: StepCtx,
  childId: ThreadId,
  calledBlock: Block,
  args: Record<string, Value>,
): void {
  if (calledBlock.kind !== "blockUser") return;
  const child = ctx.state.threads[childId];
  if (child === undefined) return;
  for (const param of calledBlock.body.parameters) {
    const v = args[param.label];
    if (v !== undefined) {
      setValueInScope(ctx, child.scopeId, param.var, v);
    }
  }
}
