// End-to-end tests for the built-in `region` reactor, driven through the whole ProjectActor (an in-runtime
// nursery scheduler — no transport). This wave covers `prelude.region.provide` only, the SCOPED provider: the
// reactor mints a `nursery` handle carrying its provide scope identity, dispatches the CONTINUATION as one
// inner delegation with `{ value: nursery }`, and settles the whole call with the continuation's outcome. A
// provide survives a restart completely (like `webhook` / `time`) — its scope re-registers and its
// continuation resumes as durable core work — since there is no external process to reconcile.

import {
  createAgentName,
  type IRModule,
  type Operation,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence, type Persistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import {
  decodeRegionExtension,
  type RegionExtension,
} from "../src/runtime/actor/region-reactor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-region" as ProjectId;
const SNAPSHOT = "snapshot-region" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

// agent main() {
//   region.provide(continuation = continuation)   // region.provide[scope, E, R, Eouter](continuation)
// }
// agent continuation(value) { <continuationOperations> }   // dispatched with { value: nursery }
// agent ask_value(input) { <request> }   // an unhandled request the recovery test suspends the run on
//
// The continuation's body is the one axis the tests vary; ask_value is always present (unused by the tests
// that do not escalate).
function provideIr(continuationOperations: Operation[]): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: {
        block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadAgent", output: 11, name: createAgentName("continuation") },
            { kind: "makeRecord", entries: [["continuation", 11]], output: 12 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.provide") },
              argument: 12,
              output: 13,
            },
            { kind: "exit", target: 0, value: 13 },
          ],
        },
        parameters: { parameter: 10 },
      },
      2: {
        block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      3: {
        block: { kind: "external", key: "prelude.region.provide", input: 30, reactor: "region" },
        parameters: { parameter: 30 },
      },
      // continuation: receives { value: nursery } and runs the test's chosen body.
      6: {
        block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      7: {
        block: { kind: "sequence", result: null, operations: continuationOperations },
        parameters: { parameter: 60 },
      },
      // ask_value: an unhandled request, so its escalation suspends the run at the run root (recovery test).
      8: {
        block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      9: {
        block: { kind: "request", name: createAgentName("ask_value"), input: 90 },
        parameters: { parameter: 90 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.region.provide")]: { block: 2, private: false },
      [createAgentName("continuation")]: { block: 6, private: false },
      [createAgentName("ask_value")]: { block: 8, private: false },
    },
    names: {},
  };
}

function makeActor(
  ir: IRModule,
  persistence: Persistence = new InMemoryPersistence(),
  blobs: InMemoryBlobStore = new InMemoryBlobStore(),
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs,
    external: new StubFfiTransport(),
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

/** `waitUntil` for an async probe — the durable-buffer reads below poll the persistence, which is async. */
async function eventually<T>(probe: () => Promise<T | undefined>): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = await probe();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("eventually: the probe never held");
}

// A richer IR than `provideIr`: it wires `prelude.region.fork` alongside `provide`, two request-agents
// (`ask_value` to HOLD an agent open on an unanswered escalation, `fiber_ask` for a fiber's own escalation),
// and a `task` agent a `fork` runs. The continuation's body, the task's body, and — for the escaped-nursery
// case — `main`'s body are the axes the tests vary.
//
//   agent main()                         { region.provide(continuation) }     // or: provide then fork (escaped)
//   agent continuation(value)            { <continuation ops> }               // dispatched with { value: nursery }
//   agent task(input)                    { <task ops> }                       // the fiber body a fork runs
//   agent ask_value(input) / fiber_ask(input) { <request> }                   // unhandled holds / fiber escalations
//
// It also wires `prelude.region.join` (so a continuation can await a fiber) and a fixed CLOSURE agent (block
// 16, returning the captured variable 121) that the resource-reown test's task builds with `makeClosure` — a
// fiber returning a scope-capturing closure, to prove a join carries the fiber's resources across.
function forkIr(bodies: {
  continuation: Operation[];
  task: Operation[];
  main?: Operation[];
}): IRModule {
  const main: Operation[] = bodies.main ?? [
    { kind: "loadAgent", output: 101, name: createAgentName("continuation") },
    { kind: "makeRecord", entries: [["continuation", 101]], output: 102 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.provide") },
      argument: 102,
      output: 103,
    },
    { kind: "exit", target: 0, value: 103 },
  ];
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: {
        block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      1: {
        block: { kind: "sequence", result: null, operations: main },
        parameters: { parameter: 100 },
      },
      2: {
        block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      3: {
        block: { kind: "external", key: "prelude.region.provide", input: 30, reactor: "region" },
        parameters: { parameter: 30 },
      },
      4: {
        block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      5: {
        block: { kind: "external", key: "prelude.region.fork", input: 50, reactor: "region" },
        parameters: { parameter: 50 },
      },
      6: {
        block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      7: {
        block: { kind: "sequence", result: null, operations: bodies.continuation },
        parameters: { parameter: 60 },
      },
      8: {
        block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      9: {
        block: { kind: "request", name: createAgentName("ask_value"), input: 90 },
        parameters: { parameter: 90 },
      },
      10: {
        block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      11: {
        block: { kind: "request", name: createAgentName("fiber_ask"), input: 110 },
        parameters: { parameter: 110 },
      },
      12: {
        block: { kind: "agent", body: 13, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      13: {
        block: { kind: "sequence", result: null, operations: bodies.task },
        parameters: { parameter: 120 },
      },
      14: {
        block: { kind: "agent", body: 15, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      15: {
        block: { kind: "external", key: "prelude.region.join", input: 150, reactor: "region" },
        parameters: { parameter: 150 },
      },
      // A closure agent the resource-reown task returns via `makeClosure`: its body returns variable 121, the
      // value the task captured from its own scope, so calling it hands back the captured value.
      16: {
        block: { kind: "agent", body: 17, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      17: {
        block: {
          kind: "sequence",
          result: null,
          operations: [{ kind: "exit", target: 16, value: 121 }],
        },
        parameters: { parameter: 170 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.region.provide")]: { block: 2, private: false },
      [createAgentName("prelude.region.fork")]: { block: 4, private: false },
      [createAgentName("prelude.region.join")]: { block: 14, private: false },
      [createAgentName("continuation")]: { block: 6, private: false },
      [createAgentName("ask_value")]: { block: 8, private: false },
      [createAgentName("fiber_ask")]: { block: 10, private: false },
      [createAgentName("task")]: { block: 12, private: false },
    },
    names: {},
  };
}

/** A continuation body: fork `task` with `argument`, then HOLD on an unanswered `ask_value` so the provide
 *  stays alive while the fiber runs; the provide settles with the hold's eventual answer. */
function forkThenHold(argument: string): Operation[] {
  return [
    { kind: "getField", source: 60, field: "value", output: 61 },
    { kind: "loadAgent", output: 62, name: createAgentName("task") },
    { kind: "loadLiteral", output: 63, value: { kind: "string", value: argument } },
    {
      kind: "makeRecord",
      entries: [
        ["nursery", 61],
        ["task", 62],
        ["argument", 63],
      ],
      output: 64,
    },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.fork") },
      argument: 64,
      output: 65,
    },
    { kind: "makeRecord", entries: [], output: 66 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("ask_value") },
      argument: 66,
      output: 67,
    },
    { kind: "exit", target: 6, value: 67 },
  ];
}

/** A task body that surfaces its argument: escalate its whole `{ input }` argument record as `fiber_ask`
 *  (which relays up through the provide to the run root), returning the answer. A fiber blocked here stays
 *  running. The argument is forwarded as the record it arrives in (a `fork` hands `task` `{ input: <arg> }`),
 *  so it crosses the agent boundary unchanged. */
const askingTask: Operation[] = [
  {
    kind: "delegate",
    target: { kind: "name", name: createAgentName("fiber_ask") },
    argument: 120,
    output: 122,
  },
  { kind: "exit", target: 12, value: 122 },
];

/** A task body that settles at once with a constant — a fiber whose outcome the provide buffers. */
const returningTask: Operation[] = [
  { kind: "loadLiteral", output: 121, value: { kind: "string", value: "fiber-done" } },
  { kind: "exit", target: 12, value: 121 },
];

/** A task body that returns its OWN argument (`{ input }.input`) — so a `join` observes exactly the value the
 *  `fork` passed, proving the argument → fiber → join round trip. */
const echoTask: Operation[] = [
  { kind: "getField", source: 120, field: "input", output: 121 },
  { kind: "exit", target: 12, value: 121 },
];

/** A task body that returns a scope-capturing CLOSURE: it reads its argument into its scope (variable 121),
 *  then `makeClosure`s the fixed closure agent (block 16), whose body returns that captured variable. The
 *  fiber's result thus carries a resource (the captured scope); a `join` must hand it across to the join's
 *  caller intact, so calling the returned closure yields the captured value. */
const closureTask: Operation[] = [
  { kind: "getField", source: 120, field: "input", output: 121 },
  { kind: "makeClosure", output: 122, agent: 16 },
  { kind: "exit", target: 12, value: 122 },
];

/** A continuation body: fork @task@ with @argument@, then `join` the fiber and return its settled value. The
 *  join awaits through the buffer or a waiter depending on whether the fiber has landed yet. */
function forkThenJoin(argument: string): Operation[] {
  return [
    { kind: "getField", source: 60, field: "value", output: 61 },
    { kind: "loadAgent", output: 62, name: createAgentName("task") },
    { kind: "loadLiteral", output: 63, value: { kind: "string", value: argument } },
    {
      kind: "makeRecord",
      entries: [
        ["nursery", 61],
        ["task", 62],
        ["argument", 63],
      ],
      output: 64,
    },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.fork") },
      argument: 64,
      output: 65,
    },
    {
      kind: "makeRecord",
      entries: [
        ["nursery", 61],
        ["handle", 65],
      ],
      output: 66,
    },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.join") },
      argument: 66,
      output: 67,
    },
    { kind: "exit", target: 6, value: 67 },
  ];
}

/** The persisted `join` extension rows, decoded — a test confirms a join's call is durable (so a restart will
 *  reload it and re-park its waiter) before crossing the restart boundary. */
async function peekRegionJoins(
  persistence: StoringPersistence,
): Promise<Array<Extract<RegionExtension, { kind: "join" }>>> {
  const joins: Array<Extract<RegionExtension, { kind: "join" }>> = [];
  await persistence.load(PROJECT, async (loader) => {
    for (const row of await loader.external.instances("region")) {
      const extension = decodeRegionExtension(row.extension);
      if (extension.kind === "join") joins.push(extension);
    }
  });
  return joins;
}

/** The persisted `provide` extension rows, decoded — how a test reads a nursery's durable fiber buffer the
 *  way a restart would reload it (unsealed through the loader). */
async function peekRegionProvides(
  persistence: StoringPersistence,
): Promise<Array<Extract<RegionExtension, { kind: "provide" }>>> {
  const provides: Array<Extract<RegionExtension, { kind: "provide" }>> = [];
  await persistence.load(PROJECT, async (loader) => {
    for (const row of await loader.external.instances("region")) {
      const extension = decodeRegionExtension(row.extension);
      if (extension.kind === "provide") provides.push(extension);
    }
  });
  return provides;
}

describe("region reactor", () => {
  test("provide hands its continuation a nursery token carrying the scope identity, and settles with the continuation's result", async () => {
    // The continuation returns the nursery handle it received, so the run resolves with it — proving both
    // that the continuation ran (the whole call settles with its outcome) and that the nursery carries this
    // provide's scope identity.
    const actor = makeActor(
      provideIr([
        { kind: "getField", source: 60, field: "value", output: 61 },
        { kind: "exit", target: 6, value: 61 },
      ]),
    );
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const value = await result;
    if (value.kind !== "record") throw new Error("expected the nursery record");
    const scope = value.fields.$katari_region_scope;
    if (scope === undefined || scope.kind !== "string") {
      throw new Error("the nursery must carry a string scope identity");
    }
    expect(scope.value).toMatch(/^regionscope:/);
  });

  test("region.provide settles with the continuation's literal result", async () => {
    // The continuation ignores the nursery and returns a constant; the provide's result IS that constant.
    const actor = makeActor(
      provideIr([
        { kind: "loadLiteral", output: 61, value: { kind: "string", value: "done" } },
        { kind: "exit", target: 6, value: 61 },
      ]),
    );
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "string", value: "done" });
  });

  test("a running provide is restored across a restart and resumes when its continuation is answered", async () => {
    // The continuation escalates the unhandled `ask_value` request and returns its answer. The escalation
    // bubbles through the region provide (its base relays a child's ask upward) to the run root, suspending
    // the run — the durable state a restart must recover: the provide's scope + its continuation resuming as
    // durable core work, and the relayed open escalation.
    const persistence = new StoringPersistence();
    const ir = provideIr([
      { kind: "makeRecord", entries: [], output: 61 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("ask_value") },
        argument: 61,
        output: 62,
      },
      { kind: "exit", target: 6, value: 62 },
    ]);

    const actorOne = makeActor(ir, persistence);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    // Drive to the suspend point: the run is open on the unhandled `ask_value` request, relayed up through
    // the live region provide.
    await waitUntil(() => (actorOne.listOpenEscalations().length > 0 ? true : undefined));

    // Restart: a fresh actor over the same rows. The provide re-registers its scope and its continuation
    // resumes as durable core work (consumed at its original dispatch — never re-dispatched); the relayed
    // open escalation rehydrates from its persisted row so the fresh actor can list and answer it.
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const open = await waitUntil(() => {
      const list = actorTwo.listOpenEscalations();
      return list.length > 0 ? list : undefined;
    });
    expect(open).toHaveLength(1);
    expect(open[0]?.request).toBe(createAgentName("ask_value"));

    // Answering it resumes the continuation, which returns the answer; the region provide settles with that
    // outcome, and the run completes with it — recorded durably as the run's `done` result.
    const escalation = open[0]?.escalation;
    if (escalation === undefined) throw new Error("no recovered open escalation");
    await actorTwo.answerEscalation(escalation, { kind: "string", value: "answered" });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "answered" });
    expect(actorTwo.listOpenEscalations()).toHaveLength(0);
  });

  test("fork spawns the task as a separate fiber and delivers its argument", async () => {
    // The continuation forks `task` (which re-escalates its `.input` as `fiber_ask`) then holds. The fiber
    // runs as its OWN instance under the provide, so its escalation wells up at the run root carrying the
    // exact argument the fork passed — proving both that a separate fiber ran and that the argument reached it.
    const actor = makeActor(forkIr({ continuation: forkThenHold("delivered"), task: askingTask }));
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const fiberAsk = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    );
    expect(fiberAsk.argument).toEqual({
      kind: "record",
      fields: { input: { kind: "string", value: "delivered" } },
    });
  });

  test("independent forks each spawn their own fiber", async () => {
    // The continuation forks `task` twice with distinct arguments, then holds. Both fibers run independently,
    // so two distinct `fiber_ask` escalations surface at the root — one per forked argument.
    const twoForks: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "alpha" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      { kind: "loadLiteral", output: 66, value: { kind: "string", value: "beta" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 66],
        ],
        output: 67,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 67,
        output: 68,
      },
      { kind: "makeRecord", entries: [], output: 69 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("ask_value") },
        argument: 69,
        output: 70,
      },
      { kind: "exit", target: 6, value: 70 },
    ];
    const actor = makeActor(forkIr({ continuation: twoForks, task: askingTask }));
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const asks = await waitUntil(() => {
      const found = actor
        .listOpenEscalations()
        .filter((open) => open.request === createAgentName("fiber_ask"));
      return found.length >= 2 ? found : undefined;
    });
    const arguments_ = asks.map((ask) => {
      const input = ask.argument?.kind === "record" ? ask.argument.fields.input : undefined;
      return input?.kind === "string" ? input.value : null;
    });
    expect(new Set(arguments_)).toEqual(new Set(["alpha", "beta"]));
  });

  test("a fiber's escalation relays through the provide to the run root, and its answer returns to the fiber", async () => {
    // The fiber escalates `fiber_ask` and returns the answer. The escalation relays up through the provide
    // (the base's relay bridge) to the run root; answering it descends the same path back DOWN to the fiber,
    // which then settles — and its outcome is buffered on the provide (nothing has joined it), carrying the
    // answer that made the full round trip.
    const persistence = new StoringPersistence();
    const actor = makeActor(
      forkIr({ continuation: forkThenHold("q"), task: askingTask }),
      persistence,
    );
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const fiberAsk = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    );
    await actor.answerEscalation(fiberAsk.escalation, { kind: "string", value: "the-answer" });

    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence)).find(
        (extension) => extension.fiberBuffer.length > 0,
      );
      return provide?.fiberBuffer;
    });
    expect(buffered).toHaveLength(1);
    expect(buffered[0]?.outcome).toEqual({
      kind: "result",
      value: { kind: "string", value: "the-answer" },
    });
  });

  test("a settled fiber's outcome is buffered durably on the provide and survives a restart", async () => {
    // The fiber settles at once with a constant while the continuation holds. Its outcome is buffered on the
    // provide's durable extension — a restart restores it, and the provide, resumed as durable core work,
    // still settles with the CONTINUATION's answer (not the buffered fiber's), proving the buffer neither
    // settled the call early nor was lost.
    const persistence = new StoringPersistence();
    const ir = forkIr({ continuation: forkThenHold("held"), task: returningTask });
    const actorOne = makeActor(ir, persistence);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);

    const beforeRestart = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence)).find(
        (extension) => extension.fiberBuffer.length > 0,
      );
      return provide?.fiberBuffer;
    });
    expect(beforeRestart[0]?.outcome).toEqual({
      kind: "result",
      value: { kind: "string", value: "fiber-done" },
    });

    // Restart: a fresh actor over the same rows re-registers the scope, resumes the held continuation, and
    // reloads the fiber buffer intact from the provide extension.
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const afterRestart = await peekRegionProvides(persistence);
    expect(afterRestart[0]?.fiberBuffer[0]?.outcome).toEqual({
      kind: "result",
      value: { kind: "string", value: "fiber-done" },
    });

    // Answering the continuation's hold settles the provide with the CONTINUATION's value; the fiber's
    // buffered outcome is discarded as the provide drops (no join took it this wave).
    const hold = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("ask_value")),
    );
    await actorTwo.answerEscalation(hold.escalation, { kind: "string", value: "continuation-value" });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "continuation-value" });
  });

  test("forking into a scope whose provide has already returned is refused", async () => {
    // `main` keeps the nursery the provide returned and forks it AFTER the block closed — a dead-scope fork
    // the type checker prevents (it discharges `Scope` at the provide), so the runtime backstop is a panic:
    // `fork`'s row declares no throw, and region has no error sum. The run fails with the closed-scope panic.
    const escapedMain: Operation[] = [
      { kind: "loadAgent", output: 101, name: createAgentName("continuation") },
      { kind: "makeRecord", entries: [["continuation", 101]], output: 102 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.provide") },
        argument: 102,
        output: 103,
      },
      { kind: "loadAgent", output: 104, name: createAgentName("task") },
      { kind: "loadLiteral", output: 105, value: { kind: "string", value: "late" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 103],
          ["task", 104],
          ["argument", 105],
        ],
        output: 106,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 106,
        output: 107,
      },
      { kind: "exit", target: 0, value: 107 },
    ];
    // The continuation returns the nursery it was handed, so the provide settles (and closes the scope)
    // before `main` reaches the fork.
    const returnNursery: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "exit", target: 6, value: 61 },
    ];
    const actor = makeActor(
      forkIr({ main: escapedMain, continuation: returnNursery, task: returningTask }),
    );
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/region\.fork.*has closed/);
  });

  test("a fiber still running when the provide returns leaks no resources", async () => {
    // The continuation forks a fiber that blocks on `fiber_ask`, then returns a constant AT ONCE. The provide
    // settles with that constant, and its cancel cascade tears the still-running fiber down (the structured-
    // concurrency teardown the base supplies) — so the run finishes with the continuation's value and leaves
    // no live instance, scope, or region call behind.
    const persistence = new StoringPersistence();
    const forkThenReturn: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "orphan" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      { kind: "loadLiteral", output: 66, value: { kind: "string", value: "closed-clean" } },
      { kind: "exit", target: 6, value: 66 },
    ];
    const actor = makeActor(forkIr({ continuation: forkThenReturn, task: askingTask }), persistence);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await expect(result).resolves.toEqual({ kind: "string", value: "closed-clean" });
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
  });

  test("join drains a fiber's buffered outcome and returns it", async () => {
    // The continuation forks a fiber that settles AT ONCE, then holds on `ask_value` — held open until the
    // test confirms the fiber's outcome is buffered — before joining. So the join provably drains the DURABLE
    // buffer (the fiber landed first), and returns the fiber's value as the whole run's result.
    const persistence = new StoringPersistence();
    const forkHoldThenJoin: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "arg" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      // Hold until the test answers, so the fiber has settled into the buffer before the join runs.
      { kind: "makeRecord", entries: [], output: 66 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("ask_value") },
        argument: 66,
        output: 67,
      },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["handle", 65],
        ],
        output: 68,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.join") },
        argument: 68,
        output: 69,
      },
      { kind: "exit", target: 6, value: 69 },
    ];
    const actor = makeActor(
      forkIr({ continuation: forkHoldThenJoin, task: returningTask }),
      persistence,
    );
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // Wait for the fiber to buffer AND the continuation to be holding on `ask_value`.
    const hold = await waitUntil(() => {
      const buffered = actor.listOpenEscalations().find(
        (open) => open.request === createAgentName("ask_value"),
      );
      return buffered;
    });
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence)).find(
        (extension) => extension.fiberBuffer.length > 0,
      );
      return provide?.fiberBuffer;
    });

    // Release the hold: the continuation joins, drains the buffered outcome, and returns it.
    await actor.answerEscalation(hold.escalation, { kind: "null" });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "fiber-done" });
    // A drained buffer leaves the nursery empty, and the whole run quiesces with nothing live behind it.
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
  });

  test("join before a fiber settles parks a waiter that the fiber's completion resumes", async () => {
    // The continuation forks a fiber that BLOCKS on `fiber_ask`, then joins it at once — so the join is parked
    // as a waiter (the fiber is still running, nothing is buffered). Answering the fiber's escalation lets it
    // settle, which resumes the waiting join directly (never buffered), and the run returns the fiber's value.
    const actor = makeActor(forkIr({ continuation: forkThenJoin("q"), task: askingTask }));
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const fiberAsk = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    );
    await actor.answerEscalation(fiberAsk.escalation, { kind: "string", value: "waited-answer" });
    await expect(result).resolves.toEqual({ kind: "string", value: "waited-answer" });
  });

  test("a fiber's returned value round-trips through join to its caller", async () => {
    // The fiber returns its own forked argument; join hands exactly that value back to the continuation, which
    // returns it — proving the argument → fiber → join value path (whether it drains a buffer or a waiter).
    const actor = makeActor(forkIr({ continuation: forkThenJoin("payload"), task: echoTask }));
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "string", value: "payload" });
  });

  test("a join waiting on a running fiber re-parks across a restart and resumes when the fiber settles", async () => {
    // The continuation forks a fiber blocked on `fiber_ask` and joins it (parking a waiter). A restart loses
    // the in-memory waiter, but the provide reload rebuilds its running-fiber set from the durable inner-call
    // bridges and the reloaded join re-parks against it. Answering the fiber then settles the join, so the run
    // completes with the fiber's value — the whole join round trip surviving the restart.
    const persistence = new StoringPersistence();
    const ir = forkIr({ continuation: forkThenJoin("resume"), task: askingTask });
    const actorOne = makeActor(ir, persistence);
    const { run } = actorOne.startRun(createAgentName("main"), SNAPSHOT, null);

    // Drive to the parked point: the fiber is running (its `fiber_ask` is open) and the join's call is durable.
    await waitUntil(() =>
      actorOne.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    );
    await eventually(async () => {
      const joins = await peekRegionJoins(persistence);
      return joins.length > 0 ? joins : undefined;
    });

    // Restart: a fresh actor over the same rows. The provide rebuilds its running fiber, and the reloaded join
    // re-parks its waiter against it.
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const fiberAsk = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    );
    await actorTwo.answerEscalation(fiberAsk.escalation, { kind: "string", value: "post-restart" });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "post-restart" });
  });

  test("joining the same fiber twice panics on the second join", async () => {
    // The continuation forks a returning fiber, joins it (single-consumer — the first join takes the outcome),
    // then joins the SAME handle again. The second join finds the fiber neither buffered nor running, so it
    // panics — `join`'s row declares no throw and region has no error sum, so a not-joinable handle (here a
    // double join) is an engine-invariant backstop, failing the run.
    const doubleJoin: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "once" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["handle", 65],
        ],
        output: 66,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.join") },
        argument: 66,
        output: 67,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.join") },
        argument: 66,
        output: 68,
      },
      { kind: "exit", target: 6, value: 68 },
    ];
    const actor = makeActor(forkIr({ continuation: doubleJoin, task: returningTask }));
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/region\.join.*not joinable/);
  });

  test("a resource the joined fiber returns reaches the join's caller and leaks nothing", async () => {
    // The fiber returns a scope-capturing closure; the continuation joins it and CALLS the returned closure,
    // which yields the value the fiber captured — so the join carried the fiber's resource (its captured scope)
    // across intact to the join's caller. The run resolves with the captured value, and quiesces with no live
    // instance, scope, or region call behind it (nothing dangled or leaked in the hand-off).
    const persistence = new StoringPersistence();
    const forkJoinCall: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "captured" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["handle", 65],
        ],
        output: 66,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.join") },
        argument: 66,
        output: 67,
      },
      // Call the joined closure: if its captured scope crossed the join intact, this yields "captured".
      { kind: "makeRecord", entries: [], output: 68 },
      { kind: "delegate", target: { kind: "value", variable: 67 }, argument: 68, output: 69 },
      { kind: "exit", target: 6, value: 69 },
    ];
    const actor = makeActor(forkIr({ continuation: forkJoinCall, task: closureTask }), persistence);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await expect(result).resolves.toEqual({ kind: "string", value: "captured" });
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
  });
});
