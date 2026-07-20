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
  type FfiHandler,
  type FfiTransport,
  InProcessFfiTransport,
  StubFfiTransport,
} from "../src/runtime/external/runner.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  apiRootIdOf,
  newDelegationId,
  newInstanceId,
  newOutboxSeq,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-recovery" as ProjectId;
const SNAPSHOT = "snapshot-recovery" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** A recording FFI transport: logs each dispatched key and each recovery, and optionally completes some
 *  keys immediately (the others stay in flight forever, modelling a slow external call). A fresh instance
 *  models a fresh process, so a recovery always refuses (at-most-once, like the real transports). */
function recordingRunner(complete: Record<string, boolean>): {
  runner: FfiTransport;
  dispatched: string[];
  recovered: string[];
} {
  const dispatched: string[] = [];
  const recovered: string[] = [];
  let sink: ((completion: FfiCompletion) => void) | null = null;
  const runner: FfiTransport = {
    onComplete(register) {
      sink = register;
    },
    onDelegate() {},
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
    recover(delegation) {
      recovered.push(delegation);
      sink?.({
        delegation,
        outcome: { kind: "error", message: "interrupted by a runtime restart (at-most-once)" },
      });
    },
    abort() {},
    deliverDelegateResult() {},
    close() {},
  };
  return { runner, dispatched, recovered };
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
    http: new StubHttpTransport(),
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
  test("a warm reset leaves the in-flight handler running: its completion resumes the reloaded project", async () => {
    // agent main() { let a = step1({}); let b = step2({}); return b }
    // step1 / step2 are external agents. The SAME transport serves both actors — the process-survived
    // (poison / warm-reset) model: step1's handler is still live when the second actor reloads, so its
    // `recover` leaves it alone, and releasing the handler resumes `main`, which dispatches step2.
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
        7: { block: { kind: "external", key: "step1", input: 8, reactor: "ffi" }, parameters: { parameter: 8 } },
        8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        9: { block: { kind: "external", key: "step2", input: 10, reactor: "ffi" }, parameters: { parameter: 10 } },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("step1")]: { block: 6, private: false },
        [createAgentName("step2")]: { block: 8, private: false },
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    // One shared transport across both actors = the handler's process survived the reset.
    let releaseStep1: (value: string) => void = () => {};
    let step2Ran = false;
    const transport = new InProcessFfiTransport({
      step1: () => new Promise<string>((resolve) => (releaseStep1 = resolve)),
      step2: () => {
        step2Ran = true;
        return "step2-done";
      },
    });

    const actorOne = makeActor(ir, persistence, transport);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (persistence.instanceCount() >= 2 ? true : undefined));

    // Warm reset: a new actor reloads from the same rows over the SAME transport. `recover(step1)` finds the
    // handler still live and leaves it alone — no error, no re-run.
    const actorTwo = makeActor(ir, persistence, transport);
    await actorTwo.activate();
    expect(step2Ran).toBe(false); // nothing moved yet — step1 is still (correctly) in flight

    // The surviving handler settles: its completion reaches the NEW actor, `main` resumes and runs step2.
    releaseStep1("step1-done");
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(step2Ran).toBe(true);
    expect(done.result).toEqual({ kind: "string", value: "step2-done" });
  });

  test("a process death fails an in-flight external at-most-once, recording the run error via Layer 1 routing", async () => {
    // agent main() { return step1({}) }   — `main` is the run root (its delegation's caller is the api
    // root, which runs no engine thread). After a crash, the run delegation's caller can only be recovered
    // from the Layer 1 delegations table. A FRESH transport (= a fresh process) cannot vouch for step1, so
    // its `recover` refuses at-most-once: the handler is never re-run, the call panics, and — unhandled —
    // the run records the error durably. Retrying is katari-level policy, never the runtime's.
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
        7: { block: { kind: "external", key: "step1", input: 8, reactor: "ffi" }, parameters: { parameter: 8 } },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("step1")]: { block: 6, private: false },
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    const first = recordingRunner({ step1: false });
    const actorOne = makeActor(ir, persistence, first.runner);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (first.dispatched.includes("step1") ? true : undefined));
    // The run delegation is durably `running` at the suspend point (its caller = the api root).
    expect(persistence.runDelegationOf(run)?.state).toBe("running");

    // Crash + recover in a fresh actor (a fresh transport = a fresh process). Recovery rebuilds the run's
    // caller purely from the delegations table; the refused call's panic bubbles out and fails the run.
    const second = recordingRunner({ step1: true });
    const actorTwo = makeActor(ir, persistence, second.runner);
    await actorTwo.activate();

    const failed = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "error" ? record : undefined;
    });
    expect(failed.errorMessage).toMatch(/interrupted by a runtime restart/);
    // The whole point of at-most-once: the handler was never re-run.
    expect(second.dispatched).toHaveLength(0);
    expect(second.recovered).toHaveLength(1);
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
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("ask_value")]: { block: 5, private: false },
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
    // C3: the engine writes the `runs` metadata row in the same commit as the run's `delegate`, so once
    // the launch batch commits (`started`) a LIVE run is durable with BOTH its metadata and its
    // delegation — never one alone. The run must still be live at the commit for the delegation row to
    // be observable (batching folds a COMPLETED run's whole routing lifecycle into the launch commit —
    // see the net-zero test below), so this fixture suspends on an unhandled request.
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
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("ask_value")]: { block: 5, private: false },
      },
      names: {},
    };
    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);
    const argument = { kind: "integer" as const, value: 3 };
    const { run, result, started } = actor.startRun(
      createAgentName("main"),
      SNAPSHOT,
      argument,
      "nightly",
    );
    void result.catch(() => {});
    await started;
    await waitUntil(() => (actor.listOpenEscalations().length > 0 ? true : undefined));

    const meta = persistence.peekRun(run);
    expect(meta?.name).toBe("nightly");
    expect(meta?.qualifiedName).toBe(createAgentName("main"));
    expect(meta?.snapshotId).toBe(SNAPSHOT);
    expect(meta?.argument).toEqual(argument);
    expect(meta?.cancelReason).toBeNull();
    // The delegation row committed with the metadata — both durable, atomically.
    expect(persistence.runDelegationOf(run)).toBeDefined();
  });

  test("a run completing within its launch batch commits ONCE, writing no routing rows (net-zero)", async () => {
    // The launch command and the whole run fold into one batch: every delegation / instance / outbox
    // row is created and torn down in memory, never touching the store. What commits is exactly the
    // permanent record — the `runs` outcome and the journal — in a single transaction.
    const persistence = new StoringPersistence();
    const actor = makeActor(constantIr(), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "integer", value: 7 });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 7 });
    expect(persistence.commitCount).toBe(1);
    expect(persistence.runDelegationOf(run)).toBeUndefined();
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
    // The journal still records every hop (the trace is complete even though the outbox saw nothing).
    expect(persistence.journalFor(run).map((event) => event.kind)).toEqual([
      "delegate",
      "delegateAck",
    ]);
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
                target: { kind: "name", name: createAgentName("prelude.add") },
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
          block: { kind: "primitive", name: "prelude.add", input: 8 },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("prelude.add")]: { block: 6, private: false },
      },
      names: {},
    };

    const persistence = new StoringPersistence();
    const actor = makeActor(ir, persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await expect(result).rejects.toThrow(/panic.*number/);
    // And the run's root instance (and its descendants) were torn down — nothing left suspended.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
    // The failure is durable on the `runs` record AND survives the teardown: failing the run sends a
    // `terminate` to its still-suspended root, whose `terminateAck` must NOT clobber the durable `error` (and
    // its message) with `cancelled`. Asserting only after full quiescence — once that terminateAck has landed —
    // is what makes this catch that regression (the run delegation row, pure live routing, was deleted on its
    // terminal, so the outcome lives on `runs` now).
    const record = persistence.peekRun(run);
    expect(record?.state).toBe("error");
    expect(record?.errorMessage).toMatch(/panic.*number/);
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
      entries: { [createAgentName("main")]: { block: 0, private: false } },
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
    const run = newInstanceId();
    const delegation = newDelegationId();
    const target = { kind: "named" as const, name: createAgentName("main"), snapshot: SNAPSHOT };
    // The run's delegation: issued by its run instance (`from: api`) to a core instance (`to: core`).
    persistence.seedDelegation(delegation, {
      caller: run,
      fromReactor: "api",
      toReactor: "core",
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
      event: {
        kind: "delegate",
        from: "api",
        to: "core",
        run,
        delegation,
        target,
        argument: null,
      },
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
    // The run's launch is already durable (a seeded delegation + outbox delegate, as after a crash); the
    // batch that RUNS it then fails its commit. The actor must not advance on that failure: it drops the
    // warm engine state, reactivates from durable (the still-unconsumed delegate replays), re-runs the
    // batch — now succeeding — and the run completes, recorded durably on the `runs` row.
    const store = new StoringPersistence();
    const run = newInstanceId();
    const delegation = newDelegationId();
    const target = { kind: "named" as const, name: createAgentName("main"), snapshot: SNAPSHOT };
    store.seedDelegation(delegation, {
      caller: run,
      fromReactor: "api",
      toReactor: "core",
    });
    store.seedRun(run, {
      name: "main",
      qualifiedName: createAgentName("main"),
      snapshotId: SNAPSHOT,
      argument: null,
    });
    store.seedOutbox({
      seq: newOutboxSeq(),
      event: {
        kind: "delegate",
        from: "api",
        to: "core",
        run,
        delegation,
        target,
        argument: null,
      },
    });
    const persistence = new FailingPersistence(store, 1);
    const actor = makeActor(constantIr(), persistence);
    await actor.activate();

    const done = await waitUntil(() => {
      const record = store.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 7 });
    // Recovery quiesced: the outbox drained and nothing is left suspended.
    await waitUntil(() => (store.outboxSize() === 0 ? true : undefined));
    expect(store.instanceCount()).toBe(0);
  });

  test("a process death cancels a dead handler's inner delegations — nothing is re-run, no orphans remain", async () => {
    // agent main() { return compute({}) }   — compute is an FFI handler that calls another FFI key
    // ("helper") through the inner agent-call channel. The first actor's helper never completes, so the
    // project persists suspended with: main + the compute call (its innerCalls bridge) + the helper call.
    // A fresh actor (a fresh process) refuses BOTH calls at-most-once: compute's error path cancels its
    // inner delegation (the would-be orphan), the panic bubbles out, and the run fails — leaving no live
    // external work behind.
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
                target: { kind: "name", name: createAgentName("compute") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: {
          block: { kind: "external", key: "compute", input: 8, reactor: "ffi" },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("compute")]: { block: 6, private: false },
      },
      names: {},
    };

    const persistence = new StoringPersistence();

    // First actor: compute suspends on an inner call to helper, which never completes.
    let helperDispatched = false;
    const firstHandlers: Record<string, FfiHandler> = {
      compute: (_argument, context) => context.call("helper", null, { reactor: "ffi" }),
      helper: () => {
        helperDispatched = true;
        return new Promise(() => {}); // never settles — the durable suspend point
      },
    };
    const actorOne = makeActor(ir, persistence, new InProcessFfiTransport(firstHandlers));
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    // The transport dispatch is strictly post-commit, so helper's dispatch means the whole suspend point —
    // main, the compute call (with its innerCalls bridge), and the helper call — is already durable.
    await waitUntil(() => (helperDispatched ? true : undefined));

    // Crash + recover with a FRESH transport (= a fresh process): neither handler is re-run — both calls
    // are refused at-most-once, and compute's failure cancels its (would-be orphan) inner delegation.
    let reRan = false;
    const secondHandlers: Record<string, FfiHandler> = {
      compute: () => {
        reRan = true;
        return "unreachable";
      },
      helper: () => {
        reRan = true;
        return "unreachable";
      },
    };
    const actorTwo = makeActor(ir, persistence, new InProcessFfiTransport(secondHandlers));
    await actorTwo.activate();

    const failed = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "error" ? record : undefined;
    });
    expect(failed.errorMessage).toMatch(/interrupted by a runtime restart/);
    expect(reRan).toBe(false);
    // No orphans: every external call — the dead compute call AND its inner helper delegation — fully
    // retired (their envelopes are gone), and the run root tore down with the failed run.
    await waitUntil(() => (persistence.envelopeCount("ffi") === 0 ? true : undefined));
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
  });
});

describe("recovery — the caller-instance (blob-hoist target) re-derivation on reload", () => {
  test("core reads the caller INSTANCE of an instance a NON-core reactor summoned, from the shared delegations SoT", async () => {
    // A core instance summoned by a webhook subscriber / mcp.serve continuation / ffi inner delegation has its
    // caller-side delegation row owned by THAT reactor, not core. Core must still re-derive its caller
    // INSTANCE (the blob-hoist target) on reload, or every later upward event silently skips the hoist and
    // the completion teardown reclaims the produced blob (a dangling ref). The SoT is
    // `delegations.caller_instance_id` for EVERY delegation; core reads the ones addressed to it (`to = core`)
    // — whoever issued them — through `loader.core.summoningDelegations()`.
    const persistence = new StoringPersistence();
    const endpointCallInstance = newInstanceId(); // a long-lived webhook / mcp serve endpoint call
    const coreParent = newInstanceId(); // an ordinary core sub-call's parent
    const webhookToCore = newDelegationId(); // the cross-reactor summon — core does NOT own the caller row
    const coreToCore = newDelegationId(); // an ordinary core sub-call — core owns this one
    const coreToFfi = newDelegationId(); // a delegation addressed elsewhere — must not leak into core's read

    await persistence.transaction(PROJECT, async (tx) => {
      await tx.base.putDelegation({
        delegation: webhookToCore,
        caller: endpointCallInstance,
        fromReactor: "webhook",
        toReactor: "core",
        state: "running",
      });
      await tx.base.putDelegation({
        delegation: coreToCore,
        caller: coreParent,
        fromReactor: "core",
        toReactor: "core",
        state: "running",
      });
      await tx.base.putDelegation({
        delegation: coreToFfi,
        caller: coreParent,
        fromReactor: "core",
        toReactor: "ffi",
        state: "running",
      });
    });

    await persistence.load(PROJECT, async (loader) => {
      const summoning = await loader.core.summoningDelegations();
      const callerOf = new Map(summoning.map((row) => [row.delegation, row.caller]));
      // The webhook→core summon: core reads its caller INSTANCE even though the caller-side row is webhook's.
      expect(callerOf.get(webhookToCore)).toBe(endpointCallInstance);
      // Its own sub-call, too — one uniform read covers both.
      expect(callerOf.get(coreToCore)).toBe(coreParent);
      // A delegation addressed to another reactor never leaks in.
      expect(callerOf.has(coreToFfi)).toBe(false);
      expect(summoning.every((row) => row.toReactor === "core")).toBe(true);

      // The regression's shape: the OLD re-derivation (`callerInstanceOf`) read only core's OWN issued rows
      // (`from = core`), which by construction cannot hold the webhook→core summon — so its caller instance
      // reloaded as `undefined`, and the hoist was silently lost across the restart.
      const ownIssued = await loader.base.delegations("core");
      expect(ownIssued.some((row) => row.delegation === webhookToCore)).toBe(false);
    });
  });
});
