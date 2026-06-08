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
  createThreadId,
  type DelegationId,
  type ScopeId,
  type ThreadId,
} from "./id.js";
import type { StepCtx } from "./step-ctx.js";
import { allocScope } from "./store.js";
import { newCommonFields, setChild } from "./thread/common.js";
import type { Thread } from "./thread/types.js";
import { NULL_VALUE, type Value } from "./value.js";

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
  /** The single argument value passed to the child (the unified convention). */
  argument: Value | undefined;
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

  // Allocate the child scope in the CORE-global store, owned by this shard's
  // entity. `isolated` → null parent, `inline` → caller's scope, `captured` →
  // captured scope.
  const parentScopeId = match(args.scopeMode)
    .with({ mode: "isolated" }, () => null as ScopeId | null)
    .with({ mode: "inline" }, (m) => m.parentScopeId)
    .with({ mode: "captured" }, (m) => m.capturedScopeId)
    .exhaustive();
  const newScopeId = allocScope(ctx.store, parentScopeId, ctx.state.selfEntity);

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
      if (b.body === "primitive.call_agent") {
        const argRec = args.argument?.kind === "record" ? args.argument.entries : {};
        const targetArg = argRec["target"];
        const argsArg = argRec["args"];
        return {
          ...common,
          kind: "callAgent" as const,
          target: targetArg ?? NULL_VALUE,
          argsRecord: argsArg !== undefined && argsArg.kind === "record" ? argsArg.entries : {},
          inboundEscalations: {},
        };
      }
      return {
        ...common,
        kind: "prim" as const,
        primName: b.body,
        argument: args.argument,
      };
    })
    .with({ kind: "blockConstructor" }, (b) => ({
      ...common,
      kind: "ctor" as const,
      ctorId: b.body,
      argument: args.argument,
    }))
    .with({ kind: "blockDelegate" }, () => ({
      ...common,
      kind: "delegate" as const,
      blockId: args.blockId,
      argument: args.argument,
      delegationId: createDelegationId(),
      inboundEscalations: {},
    }))
    .with({ kind: "blockGetField" }, () => ({
      ...common,
      kind: "getField" as const,
      blockId: args.blockId,
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
      total: 0,
      iterableSnapshot: [],
      collected: {},
      iterIndexByCallId: {},
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
      argument: args.argument,
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

// ─── AgentThread (delegation boundary / in-shard closure body) ─────────────

export type SpawnAgentRootArgs = {
  blockId: BlockId;
  argument: Value | undefined;
  delegationId: DelegationId;
  /**
   * Optional parent scope. When set, the new agent's scope inherits from it —
   * used for closure dispatch so the body sees captured locals. Top-level
   * qualifiedName dispatch leaves it null and the agent runs isolated.
   */
  capturedScopeId?: ScopeId | null;
  /**
   * The activation's ambient generic substitution (from the inbound delegate's
   * `generics`), recorded on the agent's root scope for `statementApplyGenerics`
   * inside the body to resolve `foo[T]` placeholders against.
   */
  ambientGenerics?: Record<string, import("../json.js").Json>;
  /**
   * For an IN-SHARD closure call (the hot path): the call-site thread + callId
   * that this agent body answers to, so it is a NON-root agent (its `return`
   * proxies up the local tree to the lexical target, and its requests bubble to
   * an enclosing handle — no delegation boundary). Omitted for a true inbound
   * delegate, where the agent is a delegation root (parent === null).
   */
  parent?: { threadId: ThreadId; callId: CallId };
};

/**
 * Spawn an AgentThread for a `blockAgent`. Two callers:
 *
 *   - an inbound `delegate` (translateExternal) → a delegation ROOT (parent
 *     omitted); its completion drives the outbound delegateAck.
 *   - an in-shard closure call (delegate.ts / callAgent.ts) → a NON-root agent
 *     (parent supplied); it `done`s its caller and proxies control upward.
 *
 * Args are bound into the body scope by the AgentThread's own `create` op.
 * Returns the new ThreadId.
 */
export function spawnAgentRoot(ctx: StepCtx, args: SpawnAgentRootArgs): ThreadId {
  const block = ctx.state.irModule.blocks[String(args.blockId)] as Block | undefined;
  if (block === undefined || block.kind !== "blockAgent") {
    throw new Error(
      `engine.spawnAgentRoot: blockId ${args.blockId} is not a blockAgent (${block?.kind})`,
    );
  }

  const newScopeId = allocScope(ctx.store, args.capturedScopeId ?? null, ctx.state.selfEntity);
  if (args.ambientGenerics !== undefined) {
    ctx.store.scopes[newScopeId]!.ambientGenerics = args.ambientGenerics;
  }

  const newThreadId = createThreadId();
  const common = newCommonFields({
    id: newThreadId,
    parent: args.parent?.threadId ?? null,
    parentCallId: args.parent?.callId ?? null,
    scopeId: newScopeId,
  });
  const agent: Thread = {
    ...common,
    kind: "agent",
    blockId: args.blockId,
    argument: args.argument,
    delegationId: args.delegationId,
    outboundEscalations: {},
  };
  ctx.state.threads[newThreadId] = agent as Thread;
  ctx.state.threadCount++;
  if (args.parent !== undefined) {
    const parent = ctx.state.threads[args.parent.threadId] as Thread | undefined;
    if (parent === undefined) {
      throw new Error(`engine.spawnAgentRoot: parent ${args.parent.threadId} not found`);
    }
    setChild(parent, args.parent.callId, newThreadId);
  }
  ctx.enqueue({ kind: "create", threadId: newThreadId });
  return newThreadId;
}
