// Thread spawning: allocate a new Thread record for a given Block, register
// it in state.threads + parent.children, and enqueue its `create` event.
//
// This is the engine's only Block-kind switch outside of pattern matching
// itself. Variant-specific fields are filled in here so the variant ops
// can rely on a complete record from their first `create` invocation.

import type { Draft } from "immer";
import { match } from "ts-pattern";
import type { Block, BlockId } from "../ir/types.js";
import { createScopeId, createThreadId, type CallId, type ScopeId, type ThreadId } from "./id.js";
import type { StepCtx } from "./step-ctx.js";
import type { Value } from "./value.js";
import {
  newCommonFields,
  setChild,
} from "./thread/common.js";
import type { ReqId } from "../ir/types.js";
import type { Thread } from "./thread/types.js";

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
    .with({ kind: "blockUser" }, b => ({
      ...common,
      kind: "user" as const,
      blockId: args.blockId,
      pc: 0,
      catchesReturn: b.body.kind === "blockKindAgent",
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
      delegationId: createDelegationIdLocal(),
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
      // Phase 3.1 stub: BlockAgent variant is reserved for the AgentThread
      // refactor (Phase 3.3). Lowering does not currently emit blockAgent,
      // so this branch is unreachable; it exists only to satisfy the
      // ts-pattern exhaustiveness check while the new variant lands.
      throw new Error(
        "engine.spawnChild: blockAgent is not yet implemented (Phase 3.3 pending)",
      );
    })
    .exhaustive();

  ctx.state.threads[newThreadId] = thread as Draft<Thread>;
  setChild(parent, args.parentCallId, newThreadId);

  ctx.enqueue({ kind: "create", threadId: newThreadId });

  return newThreadId;
}

// Local delegation-id allocator (UUID). Kept here instead of importing
// from id.ts to avoid an unused-import lint when the file uses it once.
function createDelegationIdLocal(): import("./id.js").DelegationId {
  return crypto.randomUUID() as import("./id.js").DelegationId;
}
