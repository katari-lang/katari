// Thread spawning: allocate a new Thread record for a given Block, register
// it in state.threads + parent.children, and enqueue its `create` event.
//
// This is the engine's only Block-kind switch outside of pattern matching
// itself. Variant-specific fields are filled in here so the variant ops
// can rely on a complete record from their first `create` invocation.

import type { Draft } from "immer";
import { match } from "ts-pattern";
import type { Block, BlockId, ReqId } from "../ir/types.js";
import {
  createDelegationId,
  createScopeId,
  createThreadId,
  type CallId,
  type DelegationId,
  type ScopeId,
  type ThreadId,
} from "./id.js";
import type { StepCtx } from "./step-ctx.js";
import type { Value } from "./value.js";
import { newCommonFields, setChild } from "./thread/common.js";
import type { ExternalThread, Thread } from "./thread/types.js";

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
  /**
   * Optional handler-map override. HandleThread uses this when spawning
   * the main body so handlers it owns are visible inside the body. Other
   * spawn sites omit it and inherit from `parent.handlers`.
   */
  handlersOverride?: Record<number, ThreadId>;
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

  const parent = ctx.state.threads[args.parentId] as Draft<Thread> | undefined;
  if (parent === undefined) {
    throw new Error(`engine.spawnChild: parent ${args.parentId} not found`);
  }

  // Allocate the child scope. `isolated` → null parent, `inline` →
  // caller's scope, `captured` → captured scope.
  const newScopeId = createScopeId();
  const parentScopeId = match(args.scopeMode)
    .with({ mode: "isolated" }, () => null as ScopeId | null)
    .with({ mode: "inline" }, m => m.parentScopeId)
    .with({ mode: "captured" }, m => m.capturedScopeId)
    .exhaustive();
  ctx.state.scopes[newScopeId] = {
    id: newScopeId,
    parentId: parentScopeId,
    values: {},
  };

  const newThreadId = createThreadId();
  const handlers = args.handlersOverride
    ? { ...args.handlersOverride }
    : { ...(parent.handlers as Record<number, ThreadId>) };

  const common = newCommonFields({
    id: newThreadId,
    parent: args.parentId,
    parentCallId: args.parentCallId,
    scopeId: newScopeId,
    handlers,
  });

  const thread: Thread = match(block)
    .with({ kind: "blockUser" }, () => ({
      ...common,
      kind: "user" as const,
      blockId: args.blockId,
      pc: 0,
    }))
    .with({ kind: "blockPrim" }, b => ({
      ...common,
      kind: "prim" as const,
      primName: b.body,
      args: args.callArgs,
    }))
    .with({ kind: "blockConstructor" }, b => ({
      ...common,
      kind: "ctor" as const,
      ctorId: b.body,
      args: args.callArgs,
    }))
    .with({ kind: "blockExternal" }, b => ({
      ...common,
      kind: "external" as const,
      externalName: b.body,
      args: args.callArgs,
      delegationId: createDelegationId(),
      pendingEscalations: {},
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
    .with({ kind: "blockRequest" }, b => ({
      ...common,
      kind: "request" as const,
      reqId: b.body as ReqId,
      args: args.callArgs,
    }))
    .with({ kind: "blockAgent" }, () => {
      // Should not be reached: Lowering routes top-level agent calls
      // through `StatementAgentCall` (core→core delegate), which spawns
      // an AgentThread root via `translateExternal` rather than as a
      // child. Reaching here means an old IR with `StatementCall +
      // CallTargetBlock(blockAgentId)` slipped through.
      throw new Error(
        `engine.spawnChild: blockId ${args.blockId} targets a blockAgent — agent calls must use StatementAgentCall`,
      );
    })
    .exhaustive();

  ctx.state.threads[newThreadId] = thread as Draft<Thread>;
  setChild(parent, args.parentCallId, newThreadId);

  ctx.enqueue({ kind: "create", threadId: newThreadId });

  return newThreadId;
}

// ─── AgentThread + ExternalThread (delegation boundary) ───────────────────

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
export function spawnAgentRoot(
  ctx: StepCtx,
  args: SpawnAgentRootArgs,
): ThreadId {
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

  const newThreadId = createThreadId();
  const common = newCommonFields({
    id: newThreadId,
    parent: null,
    parentCallId: null,
    scopeId: newScopeId,
    handlers: {},
  });
  const agent: Thread = {
    ...common,
    kind: "agent",
    blockId: args.blockId,
    args: { ...args.args },
    delegationId: args.delegationId,
    pendingEscalations: {},
  };
  ctx.state.threads[newThreadId] = agent as Draft<Thread>;
  ctx.enqueue({ kind: "create", threadId: newThreadId });
  return newThreadId;
}

export type SpawnExternalForAgentArgs = {
  parentId: ThreadId;
  parentCallId: CallId;
  delegationId: DelegationId;
  args: Record<string, Value>;
};

/**
 * Spawn a "phantom" ExternalThread to receive the eventual `delegateAck`
 * for a core→core agent delegate. Unlike a normal ExternalThread (which
 * fires its own outbound `delegate` on create), this one is created with
 * the delegation already in flight — the caller emits the outbound event
 * directly.
 *
 * Used by `statementAgentCall` / `statementAgentCallClosure` in the
 * UserThread ops.
 */
export function spawnExternalForAgentDelegate(
  ctx: StepCtx,
  args: SpawnExternalForAgentArgs,
): ThreadId {
  const parent = ctx.state.threads[args.parentId] as Draft<Thread> | undefined;
  if (parent === undefined) {
    throw new Error(
      `engine.spawnExternalForAgentDelegate: parent ${args.parentId} not found`,
    );
  }

  const newScopeId = createScopeId();
  ctx.state.scopes[newScopeId] = {
    id: newScopeId,
    parentId: parent.scopeId,
    values: {},
  };

  const newThreadId = createThreadId();
  const common = newCommonFields({
    id: newThreadId,
    parent: args.parentId,
    parentCallId: args.parentCallId,
    scopeId: newScopeId,
    handlers: { ...(parent.handlers as Record<number, ThreadId>) },
  });
  const ext: ExternalThread = {
    ...common,
    kind: "external",
    externalName: { module_: "<agent>", name: "<delegate>" },
    args: { ...args.args },
    delegationId: args.delegationId,
    pendingEscalations: {},
  };
  ctx.state.threads[newThreadId] = ext as Draft<Thread>;
  setChild(parent, args.parentCallId, newThreadId);
  // Register on the sender side so inbound delegateAck / terminateAck
  // can be routed back to this phantom. The caller emits the outbound
  // delegate event itself.
  ctx.state.pendingDelegateOut[args.delegationId as string] = newThreadId;
  return newThreadId;
}
