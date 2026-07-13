// Spawning an in-instance child thread: allocate a fresh child scope, seed it with the block's
// parameters, build the `Thread` variant for the block kind, and schedule its `create`. This backs both
// the root `AgentThread` spawning its body and every `OperationCall` into a structural node, plus the
// per-iteration / per-element / per-handler bodies. The parent allocates the `callId` (and records its
// own pending state) before calling in, so the child's `parentCallId` correlates the eventual `callAck`.
//
// `AgentThread` is never spawned here — it is an instance root, raised by the instance layer. `delegate`
// threads are spawned by the delegate op (they proxy a cross-instance child, not a block).

import type { Block, BlockId } from "@katari-lang/types";
import { type CallId, newDelegationId, type ScopeId, type ThreadId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { StepContext } from "./context.js";
import { allocateScope, writeVariable } from "./scope.js";
import { allocateThreadId } from "./store.js";
import type { Thread, ThreadBase, ThreadOrigin } from "./types.js";

/** Resolve a block by id within the running instance's snapshot (unwrapping its `BlockInformation`). */
export function getBlock(ctx: StepContext, blockId: BlockId): Block {
  return ctx.ir.block(blockId).block;
}

/**
 * Spawn a child thread for `blockId` under `parent`, in a fresh scope chained to `parentScopeId` and
 * seeded with `parameters` (mapped through the block's `BlockInformation.parameters`). Returns the new
 * thread id; the caller has already allocated `callId` and set its pending state.
 */
export function spawnThread(
  ctx: StepContext,
  args: {
    parent: ThreadId;
    parentCallId: CallId;
    parentScopeId: ScopeId;
    blockId: BlockId;
    parameters: Record<string, Value>;
    /** Override the origin the child would otherwise inherit from its parent — supplied only when spawning a
     *  finalizer root under the (user) agent root, to stamp the whole finalizer subtree `finalizer`. */
    origin?: ThreadOrigin;
  },
): ThreadId {
  const information = ctx.ir.block(args.blockId);
  const scopeId = allocateScope(ctx.store, args.parentScopeId, ctx.instance.id);
  for (const [name, value] of Object.entries(args.parameters)) {
    const variable = information.parameters[name];
    if (variable === undefined) {
      throw new Error(`block ${args.blockId} has no parameter named "${name}"`);
    }
    writeVariable(ctx.store, scopeId, variable, value);
  }
  const threadId = allocateThreadId(ctx.instance);
  const base: ThreadBase = {
    id: threadId,
    parent: args.parent,
    parentCallId: args.parentCallId,
    scopeId,
    blockId: args.blockId,
    status: "running",
    // Inherit the spawning parent's origin (a finalizer's sub-threads are finalizers too), unless the caller
    // stamps one explicitly (the finalizer root spawned under the user agent root).
    origin: args.origin ?? ctx.instance.threads[args.parent]?.origin ?? "user",
    forwardRoutes: {},
  };
  ctx.instance.threads[threadId] = threadForBlock(information.block, base);
  ctx.enqueue({ kind: "create", thread: threadId });
  return threadId;
}

/** Build the `Thread` variant for a block kind over a prepared base. `agent` is an instance root (raised
 *  elsewhere); `delegate` is not a block — neither is constructed here. */
export function threadForBlock(block: Block, base: ThreadBase): Thread {
  switch (block.kind) {
    case "sequence":
      return { ...base, kind: "sequence", cursor: 0, pending: null };
    case "primitive":
      return { ...base, kind: "primitive", invocation: { kind: "block" } };
    case "construct":
      return { ...base, kind: "construct" };
    case "request":
      return { ...base, kind: "request" };
    case "external":
      // Born like a delegate proxy: a fresh delegation it will open on `create` when it emits its
      // `delegate` to its reactor. The block's marker is copied verbatim — the compiler already pins it
      // to the known reactor names (and stamps `ffi` when the `from` clause is absent). This is the
      // `wrapper` role: the spawning instance's whole body is this external leaf, so the ack value is
      // the instance's own result (conformed against its declared output at the core reactor).
      return {
        ...base,
        kind: "external",
        delegationId: newDelegationId(),
        relays: {},
        reactor: block.reactor,
        role: "wrapper",
      };
    case "match":
      return { ...base, kind: "match", pending: null };
    case "for":
      return {
        ...base,
        kind: "for",
        parallel: block.parallel,
        cursor: 0,
        collected: {},
        states: {},
        pending: {},
        postCancelCollect: {},
        thenPending: null,
      };
    case "forever":
      return { ...base, kind: "forever", pending: null, states: {}, postCancelAdvance: {} };
    case "handle":
      return {
        ...base,
        kind: "handle",
        parallel: block.parallel,
        states: {},
        bodyCall: null,
        handlers: {},
        pendingRequests: [],
        postCancelActions: {},
        thenPending: null,
      };
    case "parallel":
      return { ...base, kind: "parallel", pending: {}, collected: {} };
    case "agent":
      throw new Error("an agent block is an instance root, not a spawnable in-instance child");
  }
}
