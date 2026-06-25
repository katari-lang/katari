// Unit test for the intra-instance scope GC: it must free the scopes an instance owns once nothing in the
// instance references them, while keeping every scope still reachable — through a thread's lexical chain, or
// a closure captured in a thread's value (a `for` accumulator) or a scope binding.

import { describe, expect, test } from "vitest";
import { unreachableOwnedScopes } from "../src/runtime/engine/gc.js";
import { rebuildScopeOwnerIndex } from "../src/runtime/engine/scope.js";
import type { CoreInstance, ProjectStore, Scope, Thread } from "../src/runtime/engine/types.js";
import {
  type DelegationId,
  type InstanceId,
  type ScopeId,
  type SnapshotId,
  toCallId,
  toScopeId,
  toThreadId,
} from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const INSTANCE = "instance-gc" as InstanceId;

function scope(id: number, parent: number | null, owner: InstanceId | null, values: Record<number, Value> = {}): Scope {
  return { id: toScopeId(id), parentId: parent === null ? null : toScopeId(parent), owner, values };
}

function instanceWith(threads: Record<number, Thread>): CoreInstance {
  return {
    kind: "core",
    id: INSTANCE,
    delegationId: "d" as DelegationId,
    target: { kind: "named", name: "demo.main" as never, snapshot: "snap" as SnapshotId },
    argument: null,
    status: "running",
    rootThreadId: toThreadId(0),
    threads,
    cancelExits: {},
    nextThreadId: Object.keys(threads).length,
    nextCallId: 0,
    nextAskId: 0,
  };
}

/** A bare agent root evaluating in `scopeId` (no embedded values). */
function agentThread(id: number, scopeId: number): Thread {
  return {
    id: toThreadId(id),
    parent: null,
    parentCallId: null,
    scopeId: toScopeId(scopeId),
    blockId: 0,
    status: "running",
    forwardRoutes: {},
    kind: "agent",
    pending: null,
    escalations: {},
  };
}

const closureCapturing = (scopeId: number): Value => ({
  kind: "closure",
  blockId: 0,
  scopeId: toScopeId(scopeId),
  snapshot: "snap" as SnapshotId,
  module: "",
});

function ownedIds(store: ProjectStore, instance: CoreInstance): number[] {
  // The fixtures hand-build the `scopes` map, so populate the owner index over it before the sweep reads it.
  rebuildScopeOwnerIndex(store);
  return unreachableOwnedScopes(store, instance)
    .map((id: ScopeId) => id as number)
    .sort((left, right) => left - right);
}

describe("unreachableOwnedScopes", () => {
  test("frees an owned scope nothing references, keeps the live thread chain", () => {
    // Chain 1 -> 0 is the live agent's scope; scope 2 (a completed sub-thread's, owned by the instance) is
    // dead; scope 3 is owned by another instance and must never be touched.
    const store: ProjectStore = {
      instances: {},
      scopes: {
        0: scope(0, null, INSTANCE),
        1: scope(1, 0, INSTANCE),
        2: scope(2, null, INSTANCE),
        3: scope(3, null, "other" as InstanceId),
      },
      scopesByOwner: new Map(),
      nextScopeId: 4,
      blobOwners: {},
    };
    const instance = instanceWith({ 0: agentThread(0, 1) });
    expect(ownedIds(store, instance)).toEqual([2]);
  });

  test("keeps a scope a closure in a `for` accumulator captures (not reachable via any thread chain)", () => {
    // Scope 2 is owned by the instance and chained from nothing live — but a closure in the `for` thread's
    // `collected` accumulator captures it (chain 2 -> 1), so 2 and 1 must survive; only the truly dead 5 frees.
    const store: ProjectStore = {
      instances: {},
      scopes: {
        0: scope(0, null, INSTANCE),
        1: scope(1, 0, INSTANCE),
        2: scope(2, 1, INSTANCE),
        5: scope(5, null, INSTANCE),
      },
      scopesByOwner: new Map(),
      nextScopeId: 6,
      blobOwners: {},
    };
    const forThread: Thread = {
      id: toThreadId(1),
      parent: toThreadId(0),
      parentCallId: toCallId(0),
      scopeId: toScopeId(0),
      blockId: 1,
      status: "running",
      forwardRoutes: {},
      kind: "for",
      parallel: false,
      cursor: 1,
      collected: { 0: closureCapturing(2) },
      states: {},
      pending: {},
      postCancelCollect: {},
      thenPending: null,
    };
    const instance = instanceWith({ 0: agentThread(0, 0), 1: forThread });
    expect(ownedIds(store, instance)).toEqual([5]);
  });

  test("follows a closure captured in another scope's binding, transitively", () => {
    // The live scope 0 binds a closure capturing scope 9; scope 9's binding captures scope 8. Both survive.
    const store: ProjectStore = {
      instances: {},
      scopes: {
        0: scope(0, null, INSTANCE, { 4: closureCapturing(9) }),
        8: scope(8, null, INSTANCE),
        9: scope(9, null, INSTANCE, { 7: closureCapturing(8) }),
        10: scope(10, null, INSTANCE),
      },
      scopesByOwner: new Map(),
      nextScopeId: 11,
      blobOwners: {},
    };
    const instance = instanceWith({ 0: agentThread(0, 0) });
    expect(ownedIds(store, instance)).toEqual([10]);
  });
});
