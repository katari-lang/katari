// UserThread ops.
//
// Drives a BlockUser by running statements sequentially via `pc`. The
// thread's `catchesReturn` flag signals that this is an agent boundary
// (`block.kind === "blockKindAgent"`); it intercepts `return` asks instead
// of proxying them upward.
//
// `break` / `for_break` / `next` / `for_next` are likewise translated
// into bubbling asks — emitted from `statementExit` / `statementCont`
// straight into the parent chain.
//
// `request` calls are dispatched the usual way: a `RequestThread` is
// spawned, which itself emits a `request` ask up the chain.

import type { Draft } from "immer";
import type {
  Block,
  BlockId,
  CallData,
  Statement,
  UserBlock,
  VarId,
} from "../../../ir/types.js";
import type { AskId, CallId, ScopeId, ThreadId } from "../../id.js";
import type { AskKind, ModMap } from "../../event.js";
import { RecoverableEngineError } from "../../errors.js";
import { tryMatch } from "../../pattern.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import { literalToValue, NULL_VALUE, type Value } from "../../value.js";
import {
  allocAskId,
  commonRemoveChild,
  emitRootCompletion,
  hasChildren,
  lookupValue,
  setValueInScope,
} from "../common.js";
import type { UserThread } from "../types.js";
import {
  defaultAskAckProxy,
  defaultCancel,
  defaultCancelAckUnexpected,
} from "./defaults.js";
import { proxyAskToParent } from "../common.js";
import type { ThreadOps } from "./types.js";

export const userOps: ThreadOps<UserThread> = {
  create(ctx, t) {
    const block = getUserBlock(ctx, t.blockId);
    bindParameters(ctx, t.scopeId, block);
    runStatements(ctx, t as Draft<UserThread>, block);
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as Draft<UserThread>, callId)) return;
    const block = getUserBlock(ctx, t.blockId);
    // Carry the call's output VarId, if any.
    const stmt = block.statements[callId as number];
    if (stmt && stmt.kind === "statementCall" && stmt.body.output !== undefined) {
      setValueInScope(ctx, t.scopeId, stmt.body.output, value);
    }
    runStatements(ctx, t as Draft<UserThread>, block);
  },

  cancel: (ctx, t) => defaultCancel<UserThread>(ctx, t as Draft<UserThread>),
  cancelAck: defaultCancelAckUnexpected,

  ask(ctx, t, askId, kind, childCallId) {
    // Agent UserThreads catch `return`. Everything else bubbles up.
    if (kind.kind === "return" && t.catchesReturn) {
      handleReturnCaught(ctx, t as Draft<UserThread>, kind.value);
      // The `return` ask never gets askAck — it's a done-terminating ask.
      // We don't ack the immediate child; instead the caller (deep
      // descendant) will be cancelled as part of the cascade.
      return;
    }
    proxyAskToParent(
      ctx,
      t as Draft<UserThread>,
      childCallId,
      askId,
      kind,
    );
  },

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<UserThread>(ctx, t as Draft<UserThread>, askId, value),
};

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

function bindParameters(
  ctx: StepCtx,
  scopeId: ScopeId,
  block: UserBlock,
): void {
  // Parameters carry the args we were spawned with. The thread record
  // doesn't store args directly (parents pass them via spawnChild).
  // This is a bit awkward in the new design — the spawning op writes
  // args into our scope before the create event fires.
  // Currently spawnChild does NOT do that; we delegate to whoever spawned
  // us by reading `args` saved on the thread for variants that take args.
  // UserThread doesn't have an `args` field; we rely on the parameters
  // having been written into the scope via `setValueInScope` by the
  // caller. Future-proof: if needed, push the args into UserThread.
  void block;
  void scopeId;
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
    if (advance === "wait") return; // wait for child / ack — the handler
    // advanced pc itself if appropriate (e.g. statementCall).

    if (advance === "advance") {
      t.pc += 1;
    }
  }

  // All statements done — emit our trailing value as `done` to parent,
  // or as an external delegateAck if we are a root thread.
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
  // Root thread: emit external delegateAck and remove ourselves.
  emitRootCompletion(ctx, t, value);
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
      // Advance pc BEFORE spawning so that the eventual `done` event re-enters
      // runStatements with the next pc, not the call statement again
      // (which would re-spawn and infinite-loop).
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
      setValueInScope(ctx, t.scopeId, stmt.body.output, {
        kind: "closure",
        blockId: stmt.body.block,
        scopeId: t.scopeId,
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
        return "wait"; // freeze the thread; caller will see the error
      }
      for (const [varId, value] of Object.entries(bindings)) {
        setValueInScope(ctx, t.scopeId, Number(varId), value);
      }
      return "advance";
    }
    case "statementExit": {
      const value = lookupValue(ctx, t.scopeId, stmt.body.value);
      // If we ourselves are the boundary for this exit kind, handle it
      // directly without bubbling — the boundary mechanism reuses our
      // own `catchesReturn` flag for return; break/break-for ought to
      // be caught by some ancestor (the compiler enforces) so we just
      // bubble those.
      if (stmt.body.exitKind === "exitKindReturn" && t.catchesReturn) {
        handleReturnCaught(ctx, t, value);
        return "wait";
      }
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
  }
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
      // Args for the callee land in the *child's* scope after spawn —
      // for that we need to push them into the new scope. The current
      // spawnChild does not write args; UserThread's child sees its own
      // params via `block.parameters[i].var`. We write args into the
      // child scope by spawning first then writing — but we don't have
      // the child's scope yet at the spawnChild caller site. Solution:
      // spawn returns the new ThreadId, and we look up its scopeId.
      const childId = spawnChild(ctx, {
        parentId: t.id,
        parentCallId: callId,
        blockId: call.target.block as BlockId,
        callArgs: args,
        scopeMode,
      });
      // Write call args into the child's scope based on parameter labels.
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
      const calledBlock = ctx.state.irModule.blocks[String(value.blockId)] as Block | undefined;
      if (calledBlock === undefined) {
        throw new Error(`engine.user: block ${value.blockId} not found (closure call)`);
      }
      const childId = spawnChild(ctx, {
        parentId: t.id,
        parentCallId: callId,
        blockId: value.blockId as BlockId,
        callArgs: args,
        scopeMode: { mode: "captured", capturedScopeId: value.scopeId },
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

function handleReturnCaught(
  ctx: StepCtx,
  t: Draft<UserThread>,
  value: Value,
): void {
  // Convert the caught return into our pending done value, then cancel
  // children to drain. finishCancelling will emit done to our parent.
  if (t.status === "cancelling") return;
  t.status = "cancelling";
  t.pendingReturn = value;
  if (!hasChildren(t)) {
    // No children — emit our done now (or root delegateAck if root).
    if (t.parent !== null && t.parentCallId !== null) {
      ctx.enqueue({
        kind: "done",
        target: t.parent,
        callId: t.parentCallId,
        value,
      });
    } else {
      // Root thread: emit external delegateAck and remove ourselves.
      emitRootCompletion(ctx, t, value);
      delete ctx.state.threads[t.id];
    }
    return;
  }
  for (const childId of Object.values(t.children) as ThreadId[]) {
    ctx.enqueue({ kind: "cancel", target: childId });
  }
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
  if (calledBlock.kind !== "blockUser") return; // only user blocks have parameters
  const child = ctx.state.threads[childId];
  if (child === undefined) return;
  for (const param of calledBlock.body.parameters) {
    const v = args[param.label];
    if (v !== undefined) {
      setValueInScope(ctx, child.scopeId, param.var, v);
    }
  }
}

// askId/AskId import only used inside helpers above.
void (null as unknown as AskId);
