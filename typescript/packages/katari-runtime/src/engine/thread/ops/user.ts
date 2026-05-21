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
// Cross-agent dispatch uses the standard `statementCall` path targeting
// a `BlockDelegate`; the runtime spawns a `DelegateThread` that emits
// the outbound `delegate` event and waits for `delegateAck`. UserThread
// itself stays uniform — no special agent-call statement variant.

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
import { tryMatch } from "../../pattern.js";
import { spawnChild } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import { literalToValue, NULL_VALUE, type Value } from "../../value.js";
import {
  allocAskId,
  commonRemoveChild,
  emitThrowEscalate,
  lookupValue,
  setValueInScope,
} from "../common.js";
import type { Thread, UserThread } from "../types.js";
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
    runStatements(ctx, t as UserThread, block);
  },

  done(ctx, t, callId, value) {
    if (!commonRemoveChild(ctx, t as UserThread, callId)) return;
    const block = getUserBlock(ctx, t.blockId);
    // Carry the call's output VarId, if any.
    const stmt = block.statements[callId];
    if (stmt !== undefined) {
      const output = outputVarOf(stmt);
      if (output !== undefined) {
        setValueInScope(ctx, t.scopeId, output, value);
      }
    }
    runStatements(ctx, t as UserThread, block);
  },

  cancel: (ctx, t) => defaultCancel<UserThread>(ctx, t as UserThread),
  cancelAck: defaultCancelAckUnexpected,

  ask: (ctx, t, askId, kind, childCallId) =>
    defaultAskProxy<UserThread>(ctx, t as UserThread, askId, kind, childCallId),

  askAck: (ctx, t, askId, value) =>
    defaultAskAckProxy<UserThread>(ctx, t as UserThread, askId, value),
};

function outputVarOf(stmt: Statement): VarId | undefined {
  switch (stmt.kind) {
    case "statementCall":
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
  t: UserThread,
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
  t: UserThread,
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
      // Guard against integer overflow near MAX_SAFE_INTEGER. A snapshot
      // that ran long enough to allocate 2^53 closures would start
      // colliding on closure id, silently misrouting dispatches. Surface
      // it as a hard engine error instead.
      const nextId = ctx.state.nextClosureId as number;
      if (nextId >= Number.MAX_SAFE_INTEGER) {
        throw new Error(
          "engine: nextClosureId exceeded MAX_SAFE_INTEGER; persistent state has run out of closure ids",
        );
      }
      const closureId = nextId as import("../../id.js").ClosureId;
      ctx.state.nextClosureId = nextId + 1;
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
        emitThrowEscalate(ctx, t as Thread, "match: pattern did not match");
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
    default: {
      // Defensive: a deserialized IR may carry a kind we removed (e.g. an
      // old `statementAgentCall`). Without an explicit throw the
      // `runStatements` loop would never advance and we'd spin forever.
      const k = (stmt as { kind: string }).kind;
      throw new Error(`engine.user: unknown statement kind '${k}' at pc=${t.pc}`);
    }
  }
}

function pushCallEvent(
  ctx: StepCtx,
  t: UserThread,
  callId: CallId,
  call: CallData,
): void {
  const args = resolveArgs(ctx, t.scopeId, call);
  const block = ctx.state.irModule.blocks[String(call.block)] as Block | undefined;
  if (block === undefined) {
    throw new Error(`engine.user: block ${call.block} not found`);
  }
  const scopeMode = isStructuralBlock(block.kind)
    ? { mode: "inline" as const, parentScopeId: t.scopeId }
    : { mode: "isolated" as const };
  const childId = spawnChild(ctx, {
    parentId: t.id,
    parentCallId: callId,
    blockId: call.block as BlockId,
    callArgs: args,
    scopeMode,
  });
  writeArgsIntoChildScope(ctx, childId, block, args);
}

function isStructuralBlock(kind: Block["kind"]): boolean {
  switch (kind) {
    case "blockHandle":
    case "blockFor":
    case "blockMatch":
    case "blockTuple":
    case "blockArray":
      return true;
    case "blockDelegate":
      // BlockDelegate may reference a runtime value at a VarId in the
      // caller's scope (DelegateTargetValue); inherit so the lookup
      // resolves. For static targets the inheritance is harmless.
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
  t: UserThread,
  askKind: AskKind,
): void {
  if (t.parent === null) {
    ctx.log("warn", "engine.user: ask issued from a parentless UserThread; ignoring", {
      threadId: t.id,
      askKind: askKind.kind,
    });
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
