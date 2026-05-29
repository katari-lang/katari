// Thread spawning: allocate a new Thread record for a given Block, register
// it in state.threads + parent.children, and enqueue its `create` event.
//
// This is the engine's only Block-kind switch outside of pattern matching
// itself. Variant-specific fields are filled in here so the variant ops
// can rely on a complete record from their first `create` invocation.

import { match } from "ts-pattern";
import type { Block, BlockId } from "../ir/types.js";
import {
  type CallId,
  createDelegationId,
  createScopeId,
  createThreadId,
  type DelegationId,
  type ScopeId,
  type ThreadId,
} from "./id.js";
import type { StepCtx } from "./step-ctx.js";
import { newCommonFields, setChild } from "./thread/common.js";
import type { Thread } from "./thread/types.js";
import { inlineText, type Value } from "./value.js";

/**
 * Decide where the freshly-allocated child scope's parentId should point.
 *
 * - "isolated": no parent (top-level callable; agent boundaries).
 * - "inline":   parent is the caller's current scope (structural blocks).
 * - "captured": parent is the closure's captured scope (closure call).
 */
export type SpawnScopeMode =
  | { mode: "isolated" }
  | { mode: "inline"; parentScopeId: ScopeId }
  | { mode: "captured"; capturedScopeId: ScopeId };

export type SpawnArgs = {
  parentId: ThreadId;
  parentCallId: CallId;
  blockId: BlockId;
  callArgs: Record<string, Value>;
  scopeMode: SpawnScopeMode;
};

/**
 * Spawn a child of `parentId` and queue its `create` event. Returns the
 * new ThreadId. Caller must be inside an Immer step; this function
 * mutates `ctx.state` directly via the draft.
 */
export function spawnChild(ctx: StepCtx, args: SpawnArgs): ThreadId {
  const blockKey = String(args.blockId);
  const block = ctx.state.irModule.blocks[blockKey] as Block | undefined;
  if (block === undefined) {
    throw new Error(`engine.spawnChild: blockId ${args.blockId} not found in IR`);
  }

  const parent = ctx.state.threads[args.parentId] as Thread | undefined;
  if (parent === undefined) {
    throw new Error(`engine.spawnChild: parent ${args.parentId} not found`);
  }

  // Allocate the child scope. `isolated` → null parent, `inline` →
  // caller's scope, `captured` → captured scope.
  const newScopeId = createScopeId();
  const parentScopeId = match(args.scopeMode)
    .with({ mode: "isolated" }, () => null as ScopeId | null)
    .with({ mode: "inline" }, (m) => m.parentScopeId)
    .with({ mode: "captured" }, (m) => m.capturedScopeId)
    .exhaustive();
  ctx.state.scopes[newScopeId] = {
    id: newScopeId,
    parentId: parentScopeId,
    values: {},
  };
  ctx.state.scopeCount++;

  const newThreadId = createThreadId();
  const common = newCommonFields({
    id: newThreadId,
    parent: args.parentId,
    parentCallId: args.parentCallId,
    scopeId: newScopeId,
  });

  const thread: Thread = match(block)
    .with({ kind: "blockUser" }, () => ({
      ...common,
      kind: "user" as const,
      blockId: args.blockId,
      pc: 0,
    }))
    .with({ kind: "blockPrim" }, (b) => {
      // `call_agent` needs to spawn a delegation against a runtime-
      // resolved target plus run schema validation, which is well
      // outside the synchronous-leaf shape PrimThread assumes. Pivot
      // into a dedicated CallAgentThread for this one well-known name.
      if (b.body === "call_agent") {
        const nameArg = args.callArgs["name"];
        const argsArg = args.callArgs["args"];
        return {
          ...common,
          kind: "callAgent" as const,
          nameStr: nameArg !== undefined && nameArg.kind === "string" ? inlineText(nameArg) : "",
          argsRecord: argsArg !== undefined && argsArg.kind === "record" ? argsArg.entries : {},
          inboundEscalations: {},
        };
      }
      return {
        ...common,
        kind: "prim" as const,
        primName: b.body,
        args: args.callArgs,
      };
    })
    .with({ kind: "blockConstructor" }, (b) => ({
      ...common,
      kind: "ctor" as const,
      ctorId: b.body,
      args: args.callArgs,
    }))
    .with({ kind: "blockDelegate" }, () => ({
      ...common,
      kind: "delegate" as const,
      blockId: args.blockId,
      args: args.callArgs,
      delegationId: createDelegationId(),
      inboundEscalations: {},
    }))
    .with({ kind: "blockMatch" }, () => ({
      ...common,
      kind: "match" as const,
      blockId: args.blockId,
    }))
    .with({ kind: "blockFor" }, () => ({
      ...common,
      kind: "for" as const,
      blockId: args.blockId,
      currentIndex: 0,
      iterableSnapshot: [],
      postCancelActions: {},
      thenCallId: null,
    }))
    .with({ kind: "blockHandle" }, () => ({
      ...common,
      kind: "handle" as const,
      blockId: args.blockId,
      childRoles: {},
      pendingActions: [],
      postCancelActions: {},
    }))
    .with({ kind: "blockTuple" }, () => ({
      ...common,
      kind: "tuple" as const,
      blockId: args.blockId,
      collected: {},
      nextIndex: 0,
    }))
    .with({ kind: "blockArray" }, () => ({
      ...common,
      kind: "array" as const,
      blockId: args.blockId,
      collected: {},
      nextIndex: 0,
    }))
    .with({ kind: "blockRecord" }, () => ({
      ...common,
      kind: "record" as const,
      blockId: args.blockId,
      collected: {},
      nextIndex: 0,
    }))
    .with({ kind: "blockRequest" }, (b) => ({
      ...common,
      kind: "request" as const,
      reqId: b.body,
      args: args.callArgs,
    }))
    .with({ kind: "blockAgent" }, () => {
      // Should not be reached: callers reach a BlockAgent only via
      // delegate events (= spawnAgentRoot on the receiver side), never
      // by direct StatementCall. Reaching here means Lowering emitted a
      // bare call to a BlockAgent without an intervening BlockDelegate.
      throw new Error(
        `engine.spawnChild: blockId ${args.blockId} targets a blockAgent — call sites must go through a BlockDelegate`,
      );
    })
    .exhaustive();

  ctx.state.threads[newThreadId] = thread as Thread;
  ctx.state.threadCount++;
  setChild(parent, args.parentCallId, newThreadId);

  ctx.enqueue({ kind: "create", threadId: newThreadId });

  return newThreadId;
}

// ─── AgentThread + DelegateThread (delegation boundary) ───────────────────

export type SpawnAgentRootArgs = {
  blockId: BlockId;
  args: Record<string, Value>;
  delegationId: DelegationId;
  /**
   * Optional parent scope. When set, the new agent's scope inherits from
   * it — used for closure-based dispatch so the body can see captured
   * locals. Top-level qualifiedName dispatch leaves it null and the agent
   * runs in a fresh isolated scope.
   */
  capturedScopeId?: import("./id.js").ScopeId | null;
};

/**
 * Spawn a fresh root AgentThread for an inbound `delegate` event. Args are
 * bound into the agent's body scope by the AgentThread's own `create` op
 * (which spawns the body UserThread). Returns the new ThreadId so the
 * caller can register it under `state.delegations`.
 */
export function spawnAgentRoot(ctx: StepCtx, args: SpawnAgentRootArgs): ThreadId {
  const block = ctx.state.irModule.blocks[String(args.blockId)] as Block | undefined;
  if (block === undefined || block.kind !== "blockAgent") {
    throw new Error(
      `engine.spawnAgentRoot: blockId ${args.blockId} is not a blockAgent (${block?.kind})`,
    );
  }

  const newScopeId = createScopeId();
  ctx.state.scopes[newScopeId] = {
    id: newScopeId,
    parentId: args.capturedScopeId ?? null,
    values: {},
  };
  ctx.state.scopeCount++;

  const newThreadId = createThreadId();
  const common = newCommonFields({
    id: newThreadId,
    parent: null,
    parentCallId: null,
    scopeId: newScopeId,
  });
  const agent: Thread = {
    ...common,
    kind: "agent",
    blockId: args.blockId,
    args: { ...args.args },
    delegationId: args.delegationId,
    outboundEscalations: {},
  };
  ctx.state.threads[newThreadId] = agent as Thread;
  ctx.state.threadCount++;
  ctx.enqueue({ kind: "create", threadId: newThreadId });
  return newThreadId;
}
