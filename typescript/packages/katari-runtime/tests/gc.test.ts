// Garbage-collection unit tests.
//
// These exercise `collectGarbage` directly without going through `applyEvent`
// — that way we can verify the reachability invariants (live thread scopeIds
// as roots, transitive trace through scope.parentId chains and through
// closure values stored in scope.values) without having to construct a full
// IR module.

import { describe, expect, it } from "vitest";
import { collectGarbage, createMachine } from "../src/index.js";
import {
  createScope,
  getScope,
  setValueInScope,
} from "../src/machine/scope.js";
import { APIThread } from "../src/machine/thread/api.js";
import { createThreadId } from "../src/machine/id.js";
import { EMPTY_BOUNDARIES } from "../src/machine/thread/types.js";
import type { BlockId, ReqId, VarId } from "../src/ir/types.js";
import type { ScopeId, ThreadId } from "../src/machine/id.js";

function emptyIR(name = "test") {
  return {
    metadata: { schemaVersion: 1 },
    name,
    blocks: {},
    entries: {},
    nameTable: { varNames: {}, blockNames: {} },
  };
}

/**
 * Build a single APIThread on the given scope so we have a non-empty root
 * set without needing the full thread factory.
 */
function attachStubThread(
  machine: ReturnType<typeof createMachine>,
  scopeId: ScopeId,
): { id: ThreadId } {
  const thread = new (class extends APIThread {})(
    {
      id: createThreadId(),
      scopeId,
      handlers: new Map(),
      boundaries: EMPTY_BOUNDARIES,
    },
    "stub-delegation" as never,
    0 as BlockId,
    {},
  );
  machine.threads.set(thread.id, thread);
  machine.apiDelegations.set("stub-delegation" as never, thread);
  return { id: thread.id };
}

describe("collectGarbage", () => {
  it("sweeps every scope when no threads are alive", () => {
    const machine = createMachine(emptyIR());
    createScope(machine, null);
    createScope(machine, null);
    createScope(machine, null);
    expect(machine.scopes.size).toBe(3);

    collectGarbage(machine);

    expect(machine.scopes.size).toBe(0);
  });

  it("preserves the scope a live thread points at", () => {
    const machine = createMachine(emptyIR());
    const liveScope = createScope(machine, null);
    createScope(machine, null); // unreachable peer
    createScope(machine, null); // unreachable peer

    attachStubThread(machine, liveScope.id);

    collectGarbage(machine);

    expect(machine.scopes.has(liveScope.id)).toBe(true);
    expect(machine.scopes.size).toBe(1);
  });

  it("preserves the parent chain of a live scope (transitive)", () => {
    const machine = createMachine(emptyIR());
    const grandparent = createScope(machine, null);
    const parent = createScope(machine, grandparent.id);
    const child = createScope(machine, parent.id);
    const sibling = createScope(machine, null); // unreachable

    attachStubThread(machine, child.id);

    collectGarbage(machine);

    expect(machine.scopes.has(child.id)).toBe(true);
    expect(machine.scopes.has(parent.id)).toBe(true);
    expect(machine.scopes.has(grandparent.id)).toBe(true);
    expect(machine.scopes.has(sibling.id)).toBe(false);
  });

  it("preserves a closure-captured scope when the closure value is in a reachable scope", () => {
    const machine = createMachine(emptyIR());
    const liveScope = createScope(machine, null);
    const capturedScope = createScope(machine, null);

    setValueInScope(machine, liveScope.id, 1 as VarId, {
      kind: "closure",
      blockId: 99 as BlockId,
      scopeId: capturedScope.id,
    });

    attachStubThread(machine, liveScope.id);

    collectGarbage(machine);

    // capturedScope is *not* a parent of liveScope; it's only reachable
    // because a closure value lives in liveScope.values. The trace must
    // follow that link.
    expect(machine.scopes.has(capturedScope.id)).toBe(true);
    expect(machine.scopes.has(liveScope.id)).toBe(true);
  });

  it("transitively follows closure references through tagged-value fields and tuple/array elements", () => {
    const machine = createMachine(emptyIR());
    const liveScope = createScope(machine, null);
    const capturedA = createScope(machine, null);
    const capturedB = createScope(machine, null);
    const capturedC = createScope(machine, null);

    // liveScope holds: a tuple of [closure(A), tagged{f: closure(B)}, array[closure(C)]]
    setValueInScope(machine, liveScope.id, 10 as VarId, {
      kind: "tuple",
      elements: [
        { kind: "closure", blockId: 1 as BlockId, scopeId: capturedA.id },
        {
          kind: "tagged",
          ctorId: 1 as ReqId as never,
          fields: {
            f: { kind: "closure", blockId: 2 as BlockId, scopeId: capturedB.id },
          },
        },
        {
          kind: "array",
          elements: [
            { kind: "closure", blockId: 3 as BlockId, scopeId: capturedC.id },
          ],
        },
      ],
    });

    attachStubThread(machine, liveScope.id);

    collectGarbage(machine);

    expect(machine.scopes.has(capturedA.id)).toBe(true);
    expect(machine.scopes.has(capturedB.id)).toBe(true);
    expect(machine.scopes.has(capturedC.id)).toBe(true);
  });

  it("sweeps a scope that's only reachable via a now-dead value (no live closure references)", () => {
    const machine = createMachine(emptyIR());
    const liveScope = createScope(machine, null);
    const orphanScope = createScope(machine, null);
    void orphanScope;

    attachStubThread(machine, liveScope.id);

    collectGarbage(machine);

    expect(machine.scopes.has(liveScope.id)).toBe(true);
    expect(machine.scopes.size).toBe(1);
  });

  it("keeps the same scope reachable across two GC passes when nothing changes", () => {
    const machine = createMachine(emptyIR());
    const liveScope = createScope(machine, null);
    attachStubThread(machine, liveScope.id);

    collectGarbage(machine);
    expect(machine.scopes.has(liveScope.id)).toBe(true);

    // Idempotent: running again with no mutation leaves the same scope.
    collectGarbage(machine);
    expect(machine.scopes.has(liveScope.id)).toBe(true);
    expect(machine.scopes.size).toBe(1);
  });

  it("works even when scope chains form a parent diamond (shared ancestor)", () => {
    // root ← branchA ← liveA
    // root ← branchB ← liveB
    // both branches share `root` as the great-grandparent.
    const machine = createMachine(emptyIR());
    const root = createScope(machine, null);
    const branchA = createScope(machine, root.id);
    const branchB = createScope(machine, root.id);
    const liveA = createScope(machine, branchA.id);
    const liveB = createScope(machine, branchB.id);

    attachStubThread(machine, liveA.id);
    attachStubThread(machine, liveB.id);

    collectGarbage(machine);

    expect(machine.scopes.size).toBe(5);
    // Sanity: all scopes still resolvable.
    expect(getScope(machine, root.id)).toBeDefined();
    expect(getScope(machine, branchA.id)).toBeDefined();
    expect(getScope(machine, branchB.id)).toBeDefined();
  });
});
