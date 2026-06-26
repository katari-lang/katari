// Recovery integration test: drive an actor to a durable suspend point (an in-flight external call),
// then resume the project in a *fresh* actor sharing the same StoringPersistence — exercising the whole
// recovery path (serialise at the turn boundary → reload → reactivate → rebuild routing → re-dispatch the
// open external → make progress past it). This is the first end-to-end test of `reactivate`; the codec
// round-trip test covers only the pure serialise/deserialise step.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import type { Persistence, PersistenceTx } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import {
  type FfiCall,
  type FfiCompletion,
  type FfiTransport,
  StubFfiTransport,
} from "../src/runtime/external/runner.js";
import {
  apiRootIdOf,
  newDelegationId,
  newOutboxSeq,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-recovery" as ProjectId;
const SNAPSHOT = "snapshot-recovery" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** A recording FFI transport: logs each dispatched key, and optionally completes some keys immediately
 *  (the others stay in flight forever, modelling a slow external call). */
function recordingRunner(complete: Record<string, boolean>): {
  runner: FfiTransport;
  dispatched: string[];
} {
  const dispatched: string[] = [];
  let sink: ((completion: FfiCompletion) => void) | null = null;
  const runner: FfiTransport = {
    onComplete(register) {
      sink = register;
    },
    dispatch(call: FfiCall) {
      dispatched.push(call.key);
      if (complete[call.key]) {
        // The completion value is plain Json (the ffi reactor lifts it back to a Value for the delegateAck).
        sink?.({
          delegation: call.delegation,
          outcome: { kind: "result", value: `${call.key}-done` },
        });
      }
    },
    abort() {},
  };
  return { runner, dispatched };
}

/** A `Persistence` that throws on its `nth` commit, delegating everything else to an inner store — so a
 *  transient commit failure (and the actor's poison → drop → reactivate recovery) is exercisable. The throw
 *  happens before the inner transaction runs, so the durable store is untouched for the failed turn. */
class FailingPersistence implements Persistence {
  private commits = 0;
  constructor(
    private readonly inner: StoringPersistence,
    private readonly failOnCommit: number,
  ) {}
  load(projectId: ProjectId, body: Parameters<Persistence["load"]>[1]) {
    return this.inner.load(projectId, body);
  }
  async transaction(projectId: ProjectId, body: (tx: PersistenceTx) => Promise<void>): Promise<void> {
    this.commits += 1;
    if (this.commits === this.failOnCommit) throw new Error("injected commit failure");
    await this.inner.transaction(projectId, body);
  }
}

function makeActor(
  ir: IRModule,
  persistence: Persistence,
  external: FfiTransport = new StubFfiTransport(),
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external,
    persistence,
  });
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("recovery", () => {
  test("resumes a project from persisted state in a fresh actor and makes progress past an in-flight external", async () => {
    // agent main() { let a = step1({}); let b = step2({}); return b }
    // step1 / step2 are external agents. The first actor's runner never completes step1, so the project is
    // persisted suspended on step1's in-flight external. A fresh actor (same persistence) completes step1
    // on recovery, which resumes `main` and lets it dispatch step2 — observable progress past the crash.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 20 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("step1") },
                argument: 20,
                output: 21,
              },
              { kind: "makeRecord", entries: [], output: 22 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("step2") },
                argument: 22,
                output: 23,
              },
              { kind: "exit", target: 0, value: 23 },
            ],
          },
          parameters: { parameter: 11 },
        },
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: { block: { kind: "external", key: "step1", input: 8 }, parameters: { parameter: 8 } },
        8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        9: { block: { kind: "external", key: "step2", input: 10 }, parameters: { parameter: 10 } },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("step1")]: 6,
        [createAgentName("step2")]: 8,
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    // First actor: step1 dispatches but never completes, so the project persists suspended on it.
    const first = recordingRunner({ step1: false });
    const actorOne = makeActor(ir, persistence, first.runner);
    actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (first.dispatched.includes("step1") ? true : undefined));
    // The run root (`main`) and step1's external instance are both persisted at this suspend point.
    await waitUntil(() => (persistence.instanceCount() >= 2 ? true : undefined));

    // Process "crash": a brand-new actor recovers from the same persisted state. Its runner completes
    // step1, so recovery's re-dispatch of the open external resolves and `main` proceeds to step2.
    const second = recordingRunner({ step1: true });
    const actorTwo = makeActor(ir, persistence, second.runner);
    await actorTwo.activate();

    // step1 was re-dispatched on recovery; completing it resumed `main`, which dispatched step2 — progress
    // strictly past the suspend point, reconstructed entirely from persisted rows.
    await waitUntil(() => (second.dispatched.includes("step2") ? true : undefined));
    expect(second.dispatched).toContain("step1");
    expect(second.dispatched).toContain("step2");
  });

  test("recovers a run's routing from the Layer 1 delegations table and durably records its result", async () => {
    // agent main() { return step1({}) }   — `main` is the run root (its delegation's caller is the api
    // root, which runs no engine thread). After a crash, the run delegation's caller can only be recovered
    // from the Layer 1 delegations table; once recovery completes step1, `main` returns and the run
    // delegation moves running → done with the result — the durable run outcome, no in-actor promise.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 20 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("step1") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: { block: { kind: "external", key: "step1", input: 8 }, parameters: { parameter: 8 } },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("step1")]: 6,
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    const first = recordingRunner({ step1: false });
    const actorOne = makeActor(ir, persistence, first.runner);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (first.dispatched.includes("step1") ? true : undefined));
    // The run delegation is durably `running` at the suspend point (its caller = the api root).
    expect(persistence.peekDelegation(run)?.state).toBe("running");

    // Crash + recover in a fresh actor with no in-memory run handlers. Recovery rebuilds the run's caller
    // purely from the delegations table, completes step1, and lets `main` return.
    const second = recordingRunner({ step1: true });
    const actorTwo = makeActor(ir, persistence, second.runner);
    await actorTwo.activate();

    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "step1-done" });
  });

  test("recovers a run suspended on an open user escalation and resumes it when answered in a fresh actor", async () => {
    // agent main() { ask_value({}) }   — ask_value has no handler, so its request escalates all the way to
    // the run root, where the engine keeps it open (the run suspends awaiting a user's answer). The open
    // escalation lives only in actor memory until persisted as an `escalations(open)` row; recovery must
    // rehydrate it so a fresh actor can list and answer it, resuming the run.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 20 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: { kind: "request", name: createAgentName("ask_value"), input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("ask_value")]: 5,
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    const actorOne = makeActor(ir, persistence);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    // Drive to the suspend point: the run is open on the unhandled `ask_value` request (now an
    // `escalations(open)` row, raised by the run root).
    await waitUntil(() => (actorOne.listOpenEscalations().length > 0 ? true : undefined));

    // Crash + recover in a fresh actor — no in-memory open-escalation registry survives, so it must come
    // back from the persisted `escalations(open)` row.
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const open = await waitUntil(() => {
      const list = actorTwo.listOpenEscalations();
      return list.length > 0 ? list : undefined;
    });
    expect(open).toHaveLength(1);
    expect(open[0]?.request).toBe(createAgentName("ask_value"));
    expect(open[0]?.argument).toEqual({ kind: "record", fields: {} });

    // Answering it in the recovered actor resumes the run to completion, recorded durably as the run
    // delegation's `done` result.
    const escalation = open[0]?.escalation;
    if (escalation === undefined) throw new Error("no recovered open escalation");
    await actorTwo.answerEscalation(escalation, { kind: "integer", value: 42 });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 42 });
    expect(actorTwo.listOpenEscalations()).toHaveLength(0);
    // Answering recorded the run's escalation history (question + answer), written atomically with the
    // relayed escalateAck.
    const audit = persistence.auditsFor(run);
    expect(audit).toHaveLength(1);
    expect(audit[0]?.escalation).toBe(escalation);
    expect(audit[0]?.question).toEqual({ kind: "record", fields: {} });
    expect(audit[0]?.answer).toEqual({ kind: "integer", value: 42 });
  });

  test("startRun writes the run's metadata sidecar atomically with its delegation", async () => {
    // C3: the engine writes the `runs` metadata row in the same commit as the run's `delegate`, so after the
    // launch commit (`started`) a run is durable with BOTH its metadata and its delegation — never one alone.
    const persistence = new StoringPersistence();
    const actor = makeActor(constantIr(), persistence);
    const argument = { kind: "integer" as const, value: 3 };
    const { run, result, started } = actor.startRun(
      createAgentName("main"),
      SNAPSHOT,
      argument,
      "nightly",
    );
    void result.catch(() => {});
    await started;

    const meta = persistence.peekRun(run);
    expect(meta?.name).toBe("nightly");
    expect(meta?.qualifiedName).toBe(createAgentName("main"));
    expect(meta?.snapshotId).toBe(SNAPSHOT);
    expect(meta?.argument).toEqual(argument);
    expect(meta?.cancelReason).toBeNull();
    // The delegation row committed in the same launch commit — both durable, atomically.
    expect(persistence.peekDelegation(run)).toBeDefined();
  });

  test("records a failed run durably in Layer 1 (delegation failed + message) and tears down its root", async () => {
    // agent main() { add({ left: 1, right: "x" }) }  — the add prim panics (a string is not a number); with
    // no handler the panic reaches the run root, which fails the run. The failure must be recorded durably
    // (the run delegation moves to `failed` with the message) and the still-suspended root torn down (no
    // leak) — previously it only rejected an in-actor promise, leaving the engine state inconsistent.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 2, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 3, value: { kind: "string", value: "x" } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 2],
                  ["right", 3],
                ],
                output: 4,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("primitive.add") },
                argument: 4,
                output: 5,
              },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: {
          block: { kind: "primitive", name: "primitive.add", input: 8 },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("primitive.add")]: 6,
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await expect(result).rejects.toThrow(/panic.*number/);
    // The failure is durable on the `runs` record by the time the run settles (the run delegation row, pure
    // live routing, was deleted on its terminal — the outcome lives here now).
    const record = persistence.peekRun(run);
    expect(record?.state).toBe("error");
    expect(record?.errorMessage).toMatch(/panic.*number/);
    // And the run's root instance (and its descendants) were torn down — nothing left suspended.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
  });

  // agent main() { return 7 }  (no children, completes in its own create turn)
  function constantIr(): IRModule {
    return {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: 2,
            operations: [{ kind: "loadLiteral", output: 2, value: { kind: "integer", value: 7 } }],
          },
          parameters: { parameter: 11 },
        },
      },
      entries: { [createAgentName("main")]: 0 },
      names: {},
    };
  }

  test("drains the outbox to empty once a run completes (every produced event was consumed)", async () => {
    const persistence = new StoringPersistence();
    const actor = makeActor(constantIr(), persistence);
    await expect(actor.startRun(createAgentName("main"), SNAPSHOT, null).result).resolves.toEqual({
      kind: "integer",
      value: 7,
    });
    // The run delegate + the run root's delegateAck were each produced then consumed: no leak.
    await waitUntil(() => (persistence.outboxSize() === 0 ? true : undefined));
    expect(persistence.outboxSize()).toBe(0);
  });

  test("replays an undrained outbox event in a fresh actor (a produced event survives a crash)", async () => {
    // Simulate a crash right after `startRun` committed: the api root opened the run's delegation row
    // (running) and produced its `delegate` atomically, but the delegate was never consumed. A fresh actor
    // must reload the run row, replay the delegate from the outbox, summon the agent, and run it to
    // completion — recorded durably as the delegation's `done` result, all reconstructed from the rows.
    const persistence = new StoringPersistence();
    const run = newDelegationId();
    const target = { kind: "named" as const, name: createAgentName("main"), snapshot: SNAPSHOT };
    // A run delegation: issued by the api root (`from: api`) to a core instance (`to: core`).
    persistence.seedDelegation(run, {
      caller: apiRootIdOf(PROJECT),
      fromReactor: "api",
      toReactor: "core",
      target,
      argument: null,
    });
    // startRun also writes the `runs` row (the run's durable record); seed it so recovery can record the outcome.
    persistence.seedRun(run, {
      name: "main",
      qualifiedName: createAgentName("main"),
      snapshotId: SNAPSHOT,
      argument: null,
    });
    persistence.seedOutbox({
      seq: newOutboxSeq(),
      issuer: apiRootIdOf(PROJECT),
      event: { kind: "delegate", from: "api", to: "core", delegation: run, target, argument: null },
    });

    const actor = makeActor(constantIr(), persistence);
    await actor.activate();

    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 7 });
    expect(persistence.outboxSize()).toBe(0);
  });

  test("a poisoned commit drops the warm state and reactivates from durable — the run still completes", async () => {
    // The run's `delegate` commits (turn 1), then the run-root's create + complete turn fails its commit
    // (turn 2). The actor must not advance on that failure: it drops the warm engine state and reactivates
    // from durable (the still-running delegation row + the unconsumed delegate in the outbox), replays the
    // turn — now succeeding — and the run completes. The in-process result promise is rejected on the poison
    // (a non-SoT hook), so the durable `runs` outcome is the proof the run finished.
    const store = new StoringPersistence();
    const persistence = new FailingPersistence(store, 2);
    const actor = makeActor(constantIr(), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/reset after a commit failure/);

    const done = await waitUntil(() => {
      const record = store.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 7 });
    // Recovery quiesced: the outbox drained and nothing is left suspended.
    await waitUntil(() => (store.outboxSize() === 0 ? true : undefined));
    expect(store.instanceCount()).toBe(0);
  });
});
