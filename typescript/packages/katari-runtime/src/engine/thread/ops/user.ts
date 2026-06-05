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

import type { Block, BlockId, CallData, Statement, UserBlock, VarId } from "../../../ir/types.js";
import type { AskKind, ModMap } from "../../event.js";
import type { CallId, ScopeId } from "../../id.js";
import { tryMatch } from "../../pattern.js";
import { spawnChild, spawnMakeClosure } from "../../spawn.js";
import type { StepCtx } from "../../step-ctx.js";
import { literalToValue, NULL_VALUE, type Value } from "../../value.js";
import {
  allocAskId,
  commonRemoveChild,
  emitThrowEscalate,
  lookupValue,
  setValueInScope,
  writeArgsIntoChildScope,
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
    case "statementMakeClosure":
      // The MakeClosureThread `done`s the closure ref into this var.
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

function runStatements(ctx: StepCtx, t: UserThread, block: UserBlock): void {
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
  const value =
    block.trailing !== undefined ? lookupValue(ctx, t.scopeId, block.trailing) : NULL_VALUE;
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
  ctx.state.threadCount--;
}

type StatementOutcome = "advance" | "wait";

function handleStatement(ctx: StepCtx, t: UserThread, stmt: Statement): StatementOutcome {
  switch (stmt.kind) {
    case "statementCall": {
      const callId = t.pc as CallId;
      t.pc += 1;
      pushCallEvent(ctx, t, callId, stmt.body);
      return "wait";
    }
    case "statementLoadLiteral": {
      // An agent literal is born in the shard's snapshot — stamp it so the
      // value carries its external (`qname@snapshot`) form.
      setValueInScope(
        ctx,
        t.scopeId,
        stmt.body.output,
        literalToValue(stmt.body.value, ctx.state.snapshot),
      );
      return "advance";
    }
    case "statementMakeClosure": {
      // A closure literal. Spawn a MakeClosureThread (like a call): its async
      // `create` freezes the captured scope into a content blob via ctx.putBlob
      // and `done`s us with the resulting `{ kind: "closure", ref }`. The output
      // var is the closure's self-reference var (recursive local agent). We wait.
      const callId = t.pc as CallId;
      t.pc += 1;
      spawnMakeClosure(ctx, {
        parentId: t.id,
        parentCallId: callId,
        blockId: stmt.body.block as BlockId,
        capturedScopeId: t.scopeId,
        selfVar: stmt.body.output,
      });
      return "wait";
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
      const value =
        stmt.body.value !== undefined ? lookupValue(ctx, t.scopeId, stmt.body.value) : NULL_VALUE;
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

function pushCallEvent(ctx: StepCtx, t: UserThread, callId: CallId, call: CallData): void {
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
  writeArgsIntoChildScope(ctx, childId, call.block as BlockId, args);
}

function isStructuralBlock(kind: Block["kind"]): boolean {
  // A child spawned by a StatementCall inherits the caller's scope (inline)
  // unless it is an agent boundary. Every block a user thread can call
  // directly computes a value in-thread and references the caller's locals —
  // match / for / handle arms and conditions, tuple / record entries, and a
  // BlockDelegate's callee VarId all need the caller scope. Only `blockAgent`
  // cuts scope (the agent isolates its own), so it alone runs isolated.
  //
  // Defaulting to structural (rather than enumerating the structural kinds)
  // is deliberate: the old enumeration silently omitted `blockRecord`, which
  // was a latent scope bug. Any new value-computing block kind is correct by
  // default here; only a genuine new boundary needs to be added below.
  return kind !== "blockAgent";
}

function resolveArgs(ctx: StepCtx, scopeId: ScopeId, call: CallData): Record<string, Value> {
  // The unified calling convention passes a single argument value. For a named
  // call the caller built it as a record (a `blockRecord`); we destructure its
  // entries back into the label-keyed args the callee binds by. An
  // argument-less call (`call.argument` absent) passes no args.
  if (call.argument === undefined) return {};
  const value = lookupValue(ctx, scopeId, call.argument);
  return value.kind === "record" ? { ...value.entries } : {};
}

function resolveModifiers(ctx: StepCtx, scopeId: ScopeId, mods: [VarId, VarId][]): ModMap {
  const out: ModMap = {};
  for (const [target, source] of mods) {
    out[target] = lookupValue(ctx, scopeId, source);
  }
  return out;
}

function exitKindToAsk(kind: import("../../../ir/types.js").ExitKind, value: Value): AskKind {
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

function emitAskUpwards(ctx: StepCtx, t: UserThread, askKind: AskKind): void {
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
