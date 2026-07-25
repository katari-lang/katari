// The root-served serial domain: an unhandled `store.exclusive` reaching the run root is SERVED by the
// runtime as the OUTERMOST domain (the root workspace) — its task closure runs as a `core` delegate issued
// by the api root, serialized through a PROJECT-WIDE durable FIFO (`run_exclusive_tasks`), and the task's
// settlement answers the escalation. Two layers of tests:
//
//   - Reactor-level (the api reactor driven directly, like `api-reactor-store`): the dispatch (one section
//     at a time, FIFO order across runs), the four ack-classification guards (a task's ack is never the
//     run's terminal), failure containment (a task's panic fails ITS run only; the next section proceeds),
//     run-cancel teardown, and the durable queue as recovery SoT (a running task re-registers without a
//     re-spawn; a completed one can never double-spawn).
//   - Actor-level (a real core over `StoringPersistence`): the whole loop — perform → enqueue → spawn →
//     the task's own store writes machine-answer → the answer resumes the raiser — plus crash-replay
//     exactly-once (`FailingPersistence` at every early commit index).

import {
  createAgentName,
  type IRModule,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ApiReactor, RunCancelledError } from "../src/runtime/actor/api-reactor.js";
import type { Persistence, PersistenceTx } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { ResourcePool } from "../src/runtime/actor/resource-pool.js";
import type { StoreRows } from "../src/runtime/actor/store-responder.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { createProjectStore } from "../src/runtime/engine/store.js";
import { isUserFacingRequest } from "../src/runtime/escalation-filter.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import {
  apiRootIdOf,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newEscalationId,
  type ProjectId,
  type ScopeId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "22222222-2222-4222-8222-222222222222" as ProjectId;
const API_ROOT = apiRootIdOf(PROJECT);
const SNAPSHOT = "snapshot-exclusive" as SnapshotId;
const EXCLUSIVE = "prelude.store.exclusive";
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

const str = (value: string): Value => ({ kind: "string", value });
const record = (fields: Record<string, Value>): Value => ({ kind: "record", fields });

/** An in-memory rows port recording the order of writes (the FIFO-order witness). */
function memoryRows(): StoreRows & { table: Map<string, Value>; writes: string[] } {
  const table = new Map<string, Value>();
  const writes: string[] = [];
  return {
    table,
    writes,
    read: async (_project, key) => table.get(key),
    upsert: async (_project, key, value) => {
      writes.push(key);
      table.set(key, value);
    },
    remove: async (_project, key) => {
      table.delete(key);
    },
    listKeys: async (_project, prefix) =>
      [...table.keys()].filter((key) => prefix === "" || key.startsWith(`${prefix}/`)).sort(),
  };
}

// ─── reactor-level ────────────────────────────────────────────────────────────────────────────────

/** A synthetic task closure (never executed at this level — `dispatchCallable` only reads its fields). */
function taskClosure(blockId: number): Value {
  return {
    kind: "closure",
    blockId,
    scopeId: (100 + blockId) as ScopeId,
    snapshot: SNAPSHOT,
    module: "m",
  };
}

function harness(rows: StoreRows = memoryRows()) {
  const store = createProjectStore();
  const pool = new ResourcePool(PROJECT, store);
  const api = new ApiReactor(
    API_ROOT,
    {
      enqueue: (thunk) => {
        void thunk();
        return Promise.resolve();
      },
    },
    pool,
    PROJECT,
    rows,
  );
  /** Start a run and capture the run delegation off the launch `delegate`. */
  const startRun = (name: string) => {
    const { run, result } = api.startRun(createAgentName(name), SNAPSHOT, null, name);
    // A rejected run promise is expected in several scenarios; observe it via `outcomeOf`, never unhandled.
    result.catch(() => undefined);
    const launch = api.drainSends().find((event) => event.kind === "delegate");
    if (launch === undefined || launch.kind !== "delegate") throw new Error("no launch delegate");
    return { run, result, delegation: launch.delegation };
  };
  return { api, pool, store, startRun };
}

/** A `store.exclusive` escalate reaching the api on a run's (or a task's) delegation leg. */
function exclusiveEscalate(
  delegation: DelegationId,
  escalation: EscalationId,
  run: InstanceId,
  task: Value,
): Extract<ExternalEvent, { kind: "escalate" }> {
  return {
    kind: "escalate",
    delegation,
    escalation,
    ask: { kind: "request", request: EXCLUSIVE as QualifiedName, argument: record({ task }) },
    from: "core",
    to: "api",
    run,
  };
}

function delegateAck(
  delegation: DelegationId,
  run: InstanceId,
  value: Value,
): Extract<ExternalEvent, { kind: "delegateAck" }> {
  return { kind: "delegateAck", delegation, value, from: "core", to: "api", run };
}

function terminateAck(
  delegation: DelegationId,
  run: InstanceId,
): Extract<ExternalEvent, { kind: "terminateAck" }> {
  return { kind: "terminateAck", delegation, from: "core", to: "api", run };
}

function panicEscalate(
  delegation: DelegationId,
  run: InstanceId,
  message: string,
): Extract<ExternalEvent, { kind: "escalate" }> {
  return {
    kind: "escalate",
    delegation,
    escalation: newEscalationId(),
    ask: {
      kind: "request",
      request: "prelude.panic" as QualifiedName,
      argument: record({ msg: str(message) }),
    },
    from: "core",
    to: "api",
    run,
  };
}

/** The in-process promise's observed state after a microtask flush — pins what afterCommit settled. */
async function outcomeOf(promise: Promise<Value>): Promise<"pending" | "resolved" | "rejected"> {
  let state: "pending" | "resolved" | "rejected" = "pending";
  promise.then(
    () => {
      state = "resolved";
    },
    () => {
      state = "rejected";
    },
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return state;
}

describe("api reactor: root-served store.exclusive (reactor level)", () => {
  test("an exclusive spawns its task as an api-issued core delegate and the task's ack answers it", async () => {
    const { api, startRun } = harness();
    const r1 = startRun("main");
    const escalation = newEscalationId();

    api.react(exclusiveEscalate(r1.delegation, escalation, r1.run, taskClosure(7)));
    // Never an operator question (the escalation-filter's exclusion, applied at the dispatch).
    expect(api.listOpenEscalations()).toHaveLength(0);
    const sends = api.drainSends();
    expect(sends).toHaveLength(1);
    const spawn = sends[0];
    if (spawn?.kind !== "delegate") throw new Error("expected the task delegate");
    // Issued by the API ROOT (the base stamps the caller), routed to core, in the run's trace.
    expect(spawn.caller).toBe(API_ROOT);
    expect(spawn.to).toBe("core");
    expect(spawn.run).toBe(r1.run);
    expect(spawn.target).toMatchObject({ kind: "closure", blockId: 7 });
    expect(spawn.argument).toEqual(record({ value: { kind: "null" } }));

    // The task settles: its ack answers the exclusive down the RUN delegation — and is NOT the run's terminal.
    const ack = delegateAck(spawn.delegation, r1.run, str("task-done"));
    api.react(ack);
    const replies = api.drainSends();
    expect(replies).toHaveLength(1);
    expect(replies[0]).toMatchObject({
      kind: "escalateAck",
      delegation: r1.delegation,
      escalation,
      value: str("task-done"),
      to: "core",
    });
    // Guard: the task's delegateAck must not resolve the run's in-process promise (the run is still live).
    api.afterCommit(ack);
    expect(await outcomeOf(r1.result)).toBe("pending");
  });

  test("two runs' exclusives serialize through ONE project FIFO, in arrival order", () => {
    const { api, startRun } = harness();
    const r1 = startRun("one");
    const r2 = startRun("two");
    const e1 = newEscalationId();
    const e2 = newEscalationId();

    api.react(exclusiveEscalate(r1.delegation, e1, r1.run, taskClosure(1)));
    api.react(exclusiveEscalate(r2.delegation, e2, r2.run, taskClosure(2)));
    // Exactly ONE section holds the domain: the first task spawned, the second queued.
    const sends = api.drainSends();
    const delegates = sends.filter((event) => event.kind === "delegate");
    expect(delegates).toHaveLength(1);
    const first = delegates[0];
    if (first?.kind !== "delegate") throw new Error("expected the first task delegate");
    expect(first.target).toMatchObject({ blockId: 1 });

    // The first section's settlement answers run one AND hands the domain to run two's task.
    api.react(delegateAck(first.delegation, r1.run, str("one-done")));
    const next = api.drainSends();
    expect(next.map((event) => event.kind)).toEqual(["escalateAck", "delegate"]);
    expect(next[0]).toMatchObject({ delegation: r1.delegation, value: str("one-done") });
    const second = next[1];
    if (second?.kind !== "delegate") throw new Error("expected the second task delegate");
    expect(second.target).toMatchObject({ blockId: 2 });
    expect(second.run).toBe(r2.run);

    api.react(delegateAck(second.delegation, r2.run, str("two-done")));
    expect(api.drainSends()).toMatchObject([
      { kind: "escalateAck", delegation: r2.delegation, value: str("two-done") },
    ]);
  });

  test("a task's panic fails ITS run only; the next queued section proceeds once the teardown confirms", async () => {
    const persistence = new StoringPersistence();
    const { api, startRun } = harness();
    const r1 = startRun("one");
    const r2 = startRun("two");
    const e1 = newEscalationId();
    const e2 = newEscalationId();
    api.react(exclusiveEscalate(r1.delegation, e1, r1.run, taskClosure(1)));
    api.react(exclusiveEscalate(r2.delegation, e2, r2.run, taskClosure(2)));
    const spawn = api.drainSends().find((event) => event.kind === "delegate");
    if (spawn?.kind !== "delegate") throw new Error("expected the first task delegate");

    // The running task panics (the failure escalates under the TASK delegation, not the run's).
    const panic = panicEscalate(spawn.delegation, r1.run, "boom");
    api.react(panic);
    const sends = api.drainSends();
    // Run one fails through ITS OWN delegation and the task subtree is torn down — but the next section
    // does NOT spawn yet (the teardown fence: a dying section's tail must not overlap the next).
    expect(sends.map((event) => event.kind).sort()).toEqual(["terminate", "terminate"]);
    expect(sends).toMatchObject([
      { kind: "terminate", delegation: r1.delegation },
      { kind: "terminate", delegation: spawn.delegation },
    ]);
    await persistence.transaction(PROJECT, (tx) => api.persist(tx));
    expect(persistence.peekRun(r1.run)?.state).toBe("error");
    expect(persistence.peekRun(r1.run)?.errorMessage).toMatch(/store\.exclusive: panic: boom/);
    expect(persistence.peekRun(r2.run)?.state).toBe("running");
    // Only run two's section remains on the durable queue.
    expect(persistence.exclusiveTasks().map((task) => task.run)).toEqual([r2.run]);
    // The failed run's promise rejects with the panic, strictly post-commit; run two's stays pending.
    api.afterCommit(panic);
    expect(await outcomeOf(r1.result)).toBe("rejected");
    expect(await outcomeOf(r2.result)).toBe("pending");

    // The task teardown confirms: the fence lifts and run two's section takes the domain. Its ack must
    // NOT record `cancelled` over run one's durable `error` (the sticky-terminal guard).
    api.react(terminateAck(spawn.delegation, r1.run));
    const resumed = api.drainSends();
    expect(resumed.map((event) => event.kind)).toEqual(["delegate"]);
    expect(resumed[0]).toMatchObject({ target: { blockId: 2 }, run: r2.run });
    await persistence.transaction(PROJECT, (tx) => api.persist(tx));
    expect(persistence.peekRun(r1.run)?.state).toBe("error");
    // The run root teardown's own terminateAck is likewise a sticky no-op.
    api.react(terminateAck(r1.delegation, r1.run));
    await persistence.transaction(PROJECT, (tx) => api.persist(tx));
    expect(persistence.peekRun(r1.run)?.state).toBe("error");
  });

  test("cancelling a run tears down its queued AND running sections; the domain passes on", async () => {
    const persistence = new StoringPersistence();
    const rows = memoryRows();
    const { api, startRun } = harness(rows);
    const r1 = startRun("one");
    const r2 = startRun("two");
    const e1 = newEscalationId();
    const e1b = newEscalationId();
    const e2 = newEscalationId();
    // Run one holds the domain AND has a second section queued (a parallel block can raise several);
    // run two waits behind both.
    api.react(exclusiveEscalate(r1.delegation, e1, r1.run, taskClosure(1)));
    api.react(exclusiveEscalate(r1.delegation, e1b, r1.run, taskClosure(11)));
    api.react(exclusiveEscalate(r2.delegation, e2, r2.run, taskClosure(2)));
    const spawn = api.drainSends().find((event) => event.kind === "delegate");
    if (spawn?.kind !== "delegate") throw new Error("expected the first task delegate");

    await api.cancelRun(r1.run, "operator stop");
    const cancels = api.drainSends();
    expect(cancels).toMatchObject([{ kind: "terminate", delegation: r1.delegation }]);

    // The cancel cascade confirms: run one records `cancelled`, BOTH its sections leave the queue, its
    // running task is terminated — and run two does not spawn until that teardown confirms.
    const runAck = terminateAck(r1.delegation, r1.run);
    api.react(runAck);
    const teardown = api.drainSends();
    expect(teardown).toMatchObject([{ kind: "terminate", delegation: spawn.delegation }]);
    await persistence.transaction(PROJECT, (tx) => api.persist(tx));
    expect(persistence.peekRun(r1.run)?.state).toBe("cancelled");
    expect(persistence.exclusiveTasks().map((task) => task.run)).toEqual([r2.run]);
    api.afterCommit(runAck);
    await expect(r1.result).rejects.toThrow(RunCancelledError);

    // The task teardown confirms: the domain passes to run two. The ack records nothing for run one.
    api.react(terminateAck(spawn.delegation, r1.run));
    expect(api.drainSends()).toMatchObject([{ kind: "delegate", target: { blockId: 2 } }]);
    await persistence.transaction(PROJECT, (tx) => api.persist(tx));
    expect(persistence.peekRun(r1.run)?.state).toBe("cancelled");
  });

  test("recovery: a RUNNING task re-registers (no re-spawn), a QUEUED one keeps its place; a completed one never double-spawns", async () => {
    const persistence = new StoringPersistence();
    const first = harness();
    const r1 = first.startRun("one");
    const r2 = first.startRun("two");
    const e1 = newEscalationId();
    const e2 = newEscalationId();
    first.api.react(exclusiveEscalate(r1.delegation, e1, r1.run, taskClosure(1)));
    first.api.react(exclusiveEscalate(r2.delegation, e2, r2.run, taskClosure(2)));
    const spawn = first.api.drainSends().find((event) => event.kind === "delegate");
    if (spawn?.kind !== "delegate") throw new Error("expected the first task delegate");
    await persistence.transaction(PROJECT, (tx) => first.api.persist(tx));
    expect(persistence.exclusiveTasks()).toMatchObject([
      { run: r1.run, taskDelegation: spawn.delegation },
      { run: r2.run, taskDelegation: null },
    ]);

    // Restart: the queue is the SoT. The running head re-registers its delegation — NO delegate is
    // re-produced (its instance resumes as durable core work) — and the queued section stays queued.
    const second = harness();
    await persistence.load(PROJECT, (loader) => second.api.load(loader));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(second.api.drainSends()).toEqual([]);

    // The recovered running task settles: its exclusive answers, and the queued section takes the domain.
    second.api.react(delegateAck(spawn.delegation, r1.run, str("one-done")));
    const resumed = second.api.drainSends();
    expect(resumed.map((event) => event.kind)).toEqual(["escalateAck", "delegate"]);
    expect(resumed[0]).toMatchObject({ delegation: r1.delegation, escalation: e1 });
    const secondSpawn = resumed[1];
    if (secondSpawn?.kind !== "delegate") throw new Error("expected the second task delegate");
    await persistence.transaction(PROJECT, (tx) => second.api.persist(tx));
    expect(persistence.exclusiveTasks().map((task) => task.run)).toEqual([r2.run]);

    // Complete the second section too, then restart once more: an EMPTY durable queue spawns nothing —
    // the completed-section double-spawn regression.
    second.api.react(delegateAck(secondSpawn.delegation, r2.run, str("two-done")));
    second.api.drainSends();
    await persistence.transaction(PROJECT, (tx) => second.api.persist(tx));
    expect(persistence.exclusiveTasks()).toEqual([]);
    const third = harness();
    await persistence.load(PROJECT, (loader) => third.api.load(loader));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(third.api.drainSends()).toEqual([]);
  });

  test("an exclusive raised from INSIDE a critical section fails the section (a nested domain would deadlock)", async () => {
    const persistence = new StoringPersistence();
    const { api, startRun } = harness();
    const r1 = startRun("one");
    api.react(exclusiveEscalate(r1.delegation, newEscalationId(), r1.run, taskClosure(1)));
    const spawn = api.drainSends().find((event) => event.kind === "delegate");
    if (spawn?.kind !== "delegate") throw new Error("expected the task delegate");

    // The running task performs `store.exclusive` itself — it would queue behind its own raiser forever.
    api.react(exclusiveEscalate(spawn.delegation, newEscalationId(), r1.run, taskClosure(9)));
    const sends = api.drainSends();
    expect(sends).toMatchObject([
      { kind: "terminate", delegation: r1.delegation },
      { kind: "terminate", delegation: spawn.delegation },
    ]);
    await persistence.transaction(PROJECT, (tx) => api.persist(tx));
    expect(persistence.peekRun(r1.run)?.state).toBe("error");
    expect(persistence.peekRun(r1.run)?.errorMessage).toMatch(/nested exclusive/);
    expect(persistence.exclusiveTasks()).toEqual([]);
  });

  test("the escalation filter never surfaces store.exclusive as user-facing", () => {
    expect(isUserFacingRequest("prelude.store.exclusive")).toBe(false);
    // The four KV operations stay machine-answered, and genuine capabilities stay answerable.
    expect(isUserFacingRequest("prelude.store.get")).toBe(false);
    expect(isUserFacingRequest("myapp.ask_operator")).toBe(true);
  });
});

// ─── actor-level (a real core engine over StoringPersistence) ─────────────────────────────────────

/** A `Persistence` that throws on its `nth` commit (the crash), delegating everything else to the inner
 *  twin — the same shape `recovery.test.ts` uses, so the exclusive path exercises poison → drop →
 *  reactivate at an arbitrary commit boundary. */
class FailingPersistence implements Persistence {
  private commits = 0;
  constructor(
    private readonly inner: StoringPersistence,
    private readonly failOnCommit: number,
  ) {}
  load(projectId: ProjectId, body: Parameters<Persistence["load"]>[1]) {
    return this.inner.load(projectId, body);
  }
  async transaction(
    projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    this.commits += 1;
    if (this.commits === this.failOnCommit) throw new Error("injected commit failure");
    await this.inner.transaction(projectId, body);
  }
}

function makeActor(ir: IRModule, persistence: Persistence, rows: StoreRows): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    persistence,
    storeRows: rows,
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

/** agent main() { store.exclusive(task = closure) } — the closure writes `counter` and returns "task-done".
 *  The store operations perform through their request wrappers (what a compiled perform delegates to). */
function exclusiveProgram(): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeClosure", agent: 6, output: 10 },
            { kind: "makeRecord", entries: [["task", 10]], output: 11 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName(EXCLUSIVE) },
              argument: 11,
              output: 12,
            },
            { kind: "exit", target: 0, value: 12 },
          ],
        },
        parameters: { parameter: 90 },
      },
      2: { block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      3: {
        block: { kind: "request", name: createAgentName(EXCLUSIVE), input: 30 },
        parameters: { parameter: 30 },
      },
      4: { block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      5: {
        block: { kind: "request", name: createAgentName("prelude.store.set"), input: 50 },
        parameters: { parameter: 50 },
      },
      // The task closure: store.set(key = "counter", value = 1); "task-done".
      6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
      7: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 71, value: { kind: "string", value: "counter" } },
            { kind: "loadLiteral", output: 72, value: { kind: "integer", value: 1 } },
            {
              kind: "makeRecord",
              entries: [
                ["key", 71],
                ["value", 72],
              ],
              output: 73,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.store.set") },
              argument: 73,
              output: 74,
            },
            { kind: "loadLiteral", output: 75, value: { kind: "string", value: "task-done" } },
            { kind: "exit", target: 6, value: 75 },
          ],
        },
        parameters: { parameter: 70 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName(EXCLUSIVE)]: { block: 2, private: false },
      [createAgentName("prelude.store.set")]: { block: 4, private: false },
    },
    names: {},
  };
}

/** The same program with a task that PANICS (a string fed to the add prim) before any write. */
function panickingProgram(): IRModule {
  const program = exclusiveProgram();
  program.blocks[7] = {
    block: {
      kind: "sequence",
      result: null,
      operations: [
        { kind: "loadLiteral", output: 71, value: { kind: "integer", value: 1 } },
        { kind: "loadLiteral", output: 72, value: { kind: "string", value: "x" } },
        {
          kind: "makeRecord",
          entries: [
            ["left", 71],
            ["right", 72],
          ],
          output: 73,
        },
        {
          kind: "delegate",
          target: { kind: "name", name: createAgentName("prelude.add") },
          argument: 73,
          output: 74,
        },
        { kind: "exit", target: 6, value: 74 },
      ],
    },
    parameters: { parameter: 70 },
  };
  program.blocks[8] = {
    block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, defaults: {} },
    parameters: {},
  };
  program.blocks[9] = {
    block: { kind: "primitive", name: "prelude.add", input: 95 },
    parameters: { parameter: 95 },
  };
  program.entries[createAgentName("prelude.add")] = { block: 8, private: false };
  return program;
}

describe("root-served store.exclusive (actor level)", () => {
  test("perform → enqueue → spawn → the task's store write machine-answers → the answer resumes the run", async () => {
    const rows = memoryRows();
    const persistence = new StoringPersistence();
    const actor = makeActor(exclusiveProgram(), persistence, rows);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The run's result IS the critical section's answer, crossed back over the escalateAck.
    await expect(result).resolves.toEqual(str("task-done"));
    expect(rows.table.get("counter")).toEqual({ kind: "integer", value: 1 });
    // Quiescence: the queue drained, no escalation row leaked, every engine instance retired.
    await waitUntil(() => (persistence.outboxSize() === 0 ? true : undefined));
    expect(persistence.exclusiveTasks()).toEqual([]);
    expect(persistence.escalationCount()).toBe(0);
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
    expect(persistence.peekRun(run)?.state).toBe("done");
  });

  test("a panicking task fails its run with the panic, and nothing leaks", async () => {
    const rows = memoryRows();
    const persistence = new StoringPersistence();
    const actor = makeActor(panickingProgram(), persistence, rows);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The in-process rejection carries the panic itself; the durable outcome carries the domain prefix.
    await expect(result).rejects.toThrow(/panic/);
    await waitUntil(() => (persistence.outboxSize() === 0 ? true : undefined));
    expect(persistence.peekRun(run)?.state).toBe("error");
    expect(persistence.peekRun(run)?.errorMessage).toMatch(/store\.exclusive: panic/);
    expect(persistence.exclusiveTasks()).toEqual([]);
    expect(persistence.escalationCount()).toBe(0);
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
  });

  test("a crash at ANY post-launch commit replays to the same answer, and the section runs exactly once", async () => {
    // Failing each commit AFTER the launch (a failed launch turn is a rejected command, not a replay —
    // its thunk is one-shot) sweeps the enqueue, spawn, store-answer and settle boundaries: the actor
    // poisons, drops its warm state, reactivates from the durable rows (the queue is the SoT) and
    // replays — to the SAME durable outcome, the section never re-running after its completion committed.
    for (let failAt = 2; failAt <= 6; failAt++) {
      const rows = memoryRows();
      const inner = new StoringPersistence();
      const actor = makeActor(exclusiveProgram(), new FailingPersistence(inner, failAt), rows);
      const { run, result, started } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
      const settled = await result.then(
        (value) => ({ value }),
        (error: unknown) => ({ error }),
      );
      await started.catch(() => undefined);
      // A poisoned in-process promise is allowed (the run continues durably); the durable outcome is not.
      await waitUntil(() => (inner.peekRun(run)?.state === "done" ? true : undefined));
      await waitUntil(() => (inner.outboxSize() === 0 ? true : undefined));
      expect(rows.table.get("counter")).toEqual({ kind: "integer", value: 1 });
      expect(inner.exclusiveTasks()).toEqual([]);
      if ("value" in settled) expect(settled.value).toEqual(str("task-done"));
    }
  });
});
