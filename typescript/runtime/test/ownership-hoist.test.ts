// Ownership hoist: every observable upward event (a `delegateAck` result, an `escalate`'s carried ask)
// reassigns the sending instance's remaining blobs one delegation step up, onto the caller instance — the
// text-plane fix (an id an AI remembers survives its producer's completion). These tests drive the base
// `Reactor.send` directly through a minimal concrete reactor, so they exercise the real hoist edge without a
// whole engine: the received-delegation edge (`acceptDelegation`) names each hop's caller instance, and each
// `send` climbs the blob one step. The complementary external-call producer path lives in `ffi-blob.test.ts`.

import type { QualifiedName } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { Reactor } from "../src/runtime/actor/reactor.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import type { BlobEntry } from "../src/runtime/engine/types.js";
import type { ExternalEvent, ReactorName } from "../src/runtime/event/types.js";
import {
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  type ProjectId,
} from "../src/runtime/ids.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-hoist" as ProjectId;
const RUN = "run-1" as InstanceId;
const BLOB = "blob-1" as BlobId;

/** A produced-blob entry owned by `owner` (the bytes are irrelevant here — ownership is the subject). */
const blobEntry = (owner: InstanceId): BlobEntry => ({
  owner,
  hash: "hash",
  size: 3,
  semanticKind: "file",
});

/** A scalar result value that captures no resource, so `release` frees nothing and the whole hoist is what
 *  moves the blob (it stands for a result that carries a blob's id only in some text / json leaf). */
const SCALAR: Value = { kind: "integer", value: 1 };

/** A minimal concrete reactor exposing the protected `acceptDelegation` / `send` so a test can wire a
 *  received edge and emit an upward event through the real base lifecycle. */
class HoistTestReactor extends Reactor {
  constructor(
    readonly name: ReactorName,
    pool: ResourcePool,
  ) {
    super(pool);
  }
  async persist(): Promise<void> {}
  accept(
    delegation: DelegationId,
    instance: InstanceId,
    caller: ReactorName,
    callerInstance: InstanceId | undefined,
  ): void {
    this.acceptDelegation(delegation, instance, caller, RUN, callerInstance);
  }
  emit(event: ExternalEvent, issuer: InstanceId): void {
    this.send(event, issuer);
  }
}

function setup(): { pool: ResourcePool; store: ReturnType<typeof createProjectStore> } {
  const store = createProjectStore();
  return { pool: new ResourcePool(PROJECT, store), store };
}

const delegateAck = (delegation: DelegationId): ExternalEvent => ({
  kind: "delegateAck",
  delegation,
  value: SCALAR,
  from: "core",
  to: "core",
  run: RUN,
});

describe("ownership hoist", () => {
  test("a blob climbs one delegation step on each ack, up a 3-instance chain", () => {
    // grandchild → child → parent, all core. A blob the grandchild owns (its result carried only its id)
    // must climb to the parent as each ack fires, never reclaimed mid-chain.
    const { pool, store } = setup();
    const reactor = new HoistTestReactor("core", pool);
    const grandchild = "i-grandchild" as InstanceId;
    const child = "i-child" as InstanceId;
    const parent = "i-parent" as InstanceId;
    const dGrandchild = "d-grandchild" as DelegationId;
    const dChild = "d-child" as DelegationId;

    // Each hop's received edge names the caller instance the blob hoists onto.
    reactor.accept(dGrandchild, grandchild, "core", child);
    reactor.accept(dChild, child, "core", parent);
    pool.registerBlob(BLOB, blobEntry(grandchild));

    // The grandchild acks: its blob climbs one step, onto the child.
    reactor.emit(delegateAck(dGrandchild), grandchild);
    expect(store.blobs[BLOB]?.owner).toBe(child);

    // The child acks: the blob climbs the next step, onto the parent.
    reactor.emit(delegateAck(dChild), child);
    expect(store.blobs[BLOB]?.owner).toBe(parent);

    // The index tracked the whole climb (only the parent holds it now).
    expect(store.blobsByOwner.get(grandchild)).toBeUndefined();
    expect(store.blobsByOwner.get(child)).toBeUndefined();
    expect([...(store.blobsByOwner.get(parent) ?? [])]).toEqual([BLOB]);
  });

  test("an escalate hoists the raiser's blobs onto its caller; a later cancel does not prune them", () => {
    // The raiser holds a blob, then escalates a request (a text plane the caller now owns). The blob moves to
    // the caller at once, so cancelling the raiser afterwards cannot reclaim it — the id the caller remembers
    // stays live.
    const { pool, store } = setup();
    const reactor = new HoistTestReactor("core", pool);
    const raiser = "i-raiser" as InstanceId;
    const caller = "i-caller" as InstanceId;
    const dRaiser = "d-raiser" as DelegationId;

    reactor.accept(dRaiser, raiser, "core", caller);
    pool.registerBlob(BLOB, blobEntry(raiser));

    reactor.emit(
      {
        kind: "escalate",
        delegation: dRaiser,
        escalation: "e-1" as EscalationId,
        ask: { kind: "request", request: "main.ask" as QualifiedName, argument: null },
        from: "core",
        to: "core",
        run: RUN,
      },
      raiser,
    );
    expect(store.blobs[BLOB]?.owner).toBe(caller);

    // The raiser is later cancelled: reclaiming its holdings must NOT touch the already-hoisted blob.
    pool.reclaimBlobsOwnedBy(raiser);
    expect(store.blobs[BLOB]?.owner).toBe(caller);
  });

  test("runOfInstance reverse-resolves a handled instance's run — the reactor edge the file.free run resolver reads", () => {
    // A blob that hoisted onto a long-lived webhook / mcp serve endpoint call instance is owned by an instance
    // absent from the engine store; `file.free`'s run resolver finds its run through this reverse of the
    // received edge, so a delivery's residual blob stays reclaimable within its run.
    const { pool } = setup();
    const reactor = new HoistTestReactor("webhook", pool);
    const endpoint = "i-endpoint" as InstanceId;
    reactor.accept("d-endpoint" as DelegationId, endpoint, "core", undefined);
    expect(reactor.runOfInstance(endpoint)).toBe(RUN);
    // An instance this reactor does not handle resolves to `undefined` (so the actor's composed resolver
    // falls through to the next reactor).
    expect(reactor.runOfInstance("i-unhandled" as InstanceId)).toBeUndefined();
  });

  test("the run→api boundary does not hoist: a non-carried blob stays on the run root, reclaimed at teardown", () => {
    // A run result's ascent stays purely value-driven (the run instance is permanent). A blob the run root
    // owns that the result did not carry must NOT hoist onto the run instance — it stays on the mortal run
    // root and is reclaimed when that root tears down.
    const { pool, store } = setup();
    const core = new HoistTestReactor("core", pool);
    const runRoot = "i-run-root" as InstanceId;
    const runInstance = "i-run" as InstanceId;
    const runDelegation = "d-run" as DelegationId;

    // The run delegation's caller is the api (its run instance) — the boundary the hoist skips.
    core.accept(runDelegation, runRoot, "api", runInstance);
    pool.registerBlob(BLOB, blobEntry(runRoot));

    core.emit(delegateAck(runDelegation), runRoot);
    // Not hoisted onto the permanent run instance — still the mortal run root's.
    expect(store.blobs[BLOB]?.owner).toBe(runRoot);

    // The run root tears down at the run's terminal, reclaiming the non-carried blob (existing behaviour).
    pool.reclaimBlobsOwnedBy(runRoot);
    expect(store.blobs[BLOB]).toBeUndefined();
  });
});
