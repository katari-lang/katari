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
  canceller?: Operation[];
}): IRModule {
  // A `canceller` fiber body (wave 5): defaults to a no-op fiber. The cancel tests override it with a body that
  // gates on a request then cancels a handle it was forked with (to panic a join parked concurrently).
  const canceller: Operation[] = bodies.canceller ?? [
    { kind: "loadLiteral", output: 221, value: { kind: "null" } },
    { kind: "exit", target: 22, value: 221 },
  ];
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
      // fiber_report: the fiber's own value-carrying escalation — the observable of a settled fiber's
      // work, now that a settled value is discarded (results ride escalations).
      14: {
        block: { kind: "agent", body: 15, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      15: {
        block: { kind: "request", name: createAgentName("fiber_report"), input: 150 },
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
      // prelude.region.cancel (wave 5): tears one fiber down early, routed by its handle.
      18: {
        block: { kind: "agent", body: 19, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      19: {
        block: { kind: "external", key: "prelude.region.cancel", input: 180, reactor: "region" },
        parameters: { parameter: 180 },
      },
      // hold2: a second holding request (distinct from ask_value), so a continuation can hold AFTER a cancel to
      // keep its nursery alive while a test observes the cancelled fiber's instance is gone.
      20: {
        block: { kind: "agent", body: 21, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      21: {
        block: { kind: "request", name: createAgentName("hold2"), input: 200 },
        parameters: { parameter: 200 },
      },
      // canceller: a fiber body a continuation forks alongside a worker — the parked-join-cancel test overrides
      // it to gate then cancel the worker's handle (its `{ input }` argument carries `{ nursery, handle }`).
      22: {
        block: { kind: "agent", body: 23, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      23: {
        block: { kind: "sequence", result: null, operations: canceller },
        parameters: { parameter: 220 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.region.provide")]: { block: 2, private: false },
      [createAgentName("prelude.region.fork")]: { block: 4, private: false },
      [createAgentName("fiber_report")]: { block: 14, private: false },
      [createAgentName("prelude.region.cancel")]: { block: 18, private: false },
      [createAgentName("continuation")]: { block: 6, private: false },
      [createAgentName("ask_value")]: { block: 8, private: false },
      [createAgentName("fiber_ask")]: { block: 10, private: false },
      [createAgentName("task")]: { block: 12, private: false },
      [createAgentName("hold2")]: { block: 20, private: false },
      [createAgentName("canceller")]: { block: 22, private: false },
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
  // Report the answer as a SECOND escalation: a fiber's settled value is discarded (results ride
  // escalations), so the report is how a test observes the round trip.
  { kind: "makeRecord", entries: [["value", 122]], output: 124 },
  {
    kind: "delegate",
    target: { kind: "name", name: createAgentName("fiber_report") },
    argument: 124,
    output: 123,
  },
  { kind: "exit", target: 12, value: 122 },
];

/** A task body that reports a constant and settles — the report escalation is the observable (a
 *  settled value is discarded). */
const returningTask: Operation[] = [
  { kind: "loadLiteral", output: 121, value: { kind: "string", value: "fiber-done" } },
  { kind: "makeRecord", entries: [["value", 121]], output: 124 },
  {
    kind: "delegate",
    target: { kind: "name", name: createAgentName("fiber_report") },
    argument: 124,
    output: 123,
  },
  { kind: "exit", target: 12, value: 121 },
];

/** A task body that SETTLES AT ONCE, escalating nothing — so it retires the instant it is forked, with no
 *  buffered escalation to service (a fiber that escalates would block forever with no watch to answer it). */
const settlingTask: Operation[] = [
  { kind: "loadLiteral", output: 121, value: { kind: "null" } },
  { kind: "exit", target: 12, value: 121 },
];


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

// The WATCH IR — the white-hole shape. `main` opens a nursery; the `continuation` binds the nursery (variable
// 61) and enters a `handle` (block 14) that catches `on_message`. The handle's protected BODY (block 15) forks
// a worker fiber and then calls `region.watch(r)` — so a worker's `on_message` escalation, which would relay UP
// through the provide in a watch-less region, is INTERCEPTED and re-emitted at the watch, where the handle
// catches it. The worker body, the handle body, and the handler body are the axes the tests vary.
//
//   agent main()                  { region.provide(continuation) }
//   agent continuation(value)     { r = value.value; handle { <handle body> } with on_message(m) { <handler> } }
//   agent worker(input)           { <worker ops> }                 // a fiber the handle body forks
//   agent on_message(input)       { request on_message }           // the fiber's escalation, re-emitted at watch
//   region.provide / fork / watch wrappers + external leaves
function watchIr(bodies?: {
  worker?: Operation[];
  handleBody?: Operation[];
  handler?: Operation[];
}): IRModule {
  // Default worker: escalate `on_message` with its own argument, and return the answer (so a watch's handler
  // answer round-trips back and the fiber's outcome — the answer — buffers on the provide).
  const worker: Operation[] = bodies?.worker ?? [
    { kind: "getField", source: 110, field: "input", output: 111 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("on_message") },
      argument: 111,
      output: 112,
    },
    // Report the answer back up — a settled value is discarded, so the report is the observable.
    { kind: "makeRecord", entries: [["value", 112]], output: 119 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("fiber_report") },
      argument: 119,
      output: 118,
    },
    { kind: "exit", target: 10, value: 112 },
  ];
  // Default handle body: fork one worker with a fixed argument, then watch the nursery forever. `r` is the
  // continuation's variable 61, visible here through the lexical scope chain (handle body → handle → continuation).
  const handleBody: Operation[] = bodies?.handleBody ?? [
    { kind: "loadAgent", output: 150, name: createAgentName("worker") },
    { kind: "loadLiteral", output: 151, value: { kind: "string", value: "arg" } },
    {
      kind: "makeRecord",
      entries: [
        ["nursery", 61],
        ["task", 150],
        ["argument", 151],
      ],
      output: 152,
    },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.fork") },
      argument: 152,
      output: 153,
    },
    { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.watch") },
      argument: 154,
      output: 155,
    },
    { kind: "exit", target: 14, value: 155 },
  ];
  // Default handler: answer the re-emitted request with a fixed value (a `next`, resuming the fiber).
  const handler: Operation[] = bodies?.handler ?? [
    { kind: "loadLiteral", output: 161, value: { kind: "string", value: "answered" } },
    { kind: "continue", target: 14, value: 161, modifiers: [] },
  ];
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
            { kind: "loadAgent", output: 101, name: createAgentName("continuation") },
            { kind: "makeRecord", entries: [["continuation", 101]], output: 102 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.provide") },
              argument: 102,
              output: 103,
            },
            { kind: "exit", target: 0, value: 103 },
          ],
        },
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
      // continuation: bind the nursery (61), then enter the handle scope (its result is the continuation's).
      7: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 60, field: "value", output: 61 },
            { kind: "call", target: 14, output: 62 },
            { kind: "exit", target: 6, value: 62 },
          ],
        },
        parameters: { parameter: 60 },
      },
      8: {
        block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      9: {
        block: { kind: "request", name: createAgentName("on_message"), input: 90 },
        parameters: { parameter: 90 },
      },
      10: {
        block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      11: {
        block: { kind: "sequence", result: null, operations: worker },
        parameters: { parameter: 110 },
      },
      12: {
        block: { kind: "agent", body: 13, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      13: {
        block: { kind: "external", key: "prelude.region.watch", input: 130, reactor: "region" },
        parameters: { parameter: 130 },
      },
      // The handle: run the fork+watch body, catch on_message, no then-clause.
      14: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 15,
          handlers: [{ request: createAgentName("on_message"), body: 16 }],
          thenClause: null,
        },
        parameters: {},
      },
      15: {
        block: { kind: "sequence", result: null, operations: handleBody },
        parameters: {},
      },
      16: {
        block: { kind: "sequence", result: null, operations: handler },
        parameters: { parameter: 160 },
      },
      // fiber_report: the fiber's own value-carrying escalation — the observable of a settled fiber's
      // work (a settled value is discarded). Unhandled by the handle, so it relays to the run root.
      // Numbered HIGH (40/41): several tests append their own blocks at 17/18 on top of this module.
      40: {
        block: { kind: "agent", body: 41, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      41: {
        block: { kind: "request", name: createAgentName("fiber_report"), input: 410 },
        parameters: { parameter: 410 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.region.provide")]: { block: 2, private: false },
      [createAgentName("prelude.region.fork")]: { block: 4, private: false },
      [createAgentName("prelude.region.watch")]: { block: 12, private: false },
      [createAgentName("continuation")]: { block: 6, private: false },
      [createAgentName("on_message")]: { block: 8, private: false },
      [createAgentName("worker")]: { block: 10, private: false },
      [createAgentName("fiber_report")]: { block: 40, private: false },
    },
    names: {},
  };
}

/** Augment a module with the registry-facing region agents the roster / cancel-by-id / crashed tests use:
 *  the `prelude.region.roster` and `prelude.region.cancel_by_id` external wrappers, the `prelude.array.range`
 *  prim (a deterministic PANIC source — a range over the materialisation ceiling throws a plain error), and
 *  a `panicker` task that trips it, so a fiber's crash carries a knowable message. Blocks live at 50+ so
 *  they never collide with `forkIr` / `watchIr` or the per-test appended blocks. */
function withRegistryAgents(ir: IRModule): IRModule {
  ir.blocks[50] = {
    block: { kind: "agent", body: 51, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[51] = {
    block: { kind: "external", key: "prelude.region.roster", input: 500, reactor: "region" },
    parameters: { parameter: 500 },
  };
  ir.blocks[52] = {
    block: { kind: "agent", body: 53, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[53] = {
    block: { kind: "external", key: "prelude.region.cancel_by_id", input: 520, reactor: "region" },
    parameters: { parameter: 520 },
  };
  ir.blocks[54] = {
    block: { kind: "agent", body: 55, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[55] = {
    block: { kind: "primitive", name: "prelude.array.range", input: 540 },
    parameters: { parameter: 540 },
  };
  ir.blocks[56] = {
    block: { kind: "agent", body: 57, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[57] = {
    block: {
      kind: "sequence",
      result: null,
      operations: [
        { kind: "loadLiteral", output: 561, value: { kind: "integer", value: 0 } },
        { kind: "loadLiteral", output: 562, value: { kind: "integer", value: 20000000 } },
        {
          kind: "makeRecord",
          entries: [
            ["start", 561],
            ["end", 562],
          ],
          output: 563,
        },
        {
          kind: "delegate",
          target: { kind: "name", name: createAgentName("prelude.array.range") },
          argument: 563,
          output: 564,
        },
        { kind: "exit", target: 56, value: 564 },
      ],
    },
    parameters: { parameter: 560 },
  };
  ir.entries[createAgentName("prelude.region.roster")] = { block: 50, private: false };
  ir.entries[createAgentName("prelude.region.cancel_by_id")] = { block: 52, private: false };
  ir.entries[createAgentName("prelude.array.range")] = { block: 54, private: false };
  ir.entries[createAgentName("panicker")] = { block: 56, private: false };
  return ir;
}

/** Augment a module with the `prelude.throw` wrapper a compiled raise delegates to (its agent entry + the
 *  request leaf), plus a `thrower` task that raises `{ error: { message } }` through it — so a fiber can end
 *  on an UNCAUGHT typed throw with a knowable payload, the `failed` counterpart of `withRegistryAgents`'
 *  `panicker`. Blocks live at 58+ so they never collide with `watchIr` (0-16, 40/41), `withRegistryAgents`
 *  (50-57), `withGate` (17/18) or the per-test appended blocks. */
function withThrowingAgents(ir: IRModule): IRModule {
  ir.blocks[58] = {
    block: { kind: "agent", body: 59, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[59] = {
    block: { kind: "request", name: createAgentName("prelude.throw"), input: 580 },
    parameters: { parameter: 580 },
  };
  ir.blocks[60] = {
    block: { kind: "agent", body: 61, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[61] = {
    block: {
      kind: "sequence",
      result: null,
      operations: raiseThrowOperations("upstream refused", 600, 60),
    },
    parameters: { parameter: 609 },
  };
  ir.entries[createAgentName("prelude.throw")] = { block: 58, private: false };
  ir.entries[createAgentName("thrower")] = { block: 60, private: false };
  return ir;
}

/** The operations a compiled `prelude.throw(error = <ctor>(message = ...))` lowers to: build the payload
 *  record, wrap it as the request's `{ error }` argument, and delegate to the `prelude.throw` wrapper. The
 *  raise diverges, so the trailing `exit` is unreachable — it is there only to make the sequence well-formed. */
function raiseThrowOperations(message: string, base: number, exitTarget: number): Operation[] {
  return [
    { kind: "loadLiteral", output: base + 1, value: { kind: "string", value: message } },
    { kind: "makeRecord", entries: [["message", base + 1]], output: base + 2 },
    { kind: "makeRecord", entries: [["error", base + 2]], output: base + 3 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.throw") },
      argument: base + 3,
      output: base + 4,
    },
    { kind: "exit", target: exitTarget, value: base + 4 },
  ];
}

/** Augment a `watchIr` module with the `gate` request agent — an unhandled hold the DELAYED-watch bodies below
 *  park on so a test can pause the continuation with NO watch registered yet (it surfaces at the run root). */
function withGate(ir: IRModule): IRModule {
  ir.blocks[17] = {
    block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[18] = {
    block: { kind: "request", name: createAgentName("gate"), input: 180 },
    parameters: { parameter: 180 },
  };
  ir.entries[createAgentName("gate")] = { block: 17, private: false };
  return ir;
}

/** A `watchIr` handle body that forks @task@ (applied to @argument@, with optional @name@), HOLDS on the
 *  unhandled `gate` request — so a test can pause here while NO watch is registered and the forked fiber's
 *  escalation sits BUFFERED — and only THEN watches. The delayed-watch shape exercising the pre-registration
 *  buffer and the M2-6 startup race. Pair with `withGate`. */
function forkHoldThenWatch(options: { task: string; argument: string; name?: string }): Operation[] {
  const forkEntries: Array<[string, number]> = [
    ["nursery", 61],
    ["task", 150],
    ["argument", 151],
  ];
  const ops: Operation[] = [
    { kind: "loadAgent", output: 150, name: createAgentName(options.task) },
    { kind: "loadLiteral", output: 151, value: { kind: "string", value: options.argument } },
  ];
  if (options.name !== undefined) {
    ops.push({ kind: "loadLiteral", output: 149, value: { kind: "string", value: options.name } });
    forkEntries.push(["name", 149]);
  }
  ops.push(
    { kind: "makeRecord", entries: forkEntries, output: 152 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.fork") },
      argument: 152,
      output: 153,
    },
    { kind: "makeRecord", entries: [], output: 156 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("gate") },
      argument: 156,
      output: 157,
    },
    { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
    {
      kind: "delegate",
      target: { kind: "name", name: createAgentName("prelude.region.watch") },
      argument: 154,
      output: 155,
    },
    { kind: "exit", target: 14, value: 155 },
  );
  return ops;
}

// The CROSS-HANDLER CONCURRENCY shape: two DESKS, each its own sequential handler, around ONE nursery + watch.
// An OUTER handle catches `desk_a`, its body is an INNER handle that catches `desk_b`, and the inner body forks
// two workers (A first, then B) and `watch`es. `desk_a` bubbles PAST the inner handle (not its request) to the
// outer; `desk_b` is caught at the inner — so the two desks are independent sequential handlers. Worker A's
// handler blocks on the unhandled `gate_a`; worker B's answers at once. This proves a blocked desk does not
// starve another under the white-hole watch (the OLD one-relay-at-a-time watch would stall B behind A).
//
//   agent main()              { region.provide(continuation) }
//   agent continuation(value) { r = value.value; <outer handle (block 20)> }
//   outer handle              catches desk_a -> handler_a (holds gate_a); body = <inner handle (block 24)>
//   inner handle              catches desk_b -> handler_b (answers at once); body = fork A, fork B, watch(r)
//   agent worker_a/worker_b   escalate desk_a/desk_b, then report "a-served"/"b-served"
function concurrentDesksIr(): IRModule {
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
            { kind: "loadAgent", output: 101, name: createAgentName("continuation") },
            { kind: "makeRecord", entries: [["continuation", 101]], output: 102 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.provide") },
              argument: 102,
              output: 103,
            },
            { kind: "exit", target: 0, value: 103 },
          ],
        },
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
      // continuation: bind the nursery (61), then enter the OUTER handle (block 20).
      6: {
        block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      7: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 60, field: "value", output: 61 },
            { kind: "call", target: 20, output: 62 },
            { kind: "exit", target: 6, value: 62 },
          ],
        },
        parameters: { parameter: 60 },
      },
      8: {
        block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      9: {
        block: { kind: "request", name: createAgentName("desk_a"), input: 90 },
        parameters: { parameter: 90 },
      },
      10: {
        block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      11: {
        block: { kind: "request", name: createAgentName("desk_b"), input: 110 },
        parameters: { parameter: 110 },
      },
      12: {
        block: { kind: "agent", body: 13, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      13: {
        block: { kind: "external", key: "prelude.region.watch", input: 130, reactor: "region" },
        parameters: { parameter: 130 },
      },
      14: {
        block: { kind: "agent", body: 15, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      15: {
        block: { kind: "request", name: createAgentName("gate_a"), input: 150 },
        parameters: { parameter: 150 },
      },
      16: {
        block: { kind: "agent", body: 17, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      17: {
        block: { kind: "request", name: createAgentName("fiber_report"), input: 170 },
        parameters: { parameter: 170 },
      },
      // worker_a: escalate desk_a, then report "a-served".
      18: {
        block: { kind: "agent", body: 19, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      19: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 190 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("desk_a") },
              argument: 190,
              output: 191,
            },
            { kind: "loadLiteral", output: 192, value: { kind: "string", value: "a-served" } },
            { kind: "makeRecord", entries: [["value", 192]], output: 193 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("fiber_report") },
              argument: 193,
              output: 194,
            },
            { kind: "exit", target: 18, value: 191 },
          ],
        },
        parameters: { parameter: 180 },
      },
      // The OUTER handle: catches desk_a, its body is the INNER handle.
      20: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 21,
          handlers: [{ request: createAgentName("desk_a"), body: 22 }],
          thenClause: null,
        },
        parameters: {},
      },
      21: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "call", target: 24, output: 210 },
            { kind: "exit", target: 20, value: 210 },
          ],
        },
        parameters: {},
      },
      // handler_a: HOLD on the unhandled gate_a (human latency), then answer desk_a.
      22: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 220 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("gate_a") },
              argument: 220,
              output: 221,
            },
            { kind: "loadLiteral", output: 222, value: { kind: "string", value: "a-answered" } },
            { kind: "continue", target: 20, value: 222, modifiers: [] },
          ],
        },
        parameters: { parameter: 225 },
      },
      // The INNER handle: catches desk_b, its body forks the workers and watches.
      24: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 25,
          handlers: [{ request: createAgentName("desk_b"), body: 26 }],
          thenClause: null,
        },
        parameters: {},
      },
      25: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadAgent", output: 250, name: createAgentName("worker_a") },
            { kind: "loadLiteral", output: 251, value: { kind: "string", value: "x" } },
            {
              kind: "makeRecord",
              entries: [
                ["nursery", 61],
                ["task", 250],
                ["argument", 251],
              ],
              output: 252,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.fork") },
              argument: 252,
              output: 253,
            },
            { kind: "loadAgent", output: 254, name: createAgentName("worker_b") },
            {
              kind: "makeRecord",
              entries: [
                ["nursery", 61],
                ["task", 254],
                ["argument", 251],
              ],
              output: 255,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.fork") },
              argument: 255,
              output: 256,
            },
            { kind: "makeRecord", entries: [["nursery", 61]], output: 257 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.watch") },
              argument: 257,
              output: 258,
            },
            { kind: "exit", target: 24, value: 258 },
          ],
        },
        parameters: {},
      },
      // handler_b: answer desk_b at once.
      26: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 260, value: { kind: "string", value: "b-answered" } },
            { kind: "continue", target: 24, value: 260, modifiers: [] },
          ],
        },
        parameters: { parameter: 265 },
      },
      // worker_b: escalate desk_b, then report "b-served".
      30: {
        block: { kind: "agent", body: 31, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      31: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 310 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("desk_b") },
              argument: 310,
              output: 311,
            },
            { kind: "loadLiteral", output: 312, value: { kind: "string", value: "b-served" } },
            { kind: "makeRecord", entries: [["value", 312]], output: 313 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("fiber_report") },
              argument: 313,
              output: 314,
            },
            { kind: "exit", target: 30, value: 311 },
          ],
        },
        parameters: { parameter: 300 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.region.provide")]: { block: 2, private: false },
      [createAgentName("prelude.region.fork")]: { block: 4, private: false },
      [createAgentName("prelude.region.watch")]: { block: 12, private: false },
      [createAgentName("continuation")]: { block: 6, private: false },
      [createAgentName("desk_a")]: { block: 8, private: false },
      [createAgentName("desk_b")]: { block: 10, private: false },
      [createAgentName("gate_a")]: { block: 14, private: false },
      [createAgentName("fiber_report")]: { block: 16, private: false },
      [createAgentName("worker_a")]: { block: 18, private: false },
      [createAgentName("worker_b")]: { block: 30, private: false },
    },
    names: {},
  };
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
    // The continuation forks `task` (which re-escalates its `.input` as `fiber_ask`) then holds. The fiber runs
    // as its OWN instance under the provide and escalates — but with no watch installed the escalation surfaces
    // NOWHERE at the run root; it lands in the nursery's durable mailbox, carrying the exact argument the fork
    // passed. Reading it back proves both that a separate fiber ran and that the argument reached it.
    const persistence = new StoringPersistence();
    const actor = makeActor(
      forkIr({ continuation: forkThenHold("delivered"), task: askingTask }),
      persistence,
    );
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    const ask = buffered.mailbox[0]?.ask;
    if (ask?.kind !== "request") throw new Error("the buffered entry must be a request");
    expect(ask.request).toEqual(createAgentName("fiber_ask"));
    expect(ask.argument).toEqual({
      kind: "record",
      fields: { input: { kind: "string", value: "delivered" } },
    });
    // With no watch, the fiber's escalation never reaches the run root — it stays buffered.
    expect(
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    ).toBeUndefined();
  });

  test("independent forks each spawn their own fiber", async () => {
    // The continuation forks `task` twice with distinct arguments, then holds. Both fibers run independently,
    // so two distinct `fiber_ask` escalations land in the nursery's durable mailbox (no watch, so neither
    // reaches the run root) — one per forked argument.
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
    const persistence = new StoringPersistence();
    const actor = makeActor(forkIr({ continuation: twoForks, task: askingTask }), persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length >= 2 ? provide : undefined;
    });
    const arguments_ = buffered.mailbox.map((entry) => {
      const argument = entry.ask.kind === "request" ? entry.ask.argument : null;
      const input = argument?.kind === "record" ? argument.fields.input : undefined;
      return input?.kind === "string" ? input.value : null;
    });
    expect(new Set(arguments_)).toEqual(new Set(["alpha", "beta"]));
    // Neither fiber's escalation reached the run root.
    expect(
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    ).toBeUndefined();
  });

  test("a watch-less fiber's escalation is buffered on the provide, never surfacing at the run root", async () => {
    // The semantic inversion of the old flush-up: the fiber escalates `fiber_ask`, but with NO watch registered
    // the escalation has nowhere to surface. The provide's declared row is `R with Eouter | io` — the fibers'
    // `E` is NOT in it — so relaying the ask up to the run root would leak a request the nursery never promised.
    // Instead it is HELD in the nursery's durable mailbox (length 1), while the continuation's OWN hold
    // (`ask_value`) surfaces at the run root as usual. No watch ever registers here, so the ask stays buffered
    // for good — it never appears among the run's open escalations.
    const persistence = new StoringPersistence();
    const actor = makeActor(
      forkIr({ continuation: forkThenHold("q"), task: askingTask }),
      persistence,
    );
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The continuation's own hold surfaces at the run root (proof the run is live and progressing).
    await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("ask_value")),
    );
    // The fiber's escalation lands in the provide's durable mailbox instead of at the run root.
    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    expect(buffered.mailbox).toHaveLength(1);
    const ask = buffered.mailbox[0]?.ask;
    expect(ask?.kind === "request" ? ask.request : null).toEqual(createAgentName("fiber_ask"));
    // It never surfaces at the run root — a watch-less nursery no longer flushes up.
    expect(
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    ).toBeUndefined();
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

  test("cancel tears a running fiber's instance down while the nursery stays alive", async () => {
    // The continuation forks a fiber that BLOCKS on `fiber_ask`, holds on gate1 (so the fiber is provably
    // running), cancels the fiber, then holds on gate2 (so the provide is still ALIVE while we observe). The
    // cancelled fiber's core instance is torn down — its live-instance count drops — even though the nursery
    // did not return: proof the cancel itself (not the provide's teardown) stopped the fiber's execution.
    const persistence = new StoringPersistence();
    const forkGate1CancelGate2: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "worker" } },
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
      // gate1: hold while the worker fiber is running, so the test can sample the live-instance count WITH it.
      { kind: "makeRecord", entries: [], output: 66 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("ask_value") },
        argument: 66,
        output: 67,
      },
      // Cancel the still-running worker fiber.
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
        target: { kind: "name", name: createAgentName("prelude.region.cancel") },
        argument: 68,
        output: 69,
      },
      // gate2: hold AFTER the cancel, so the provide is still alive while the test samples the count WITHOUT it.
      { kind: "makeRecord", entries: [], output: 70 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("hold2") },
        argument: 70,
        output: 71,
      },
      { kind: "exit", target: 6, value: 71 },
    ];
    const actor = makeActor(
      forkIr({ continuation: forkGate1CancelGate2, task: askingTask }),
      persistence,
    );
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The worker fiber is running (its `fiber_ask` sits buffered in the mailbox, since no watch is installed)
    // and the continuation holds on gate1 (`ask_value`, at the run root).
    const gate1 = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("ask_value")),
    );
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? true : undefined;
    });
    const withFiber = persistence.instanceCount();

    // Release gate1: the continuation cancels the worker, then holds on gate2. The cancel settles `null` only
    // after the fiber's teardown confirms, so by the time gate2 is up the fiber's instance is gone.
    await actor.answerEscalation(gate1.escalation, { kind: "null" });
    await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("hold2")),
    );
    const withoutFiber = await waitUntil(() =>
      persistence.instanceCount() < withFiber ? persistence.instanceCount() : undefined,
    );
    expect(withoutFiber).toBeLessThan(withFiber);

    // Releasing gate2 lets the whole run finish; nothing leaks behind the cancelled fiber.
    const gate2 = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("hold2")),
    );
    await actor.answerEscalation(gate2.escalation, { kind: "string", value: "done" });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "done" });
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
    await expect(result).resolves.toEqual({ kind: "string", value: "done" });
  });

  test("cancelling an already-settled fiber is an idempotent no-op that still succeeds", async () => {
    // The continuation forks a fiber that settles AT ONCE (escalating nothing, so it retires with no watch to
    // service it), holds until the fiber has retired, then cancels the now-settled fiber. The cancel finds
    // nothing running — an idempotent no-op — yet still succeeds with `null`, and the continuation returns a
    // constant the run resolves with.
    const persistence = new StoringPersistence();
    const forkHoldCancelReturn: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "x" } },
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
        target: { kind: "name", name: createAgentName("prelude.region.cancel") },
        argument: 68,
        output: 69,
      },
      { kind: "loadLiteral", output: 70, value: { kind: "string", value: "cancel-noop" } },
      { kind: "exit", target: 6, value: 70 },
    ];
    const actor = makeActor(
      forkIr({ continuation: forkHoldCancelReturn, task: settlingTask }),
      persistence,
    );
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // Let the fiber settle first: wait for its retirement (the provide's inner-call bridges shrink back to
    // just the continuation's) before releasing the hold that drives the cancel of the now-gone fiber.
    const hold = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("ask_value")),
    );
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.innerCalls.length === 1 ? true : undefined;
    });
    await actor.answerEscalation(hold.escalation, { kind: "null" });

    await expect(result).resolves.toEqual({ kind: "string", value: "cancel-noop" });
    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({ kind: "string", value: "cancel-noop" });
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
  });

  test("cancelling a forged fiber handle (an unknown scope) panics", async () => {
    // The `cancel` twin of the forged-join case: a forged handle whose scope names no live nursery is refused
    // as a panic, automatically rejecting the hostile-wire handle.
    const cancelForged: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadLiteral", output: 62, value: { kind: "string", value: "regionscope:forged" } },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "fiber:forged" } },
      {
        kind: "makeRecord",
        entries: [
          ["$katari_region_scope", 62],
          ["$katari_region_fiber", 63],
        ],
        output: 64,
      },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["handle", 64],
        ],
        output: 65,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.cancel") },
        argument: 65,
        output: 66,
      },
      { kind: "exit", target: 6, value: 66 },
    ];
    const actor = makeActor(forkIr({ continuation: cancelForged, task: returningTask }));
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).rejects.toThrow(/region\.cancel.*not cancellable/);
  });

  test("watch re-emits a fiber's escalation at the handler installed around it, whose answer returns to the fiber", async () => {
    // The white hole, end to end: the handle body forks a worker that escalates `on_message`, then watches. The
    // worker's escalation does NOT relay up through the provide (the handle wraps only the WATCH, not the
    // sibling worker) — `watch` intercepts it and re-emits it AT the watch, where the handle catches it. The
    // handler answers "answered", which descends back to the worker; the worker returns it, and its outcome
    // buffers on the provide. So a buffered "answered" proves the whole fiber → watch → handler → fiber round
    // trip: without the interception the handle would never have seen `on_message` at all.
    const persistence = new StoringPersistence();
    const actor = makeActor(watchIr(), persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "answered" });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("a fiber that escalates before watch is called accumulates in the mailbox and is re-emitted", async () => {
    // The mailbox's "溜まっていた" requirement: the handle body forks the worker (which escalates `on_message`)
    // BEFORE calling watch, so the escalation reaches the reactor before the watch registers. It is held in the
    // nursery mailbox (not flushed up), and re-emitted once the watch — registered later in the same batch —
    // claims it. Observed the same way as the round trip: the answer reaching the worker proves the escalation
    // was held for the watch rather than escaping. (The default IR already forks-then-watches; this test names
    // the guarantee explicitly, and asserts the mailbox drains to empty once serviced.)
    const persistence = new StoringPersistence();
    const actor = makeActor(watchIr(), persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The report escalation appearing means the mailboxed `on_message` was serviced; the mailbox is
    // then drained back to empty (the report itself rides the watch's outstanding relay, not the box).
    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 0 ? true : undefined;
    });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("a fiber's escalation waits, buffered, for a watch registered arbitrarily late — no run-root leak (M2-6)", async () => {
    // The startup race M2-6 closes. A worker escalates `on_message` the instant it is forked, but the nursery's
    // watch is installed only LATER — here after a human-latency `gate` hold answers. With the quiescence
    // flush-up gone, the escalation is NOT misrouted to the run root during the gap: `listOpenEscalations` never
    // shows it, and the durable mailbox holds it (length 1). Once the gate answers and the watch registers, the
    // buffered `on_message` re-emits at the handler, whose answer descends to the worker; its report proves the
    // round trip — the exact sequence that used to deterministically mis-flush to an operator interview.
    const persistence = new StoringPersistence();
    const actor = makeActor(
      withGate(watchIr({ handleBody: forkHoldThenWatch({ task: "worker", argument: "q" }) })),
      persistence,
    );
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The continuation is parked on `gate` (no watch yet); the worker's escalation sits buffered.
    await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    expect(buffered.mailbox).toHaveLength(1);
    expect(
      actor.listOpenEscalations().find((open) => open.request === createAgentName("on_message")),
    ).toBeUndefined();

    // Answer the gate: the watch registers and drains the buffered escalation to the handler.
    const gate = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await actor.answerEscalation(gate.escalation, { kind: "null" });
    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "answered" });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("a buffered escalation with no watch survives a restart, and a late watch drains it", async () => {
    // The pre-watch twin of the watch+restart durability test: a worker escalates into a nursery with NO watch
    // yet (the continuation parked on `gate`), so it sits in the durable mailbox. A fresh actor over the same
    // rows reloads that buffered escalation with STILL no watch; answering the gate then installs the watch,
    // which drains the reloaded backlog to the handler — the answer descends to the worker AFTER the restart,
    // proving the buffer is durable across a crash even before any watch exists.
    const persistence = new StoringPersistence();
    const ir = withGate(watchIr({ handleBody: forkHoldThenWatch({ task: "worker", argument: "q" }) }));

    const actorOne = makeActor(ir, persistence);
    actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() =>
      actorOne.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    const before = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    expect(before.mailbox).toHaveLength(1);

    // Restart: the buffered escalation reloads; with no watch reloaded, nothing drains it yet.
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const after = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    expect(after.mailbox).toHaveLength(1);

    // Answer the gate on the fresh actor → the watch registers → the reloaded backlog drains → the worker
    // round-trips after the restart.
    const gate = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await actorTwo.answerEscalation(gate.escalation, { kind: "null" });
    const report = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "answered" });
    await actorTwo.answerEscalation(report.escalation, { kind: "null" });
  });

  test("cancelling a fiber whose escalation is still buffered drops the entry — a late watch gets nothing", async () => {
    // A worker escalates `on_message` into a watch-less nursery, so it sits buffered. The continuation then
    // CANCELS that worker before any watch registers: `dropFiberMailbox` removes its queued escalation, so the
    // mailbox empties. A watch installed afterward finds nothing to re-emit — the cancelled fiber's request
    // never reaches a handler.
    const persistence = new StoringPersistence();
    const handleBody: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "victim" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "makeRecord", entries: [], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("gate") },
        argument: 154,
        output: 155,
      },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["handle", 153],
        ],
        output: 156,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.cancel") },
        argument: 156,
        output: 157,
      },
      { kind: "makeRecord", entries: [], output: 158 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("gate2") },
        argument: 158,
        output: 159,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 160 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 160,
        output: 161,
      },
      { kind: "exit", target: 14, value: 161 },
    ];
    const ir = withGate(watchIr({ handleBody }));
    // The cancel wrapper and a second gate (`gate2`) the body pauses on after the cancel.
    ir.blocks[30] = {
      block: { kind: "agent", body: 31, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[31] = {
      block: { kind: "external", key: "prelude.region.cancel", input: 300, reactor: "region" },
      parameters: { parameter: 300 },
    };
    ir.blocks[32] = {
      block: { kind: "agent", body: 33, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[33] = {
      block: { kind: "request", name: createAgentName("gate2"), input: 320 },
      parameters: { parameter: 320 },
    };
    ir.entries[createAgentName("prelude.region.cancel")] = { block: 30, private: false };
    ir.entries[createAgentName("gate2")] = { block: 32, private: false };

    const actor = makeActor(ir, persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // Pause 1: the worker's escalation is buffered (mailbox length 1) while the body holds on `gate`.
    const gate = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? true : undefined;
    });

    // Answer `gate`: the body cancels the worker (dropping its buffered entry), then holds on `gate2`.
    await actor.answerEscalation(gate.escalation, { kind: "null" });
    const gate2 = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate2")),
    );
    const dropped = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 0 ? provide : undefined;
    });
    expect(dropped.mailbox).toHaveLength(0);

    // Answer `gate2`: the watch registers with an empty mailbox, so it re-emits nothing — the cancelled
    // fiber's request never reaches a handler and no report ever surfaces.
    await actor.answerEscalation(gate2.escalation, { kind: "null" });
    for (let tick = 0; tick < 50; tick += 1) await new Promise((resolve) => setTimeout(resolve, 0));
    expect(
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    ).toBeUndefined();
    const settled = (await peekRegionProvides(persistence))[0];
    expect(settled?.mailbox).toHaveLength(0);
  });

  test("an escalation arriving after a watch drops re-buffers, and a re-registered watch drains it", async () => {
    // The watch-DROP path (`onDropCall`) leaves the mailbox buffered, not flushed. Worker A escalates
    // `on_message`; the FIRST watch re-emits it and that handler BREAKS out of its handle — dropping watch1
    // while the nursery lives on. Worker B, forked into the now watch-less nursery, escalates `on_message` and
    // it BUFFERS (length 1). A SECOND handle+watch then registers and drains that backlog to its handler, whose
    // answer descends to worker B — proving a dropped watch neither flushes the mailbox nor loses a later one.
    const persistence = new StoringPersistence();
    const continuation: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 70, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 71, value: { kind: "string", value: "first" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 70],
          ["argument", 71],
        ],
        output: 72,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 72,
        output: 73,
      },
      { kind: "call", target: 14, output: 74 },
      { kind: "loadLiteral", output: 75, value: { kind: "string", value: "second" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 70],
          ["argument", 75],
        ],
        output: 76,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 76,
        output: 77,
      },
      { kind: "makeRecord", entries: [], output: 78 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("gate") },
        argument: 78,
        output: 79,
      },
      { kind: "call", target: 34, output: 80 },
      { kind: "exit", target: 6, value: 80 },
    ];
    const ir = withGate(watchIr());
    // Override the continuation (block 7) with the two-watch program.
    ir.blocks[7] = {
      block: { kind: "sequence", result: null, operations: continuation },
      parameters: { parameter: 60 },
    };
    // handle1's body (block 15) just watches; its handler (block 16) BREAKS on the first on_message (dropping
    // watch1 without answering worker A — worker A then stays a blocked fiber, cancelled at region close).
    ir.blocks[15] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "makeRecord", entries: [["nursery", 61]], output: 151 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.region.watch") },
            argument: 151,
            output: 152,
          },
          { kind: "exit", target: 14, value: 152 },
        ],
      },
      parameters: {},
    };
    ir.blocks[16] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 161, value: { kind: "null" } },
          { kind: "exit", target: 14, value: 161 },
        ],
      },
      parameters: { parameter: 160 },
    };
    // handle2 (block 34): body watches (block 35); handler answers on_message with "answered" (block 36).
    ir.blocks[34] = {
      block: {
        kind: "handle",
        parallel: false,
        initialStates: [],
        body: 35,
        handlers: [{ request: createAgentName("on_message"), body: 36 }],
        thenClause: null,
      },
      parameters: {},
    };
    ir.blocks[35] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "makeRecord", entries: [["nursery", 61]], output: 351 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.region.watch") },
            argument: 351,
            output: 352,
          },
          { kind: "exit", target: 34, value: 352 },
        ],
      },
      parameters: {},
    };
    ir.blocks[36] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 361, value: { kind: "string", value: "answered" } },
          { kind: "continue", target: 34, value: 361, modifiers: [] },
        ],
      },
      parameters: { parameter: 360 },
    };

    const actor = makeActor(ir, persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // watch1 dropped; the body is parked on `gate` and worker B's escalation sits buffered (length 1).
    const gate = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    expect(buffered.mailbox).toHaveLength(1);

    // Answer `gate`: handle2 registers watch2, which drains the buffered escalation → worker B round-trips.
    await actor.answerEscalation(gate.escalation, { kind: "null" });
    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "answered" });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("pre-watch buffered escalations and a post-watch one reach a sequential handler in arrival order", async () => {
    // The FIFO guarantee ACROSS the buffer boundary (the `:1596` transition version). Two workers escalate
    // `on_message` BEFORE the watch registers (buffered, arrival order first→second); a THIRD escalates AFTER the
    // watch is live (worker3 first parks on `w3gate`, released only once first/second are handled). One
    // sequential handler `note`s each tag and blocks, so the order the notes surface IS its processing order —
    // the buffered pair ahead of the live one: [first, second, third].
    const handleBody: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "first" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "loadLiteral", output: 156, value: { kind: "string", value: "second" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 156],
        ],
        output: 157,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 157,
        output: 158,
      },
      { kind: "loadAgent", output: 162, name: createAgentName("worker3") },
      { kind: "loadLiteral", output: 163, value: { kind: "string", value: "" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 162],
          ["argument", 163],
        ],
        output: 164,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 164,
        output: 165,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    const taggedWorker: Operation[] = [
      { kind: "getField", source: 110, field: "input", output: 111 },
      { kind: "makeRecord", entries: [["tag", 111]], output: 113 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("on_message") },
        argument: 113,
        output: 112,
      },
      { kind: "exit", target: 10, value: 112 },
    ];
    const notingHandler: Operation[] = [
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("note") },
        argument: 160,
        output: 169,
      },
      { kind: "loadLiteral", output: 161, value: { kind: "null" } },
      { kind: "continue", target: 14, value: 161, modifiers: [] },
    ];
    const ir = watchIr({ handleBody, worker: taggedWorker, handler: notingHandler });
    // The `note` request the handler blocks on, and `w3gate` + a `worker3` that parks on it before escalating
    // its own `on_message` — the post-watch third fiber.
    ir.blocks[17] = {
      block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[18] = {
      block: { kind: "request", name: createAgentName("note"), input: 180 },
      parameters: { parameter: 180 },
    };
    ir.blocks[34] = {
      block: { kind: "agent", body: 35, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[35] = {
      block: { kind: "request", name: createAgentName("w3gate"), input: 340 },
      parameters: { parameter: 340 },
    };
    ir.blocks[36] = {
      block: { kind: "agent", body: 37, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[37] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "makeRecord", entries: [], output: 371 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("w3gate") },
            argument: 371,
            output: 372,
          },
          { kind: "loadLiteral", output: 373, value: { kind: "string", value: "third" } },
          { kind: "makeRecord", entries: [["tag", 373]], output: 374 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("on_message") },
            argument: 374,
            output: 375,
          },
          { kind: "exit", target: 36, value: 375 },
        ],
      },
      parameters: { parameter: 370 },
    };
    ir.entries[createAgentName("note")] = { block: 17, private: false };
    ir.entries[createAgentName("w3gate")] = { block: 34, private: false };
    ir.entries[createAgentName("worker3")] = { block: 36, private: false };

    const actor = makeActor(ir);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const order: string[] = [];
    // The two PRE-watch buffered escalations, processed in arrival order by the sequential handler.
    for (let landed = 0; landed < 2; landed += 1) {
      const note = await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName("note")),
      );
      const tag = note.argument?.kind === "record" ? note.argument.fields.tag : undefined;
      if (tag?.kind === "string") order.push(tag.value);
      await actor.answerEscalation(note.escalation, { kind: "null" });
    }
    // Release worker3's POST-watch escalation, then process its note — it lands AFTER the buffered pair.
    const w3gate = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("w3gate")),
    );
    await actor.answerEscalation(w3gate.escalation, { kind: "null" });
    const third = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("note")),
    );
    const tag = third.argument?.kind === "record" ? third.argument.fields.tag : undefined;
    if (tag?.kind === "string") order.push(tag.value);
    await actor.answerEscalation(third.escalation, { kind: "null" });

    expect(order).toEqual(["first", "second", "third"]);
  });

  test("both fibers' escalations are re-emitted concurrently and a sequential handler services them all", async () => {
    // Two workers with distinct arguments both escalate `on_message`; the watch re-emits BOTH at once (no
    // serialization of its own), and the sequential handle re-serializes them at its own FIFO — servicing each
    // in turn. Both outcomes buffer on the provide — proving every fiber's request wells up at the one watch and
    // is serviced (the arrival-ORDER guarantee is pinned separately by the FIFO test below).
    const persistence = new StoringPersistence();
    const twoForks: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "alpha" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "loadLiteral", output: 156, value: { kind: "string", value: "beta" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 156],
        ],
        output: 157,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 157,
        output: 158,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    // A worker escalates `on_message` (which wells up at the watch), and AFTER it is answered returns its own
    // fork argument — so the two buffered outcomes are the two distinct arguments, proving BOTH fibers'
    // requests were serviced (each fiber unblocks only once the handler answers its `on_message`).
    const returningWorker: Operation[] = [
      { kind: "getField", source: 110, field: "input", output: 111 },
      { kind: "makeRecord", entries: [], output: 113 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("on_message") },
        argument: 113,
        output: 112,
      },
      // Report the own argument back up — the observable that this exact worker was serviced.
      { kind: "makeRecord", entries: [["value", 111]], output: 119 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("fiber_report") },
        argument: 119,
        output: 118,
      },
      { kind: "exit", target: 10, value: 111 },
    ];
    // The sequential handle services one request at a time; the handler answers each (with a constant, which
    // the worker discards) and frees the handle for the next.
    const handler: Operation[] = [
      { kind: "loadLiteral", output: 161, value: { kind: "null" } },
      { kind: "continue", target: 14, value: 161, modifiers: [] },
    ];
    const actor = makeActor(
      watchIr({ handleBody: twoForks, handler, worker: returningWorker }),
      persistence,
    );
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The two workers are both serviced (order-agnostic here); collect and answer each report.
    const values = new Set<string>();
    for (let landed = 0; landed < 2; landed += 1) {
      const report = await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
      );
      const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
      if (reported?.kind === "string") values.add(reported.value);
      await actor.answerEscalation(report.escalation, { kind: "null" });
    }
    expect(values).toEqual(new Set(["alpha", "beta"]));
  });

  test("concurrently re-emitted escalations reach a sequential (var) handler in arrival (FIFO) order", async () => {
    // The FIFO-into-a-var-handler guarantee (audit PAIN A6). Two workers escalate `on_message` carrying their
    // own tag; the watch re-emits BOTH concurrently (no serialization of its own). The sequential handler
    // `note`s each tag as its FIRST act and BLOCKS there until the test answers — so exactly one `note` is open
    // at a time, and the order the notes surface IS the order the handler processed the escalations. Because
    // "first" is forked before "second" (a blocking `fork` delegate spawns and runs its fiber before the next
    // fork is issued), it is mailboxed first, so a correct FIFO handler processes ["first", "second"] — a racy
    // re-emission (or a LIFO queue) would invert them. This is the test the audit demands: it pins arrival-order
    // processing by a var handler, the property that lets a chat loop keep ONE var handler and stay in order.
    const twoForks: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "first" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "loadLiteral", output: 156, value: { kind: "string", value: "second" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 156],
        ],
        output: 157,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 157,
        output: 158,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    // A worker escalates `on_message` CARRYING its own tag as `{ tag }` (an agent's argument must be a record —
    // a bare value is coerced to `{}` — so the tag rides a field), then exits.
    const taggedWorker: Operation[] = [
      { kind: "getField", source: 110, field: "input", output: 111 },
      { kind: "makeRecord", entries: [["tag", 111]], output: 113 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("on_message") },
        argument: 113,
        output: 112,
      },
      { kind: "exit", target: 10, value: 112 },
    ];
    // The sequential handler `note`s the whole `{ tag }` record and blocks on that unhandled request before
    // answering — so its invocations are observable one at a time, in the order it dispatched them.
    const notingHandler: Operation[] = [
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("note") },
        argument: 160,
        output: 169,
      },
      { kind: "loadLiteral", output: 161, value: { kind: "null" } },
      { kind: "continue", target: 14, value: 161, modifiers: [] },
    ];
    const ir = watchIr({ handleBody: twoForks, worker: taggedWorker, handler: notingHandler });
    // The `note` request agent the handler holds on (unhandled, so it surfaces at the run root).
    ir.blocks[17] = {
      block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[18] = {
      block: { kind: "request", name: createAgentName("note"), input: 180 },
      parameters: { parameter: 180 },
    };
    ir.entries[createAgentName("note")] = { block: 17, private: false };

    const actor = makeActor(ir);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // Exactly one `note` is open at a time (the handler blocks on it); reading them in order IS the handler's
    // processing order.
    const order: string[] = [];
    for (let landed = 0; landed < 2; landed += 1) {
      const note = await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName("note")),
      );
      const tag = note.argument?.kind === "record" ? note.argument.fields.tag : undefined;
      if (tag?.kind === "string") order.push(tag.value);
      await actor.answerEscalation(note.escalation, { kind: "null" });
    }
    expect(order).toEqual(["first", "second"]);
  });

  test("two escalations to two DIFFERENT handlers are served concurrently — one blocking does not starve the other", async () => {
    // The whole point of the change (audit §10 — a pending approval must not freeze the bus). Two DESKS, each
    // its OWN sequential handler around one nursery: an OUTER handle catches `desk_a`, an INNER handle catches
    // `desk_b`, and both wrap the single `watch`. Worker A (forked first) escalates `desk_a` and its handler
    // BLOCKS on a human-latency `gate_a`; worker B escalates `desk_b` and its handler answers at once. Under the
    // OLD one-relay-at-a-time watch, `desk_a` (mailboxed first) would hold the watch busy and `desk_b` would
    // never be re-emitted — worker B would stall behind the blocked desk. Under the WHITE-HOLE watch, both are
    // re-emitted concurrently, so worker B reports WHILE `desk_a`'s handler is still blocked. That coincidence —
    // B served, gate_a still open — is the concurrency proof; the desks interleave.
    const actor = makeActor(concurrentDesksIr());
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // Worker B is served (its report surfaces) WHILE worker A's desk_a handler is still parked on gate_a.
    const bReport = await waitUntil(() => {
      const report = actor
        .listOpenEscalations()
        .find(
          (open) =>
            open.request === createAgentName("fiber_report") &&
            open.argument?.kind === "record" &&
            open.argument.fields.value?.kind === "string" &&
            open.argument.fields.value.value === "b-served",
        );
      const blocked = actor
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("gate_a"));
      return report !== undefined && blocked !== undefined ? report : undefined;
    });
    // Let worker B finish, then release desk_a's handler; worker A then reports too — nothing was lost.
    await actor.answerEscalation(bReport.escalation, { kind: "null" });
    const gateA = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate_a")),
    );
    await actor.answerEscalation(gateA.escalation, { kind: "string", value: "go" });
    const aReport = await waitUntil(() =>
      actor
        .listOpenEscalations()
        .find(
          (open) =>
            open.request === createAgentName("fiber_report") &&
            open.argument?.kind === "record" &&
            open.argument.fields.value?.kind === "string" &&
            open.argument.fields.value.value === "a-served",
        ),
    );
    await actor.answerEscalation(aReport.escalation, { kind: "null" });
  });

  test("a handler installed around watch can fork a NEW fiber into the same nursery", async () => {
    // The white hole gives the handler the nursery: on the worker's `on_message`, the handler forks a SECOND
    // worker (a `child` agent returning a constant) into the same nursery `r` (variable 61, in lexical scope),
    // then answers the first. Both the first worker's answer and the forked child's constant buffer on the
    // provide — proving the handler's position holds the nursery, the composition `watch` exists to enable.
    const persistence = new StoringPersistence();
    // The handler: fork `child` into `r`, then answer the original `on_message` with "answered".
    const forkingHandler: Operation[] = [
      { kind: "loadAgent", output: 162, name: createAgentName("child") },
      { kind: "loadLiteral", output: 163, value: { kind: "string", value: "childarg" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 162],
          ["argument", 163],
        ],
        output: 164,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 164,
        output: 165,
      },
      { kind: "loadLiteral", output: 166, value: { kind: "string", value: "answered" } },
      { kind: "continue", target: 14, value: 166, modifiers: [] },
    ];
    const ir = watchIr({ handler: forkingHandler });
    // Add the `child` agent (a fiber the handler forks) — returns a constant, so it buffers a distinct outcome.
    ir.blocks[17] = {
      block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[18] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 181, value: { kind: "string", value: "child-ran" } },
          { kind: "makeRecord", entries: [["value", 181]], output: 183 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("fiber_report") },
            argument: 183,
            output: 182,
          },
          { kind: "exit", target: 17, value: 181 },
        ],
      },
      parameters: { parameter: 180 },
    };
    ir.entries[createAgentName("child")] = { block: 17, private: false };

    const actor = makeActor(ir, persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const values = new Set<string>();
    for (let landed = 0; landed < 2; landed += 1) {
      const report = await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
      );
      const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
      if (reported?.kind === "string") values.add(reported.value);
      await actor.answerEscalation(report.escalation, { kind: "null" });
    }
    expect(values).toEqual(new Set(["answered", "child-ran"]));
  });

  test("a watch and its mailboxed escalation survive a restart, and the answer still returns to the fiber", async () => {
    // Durability: a worker escalates `on_message`, the watch re-emits it, and it lands at the handle — which
    // holds it (a handler that never answers, so the escalation is outstanding at restart). A fresh actor over
    // the same rows re-registers the watch (its outstanding relay reloaded from the durable row) and reloads the
    // provide's fiber buffer / mailbox. The reloaded handle re-catches the outstanding request and answers it,
    // so the worker settles with the answer AFTER the restart — the whole white hole surviving the crash.
    const persistence = new StoringPersistence();
    // A handler that HOLDS on a second, unhandled request (`gate`) before answering — so at the restart point
    // the worker's `on_message` is outstanding (re-emitted, caught, not yet answered).
    const holdingHandler: Operation[] = [
      { kind: "makeRecord", entries: [], output: 161 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("gate") },
        argument: 161,
        output: 162,
      },
      { kind: "continue", target: 14, value: 162, modifiers: [] },
    ];
    const ir = watchIr({ handler: holdingHandler });
    // Add the `gate` request agent the handler holds on.
    ir.blocks[17] = {
      block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[18] = {
      block: { kind: "request", name: createAgentName("gate"), input: 180 },
      parameters: { parameter: 180 },
    };
    ir.entries[createAgentName("gate")] = { block: 17, private: false };

    const actorOne = makeActor(ir, persistence);
    actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    // Drive to the suspend point: the handler is holding on `gate` (so the worker's on_message is outstanding at
    // the watch), and the watch call is durable.
    await waitUntil(() =>
      actorOne.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );

    // Restart: a fresh actor re-registers the watch and reloads the mailbox / outstanding relay.
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const gate = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    // Answering the gate lets the handler answer the original on_message; the worker settles with that answer.
    await actorTwo.answerEscalation(gate.escalation, { kind: "string", value: "post-restart" });
    const report = await waitUntil(() =>
      actorTwo
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "post-restart" });
    await actorTwo.answerEscalation(report.escalation, { kind: "null" });
  });

  // Augment a `watchIr` module with the two `file` prim agents (`from_base64` / `read_base64`) the blob-edge
  // tests below use — the file API is the same monotonic blob machinery every reactor shares, wired here as
  // ordinary primitive-block agents so a fiber / handler can mint and read a blob mid-run.
  function withFilePrims(ir: IRModule): IRModule {
    ir.blocks[32] = {
      block: { kind: "agent", body: 33, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[33] = {
      block: { kind: "primitive", name: "prelude.files.from_base64", input: 320 },
      parameters: { parameter: 320 },
    };
    ir.blocks[34] = {
      block: { kind: "agent", body: 35, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[35] = {
      block: { kind: "primitive", name: "prelude.files.read_base64", input: 340 },
      parameters: { parameter: 340 },
    };
    ir.entries[createAgentName("prelude.files.from_base64")] = { block: 32, private: false };
    ir.entries[createAgentName("prelude.files.read_base64")] = { block: 34, private: false };
    return ir;
  }

  test("watch: a handler's answer carrying a blob is readable by the fiber it descends to", async () => {
    // The white hole in the ANSWER direction. The fiber escalates `on_message`; the handler — which runs in the
    // long-lived continuation instance the whole handle+watch lives in — mints a blob with `files.from_base64`
    // and answers WITH it. The answer descends the watch bridge back to the fiber, which reads the blob's
    // content (`files.read_base64`) and returns it, so the read-back buffers on the provide. A gone / dangling
    // answer blob would panic `read_base64` and never buffer, so a buffered "aGVsbG8=" proves the fiber read the
    // handler's blob. The blob is owned by the continuation instance — an ancestor of every fiber, kept alive by
    // the held-open `watch` — so it always outlives the reader without any answer-direction owner lift.
    const persistence = new StoringPersistence();
    const worker: Operation[] = [
      { kind: "makeRecord", entries: [], output: 116 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("on_message") },
        argument: 116,
        output: 112,
      },
      // 112 is the answer blob the handler minted. Read it back and return the content.
      { kind: "makeRecord", entries: [["value", 112]], output: 113 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.files.read_base64") },
        argument: 113,
        output: 114,
      },
      { kind: "makeRecord", entries: [["value", 114]], output: 119 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("fiber_report") },
        argument: 119,
        output: 118,
      },
      { kind: "exit", target: 10, value: 114 },
    ];
    const handler: Operation[] = [
      { kind: "loadLiteral", output: 161, value: { kind: "string", value: "aGVsbG8=" } },
      { kind: "loadLiteral", output: 162, value: { kind: "string", value: "" } },
      {
        kind: "makeRecord",
        entries: [
          ["content", 161],
          ["content_type", 162],
        ],
        output: 163,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.files.from_base64") },
        argument: 163,
        output: 164,
      },
      { kind: "continue", target: 14, value: 164, modifiers: [] },
    ];
    const actor = makeActor(withFilePrims(watchIr({ worker, handler })), persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "aGVsbG8=" });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("watch: blobs carried on a held escalation and its queued sibling both survive a restart and stay readable", async () => {
    // The white hole in the FORWARD direction, across a restart. Two worker fibers each mint a blob and escalate
    // it under `on_message`; the watch re-emits BOTH concurrently (no serialization of its own). The sequential
    // handler catches the first and HOLDS it on `gate` (its blob riding an OUTSTANDING RELAY on the watch), and
    // the second's escalation — carrying its blob — waits in the handler's own FIFO queue (durable handle-thread
    // state, a GC root). Both durable homes survive a restart: a fresh actor over the same rows and byte store
    // reloads the held relay and the queued sibling, and after recovery the handler reads each blob
    // (`files.read_base64`) to answer. Both workers buffer their own read-back content, so a buffered "d29ybGQ="
    // (the queued fiber's) proves its blob's ref, owner, and bytes were restored intact — a reclaimed blob would
    // panic the post-restart read. (Under the OLD one-at-a-time watch the sibling sat in the reactor mailbox;
    // now it sits in the receiving handler's queue — the durability moved with the serialization point.)
    const persistence = new StoringPersistence();
    const blobs = new InMemoryBlobStore();
    // Fork two workers (distinct base64 payloads), then watch — both escalations are re-emitted at once; the
    // first is held at the handler on `gate`, the second queues in the sequential handler's FIFO.
    const twoForks: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "aGVsbG8=" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "loadLiteral", output: 156, value: { kind: "string", value: "d29ybGQ=" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 156],
        ],
        output: 157,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 157,
        output: 158,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    // A worker mints a blob from its fork argument (a base64 payload), escalates it WRAPPED in a record (the
    // realistic request-argument shape), and returns the handler's answer.
    const worker: Operation[] = [
      { kind: "getField", source: 110, field: "input", output: 111 },
      { kind: "loadLiteral", output: 117, value: { kind: "string", value: "" } },
      {
        kind: "makeRecord",
        entries: [
          ["content", 111],
          ["content_type", 117],
        ],
        output: 113,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.files.from_base64") },
        argument: 113,
        output: 114,
      },
      { kind: "makeRecord", entries: [["file", 114]], output: 116 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("on_message") },
        argument: 116,
        output: 112,
      },
      { kind: "makeRecord", entries: [["value", 112]], output: 119 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("fiber_report") },
        argument: 119,
        output: 118,
      },
      { kind: "exit", target: 10, value: 112 },
    ];
    // The handler HOLDS on `gate` (so its invocation stays outstanding and the sibling waits in the handler's
    // FIFO), then reads the carried blob out of the request record and answers with its content.
    const handler: Operation[] = [
      { kind: "makeRecord", entries: [], output: 166 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("gate") },
        argument: 166,
        output: 167,
      },
      { kind: "getField", source: 160, field: "file", output: 165 },
      { kind: "makeRecord", entries: [["value", 165]], output: 168 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.files.read_base64") },
        argument: 168,
        output: 169,
      },
      { kind: "continue", target: 14, value: 169, modifiers: [] },
    ];
    const ir = withFilePrims(watchIr({ handleBody: twoForks, worker, handler }));
    // Add the `gate` request agent the handler holds on (blocks 17 / 18, mirroring the restart test above).
    ir.blocks[17] = {
      block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[18] = {
      block: { kind: "request", name: createAgentName("gate"), input: 180 },
      parameters: { parameter: 180 },
    };
    ir.entries[createAgentName("gate")] = { block: 17, private: false };

    const actorOne = makeActor(ir, persistence, blobs);
    actorOne.startRun(createAgentName("main"), SNAPSHOT, null);

    // Drive to the suspend point: the handler holds the first worker on `gate`, and the second worker's
    // escalation (with its blob) waits in the handler's FIFO.
    await waitUntil(() =>
      actorOne.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );

    // Restart: a fresh actor over the same rows and the same byte store.
    const actorTwo = makeActor(ir, persistence, blobs);
    await actorTwo.activate();

    // Answer the first gate (the handler answers the first worker and frees itself for the queued sibling),
    // then the second gate the queued escalation raises. The second answer reads the RESTORED sibling blob.
    const gateOne = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await actorTwo.answerEscalation(gateOne.escalation, { kind: "null" });
    const gateTwo = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await actorTwo.answerEscalation(gateTwo.escalation, { kind: "null" });

    // Both fibers settle with their own read-back content — the queued sibling's "d29ybGQ=" proving its blob
    // survived the restart in the handler's FIFO and was readable after re-emission.
    const values = new Set<string>();
    for (let landed = 0; landed < 2; landed += 1) {
      const report = await waitUntil(() =>
        actorTwo
          .listOpenEscalations()
          .find((open) => open.request === createAgentName("fiber_report")),
      );
      const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
      if (reported?.kind === "string") values.add(reported.value);
      await actorTwo.answerEscalation(report.escalation, { kind: "null" });
    }
    expect(values).toEqual(new Set(["aGVsbG8=", "d29ybGQ="]));
  });

  test("roster lists the RUNNING fibers as fiber_info(id, name) data values and omits a settled one", async () => {
    // The continuation forks TWO named fibers — "alpha" (blocks on `fiber_ask`, so it stays running) and
    // "beta" (the default canceller body, which settles at once) — holds until beta is retired, then returns
    // the roster. The run resolves with an array of ONE `fiber_info` data value: alpha's, carrying its
    // runtime-minted id and its name tag; beta — settled — is simply absent (the runtime's liveness is the
    // only copy, so there is nothing stale to retire).
    const persistence = new StoringPersistence();
    const continuation: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "a-arg" } },
      { kind: "loadLiteral", output: 71, value: { kind: "string", value: "alpha" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
          ["name", 71],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      { kind: "loadAgent", output: 72, name: createAgentName("canceller") },
      { kind: "loadLiteral", output: 73, value: { kind: "string", value: "beta" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 72],
          ["argument", 63],
          ["name", 73],
        ],
        output: 74,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 74,
        output: 75,
      },
      // Hold, so the test can wait for beta's retirement before the roster reads the running set.
      { kind: "makeRecord", entries: [], output: 66 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("ask_value") },
        argument: 66,
        output: 67,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 68 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.roster") },
        argument: 68,
        output: 69,
      },
      { kind: "exit", target: 6, value: 69 },
    ];
    const actor = makeActor(
      withRegistryAgents(forkIr({ continuation, task: askingTask })),
      persistence,
    );
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The continuation holds on ask_value (alpha's own `fiber_ask` sits buffered in the mailbox — no watch — so
    // it never reaches the run root; alpha's liveness is confirmed below via the provide's inner-call bridges).
    const hold = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("ask_value")),
    );
    // Beta retired: the provide's bridges shrink to continuation + alpha, and the durable name map holds
    // exactly alpha's tag (beta's was cleaned with its running entry).
    const before = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined &&
        provide.innerCalls.length === 2 &&
        Object.values(provide.names).length === 1
        ? provide
        : undefined;
    });
    expect(Object.values(before.names)).toEqual(["alpha"]);

    await actor.answerEscalation(hold.escalation, { kind: "null" });
    const value = await result;
    if (value.kind !== "array") throw new Error("expected the roster array");
    expect(value.elements).toHaveLength(1);
    const info = value.elements[0];
    if (info?.kind !== "record") throw new Error("expected a fiber_info record");
    // The decoded completion is a DATA value: the constructor tag is what a Katari
    // `match ... fiber_info(...)` dispatches on, and the fields are what its arms bind.
    expect(info.ctor).toBe(createAgentName("prelude.region.fiber_info"));
    expect(info.fields.name).toEqual({ kind: "string", value: "alpha" });
    const id = info.fields.id;
    if (id?.kind !== "string") throw new Error("fiber_info must carry a string id");
    expect(id.value).toMatch(/^fiber:/);
  });

  test("cancel_by_id tears a running fiber down and answers cancelled(id)", async () => {
    // The continuation forks a named fiber, reads the id OFF the returned handle (the same field
    // `fiber_id` reads), holds until the fiber is provably running, then cancels by that id. The
    // `cancelled(id)` answer settles only when the teardown confirms, so the resolved run proves the
    // fiber is gone — and nothing leaks behind it.
    const persistence = new StoringPersistence();
    const continuation: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadAgent", output: 62, name: createAgentName("task") },
      { kind: "loadLiteral", output: 63, value: { kind: "string", value: "w-arg" } },
      { kind: "loadLiteral", output: 71, value: { kind: "string", value: "worker" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 62],
          ["argument", 63],
          ["name", 71],
        ],
        output: 64,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 64,
        output: 65,
      },
      { kind: "getField", source: 65, field: "$katari_region_fiber", output: 72 },
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
          ["id", 72],
        ],
        output: 68,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.cancel_by_id") },
        argument: 68,
        output: 69,
      },
      { kind: "exit", target: 6, value: 69 },
    ];
    const actor = makeActor(
      withRegistryAgents(forkIr({ continuation, task: askingTask })),
      persistence,
    );
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const gate = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("ask_value")),
    );
    // The worker is provably running: its own `fiber_ask` sits buffered in the mailbox (no watch to surface it).
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? true : undefined;
    });
    await actor.answerEscalation(gate.escalation, { kind: "null" });

    const value = await result;
    if (value.kind !== "record") throw new Error("expected a cancel_outcome data value");
    expect(value.ctor).toBe(createAgentName("prelude.region.cancelled"));
    const id = value.fields.id;
    if (id?.kind !== "string") throw new Error("cancelled must carry a string id");
    expect(id.value).toMatch(/^fiber:/);
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
  });

  test("cancel_by_id with an id matching no running fiber answers unknown_fiber(id), not an error", async () => {
    // Ids are data (often model-supplied), so a stale / made-up one is an anticipated miss the caller
    // renders — unlike a forged NURSERY handle, which stays a panic.
    const continuation: Operation[] = [
      { kind: "getField", source: 60, field: "value", output: 61 },
      { kind: "loadLiteral", output: 62, value: { kind: "string", value: "fiber:missing" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["id", 62],
        ],
        output: 63,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.cancel_by_id") },
        argument: 63,
        output: 64,
      },
      { kind: "exit", target: 6, value: 64 },
    ];
    const actor = makeActor(withRegistryAgents(forkIr({ continuation, task: returningTask })));
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const value = await result;
    if (value.kind !== "record") throw new Error("expected a cancel_outcome data value");
    expect(value.ctor).toBe(createAgentName("prelude.region.unknown_fiber"));
    expect(value.fields.id).toEqual({ kind: "string", value: "fiber:missing" });
  });

  test("a fiber's panic arrives at the watch as the typed crashed event, and the nursery keeps serving", async () => {
    // The handle body forks a steady worker AND a named `panicker` fiber (its range-over-the-ceiling call
    // panics), then watches. The panic never unwinds the watch context: the runtime tears the dead fiber
    // down and re-emits `crashed(id, name, message)` at the watch, where a handler for it — installed next
    // to `on_message` — reports the record up as `crash_seen` and answers null. The null answer has no
    // fiber to descend to (swallowed), and the steady worker's own request still round-trips afterwards —
    // the nursery kept serving.
    const persistence = new StoringPersistence();
    const handleBody: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "arg" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "loadAgent", output: 156, name: createAgentName("panicker") },
      { kind: "loadLiteral", output: 157, value: { kind: "string", value: "x" } },
      { kind: "loadLiteral", output: 148, value: { kind: "string", value: "boom" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 156],
          ["argument", 157],
          ["name", 148],
        ],
        output: 149,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 149,
        output: 147,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    const ir = watchIr({ handleBody });
    // Install a `crashed` handler next to the default `on_message` one: report the crash record up as
    // `crash_seen` (the test's observable), then answer the crashed event with null.
    const handleBlock = ir.blocks[14]?.block;
    if (handleBlock === undefined || handleBlock.kind !== "handle") {
      throw new Error("watchIr must place the handle at block 14");
    }
    handleBlock.handlers.push({ request: createAgentName("prelude.region.crashed"), body: 20 });
    ir.blocks[20] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("crash_seen") },
            argument: 200,
            output: 201,
          },
          { kind: "loadLiteral", output: 202, value: { kind: "null" } },
          { kind: "continue", target: 14, value: 202, modifiers: [] },
        ],
      },
      parameters: { parameter: 200 },
    };
    ir.blocks[22] = {
      block: { kind: "agent", body: 23, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[23] = {
      block: { kind: "request", name: createAgentName("crash_seen"), input: 220 },
      parameters: { parameter: 220 },
    };
    ir.entries[createAgentName("crash_seen")] = { block: 22, private: false };

    const actor = makeActor(withRegistryAgents(ir), persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const seen = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("crash_seen")),
    );
    const argument = seen.argument;
    if (argument?.kind !== "record") throw new Error("crash_seen must carry the crashed record");
    expect(argument.fields.name).toEqual({ kind: "string", value: "boom" });
    const id = argument.fields.id;
    if (id?.kind !== "string") throw new Error("crashed must carry a string id");
    expect(id.value).toMatch(/^fiber:/);
    const message = argument.fields.message;
    if (message?.kind !== "string") throw new Error("crashed must carry a string message");
    expect(message.value).toContain("range(0, 20000000)");
    // The dead fiber is fully retired while the nursery lives on: the provide's bridges shrink back to
    // the continuation + the steady worker.
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.innerCalls.length === 2 ? true : undefined;
    });

    // Answer the report; the handler's null answer to the crashed event itself is swallowed (no fiber to
    // descend to), freeing the watch — so the steady worker's on_message still round-trips end-to-end.
    await actor.answerEscalation(seen.escalation, { kind: "null" });
    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "answered" });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("a fiber's crash is buffered with no watch, and a later watch re-emits it", async () => {
    // The semantic inversion of the old crashed-flush: the panicker crashes while NO watch is registered, so the
    // runtime tears the dead fiber down and writes the synthetic `crashed` entry into the durable MAILBOX — it
    // does NOT flush up to the run root (the provide's row carries no `crashed` obligation without a watch). The
    // continuation is parked on `gate`; only when it answers and the watch registers does the buffered crash
    // re-emit, bubbling PAST the on_message handle to the run root as the typed event. Answering it is swallowed
    // (the fiber is long dead).
    const persistence = new StoringPersistence();
    const ir = withGate(
      withRegistryAgents(
        watchIr({ handleBody: forkHoldThenWatch({ task: "panicker", argument: "x", name: "boom" }) }),
      ),
    );
    const actor = makeActor(ir, persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The continuation is parked on `gate` (no watch yet) and the crash sits buffered as a SYNTHETIC entry
    // (no child leg), NOT at the run root.
    await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    const buffered = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
    });
    const entry = buffered.mailbox[0];
    expect(entry?.child).toBeNull();
    expect(entry?.ask.kind === "request" ? entry.ask.request : null).toEqual(
      createAgentName("prelude.region.crashed"),
    );
    expect(
      actor
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("prelude.region.crashed")),
    ).toBeUndefined();

    // Answer the gate: the watch registers and re-emits the buffered crash, which bubbles to the run root.
    const gate = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await actor.answerEscalation(gate.escalation, { kind: "null" });
    const crashed = await waitUntil(() =>
      actor
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("prelude.region.crashed")),
    );
    const argument = crashed.argument;
    if (argument?.kind !== "record") throw new Error("crashed must carry its record");
    expect(argument.fields.name).toEqual({ kind: "string", value: "boom" });
    const message = argument.fields.message;
    if (message?.kind !== "string") throw new Error("crashed must carry a string message");
    expect(message.value).toContain("range(0, 20000000)");
    await actor.answerEscalation(crashed.escalation, { kind: "null" });
  });

  test("fiber names and a re-emitted crashed event survive a restart", async () => {
    // Pre-restart shape: the keeper worker's on_message is held open at the handler (a `gate` hold), and the
    // handler has forked a `panicker` fiber whose crash is re-emitted at the watch AT ONCE (the white hole
    // holds nothing back). The handle knows only on_message, so the crashed event bubbles PAST it to the run
    // root as an open escalation — the durable home a re-emitted crash now takes (the mailbox holds only the
    // pre-registration backlog, so it is empty here). The keeper's name tag sits in the durable `names` map
    // (the crashed fiber's tag was cleaned with its running entry). A fresh actor over the same rows must
    // reload the keeper's name AND the outstanding crashed escalation, which must still be answerable (and
    // swallowed) after the restart.
    const persistence = new StoringPersistence();
    const handleBody: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "arg" } },
      { kind: "loadLiteral", output: 149, value: { kind: "string", value: "keeper" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
          ["name", 149],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    // The on_message handler forks the panicker FIRST (deterministically while the watch is busy with the
    // on_message it is servicing), then holds on `gate` until the test releases it.
    const handler: Operation[] = [
      { kind: "loadAgent", output: 162, name: createAgentName("panicker") },
      { kind: "loadLiteral", output: 163, value: { kind: "string", value: "x" } },
      { kind: "loadLiteral", output: 168, value: { kind: "string", value: "boom" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 162],
          ["argument", 163],
          ["name", 168],
        ],
        output: 164,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 164,
        output: 165,
      },
      { kind: "makeRecord", entries: [], output: 166 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("gate") },
        argument: 166,
        output: 167,
      },
      { kind: "continue", target: 14, value: 167, modifiers: [] },
    ];
    const ir = withRegistryAgents(watchIr({ handleBody, handler }));
    ir.blocks[17] = {
      block: { kind: "agent", body: 18, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[18] = {
      block: { kind: "request", name: createAgentName("gate"), input: 180 },
      parameters: { parameter: 180 },
    };
    ir.entries[createAgentName("gate")] = { block: 17, private: false };

    const actorOne = makeActor(ir, persistence);
    actorOne.startRun(createAgentName("main"), SNAPSHOT, null);
    // The keeper's handler is holding on `gate`, and the panicker's crash has been re-emitted at once and —
    // unhandled by the handle — bubbled to the run root as the typed `crashed` event.
    await waitUntil(() =>
      actorOne.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    const crashedBefore = await waitUntil(() =>
      actorOne
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("prelude.region.crashed")),
    );
    const crashedArg = crashedBefore.argument;
    if (crashedArg?.kind !== "record") throw new Error("crashed must carry its record");
    expect(crashedArg.fields.name).toEqual({ kind: "string", value: "boom" });
    // The crash is fully absorbed pre-restart: the panicker's bridge is gone (continuation + keeper remain),
    // the mailbox is EMPTY (the crash was re-emitted, not held), and only the keeper's name survives in the map.
    const before = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined &&
        provide.mailbox.length === 0 &&
        provide.innerCalls.length === 2 &&
        Object.values(provide.names).length === 1
        ? provide
        : undefined;
    });
    expect(Object.values(before.names)).toEqual(["keeper"]);

    // Restart: the durable registry facts reload — the keeper's tag and the outstanding crashed escalation
    // (its watch relay row restored, its root escalation rehydrated).
    const actorTwo = makeActor(ir, persistence);
    await actorTwo.activate();
    const after = await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && Object.values(provide.names).length === 1 ? provide : undefined;
    });
    expect(after.mailbox).toHaveLength(0);
    expect(Object.values(after.names)).toEqual(["keeper"]);

    // The crashed event survived the restart at the run root; answering it is swallowed (the fiber is long
    // dead). Releasing the gate lets the keeper's on_message answer, and its post-restart report proves the
    // nursery still serves.
    const crashed = await waitUntil(() =>
      actorTwo
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("prelude.region.crashed")),
    );
    const argument = crashed.argument;
    if (argument?.kind !== "record") throw new Error("crashed must carry its record");
    expect(argument.fields.name).toEqual({ kind: "string", value: "boom" });
    await actorTwo.answerEscalation(crashed.escalation, { kind: "null" });
    const gate = await waitUntil(() =>
      actorTwo.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
    );
    await actorTwo.answerEscalation(gate.escalation, { kind: "string", value: "resumed" });
    const report = await waitUntil(() =>
      actorTwo
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "resumed" });
    await actorTwo.answerEscalation(report.escalation, { kind: "null" });
  });

  test("a fiber's uncaught throw arrives at the watch as the typed failed event carrying the thrown value, and the nursery keeps serving", async () => {
    // The `failed` twin of the crashed test, and the whole point of the feature: the handle body forks a
    // steady worker AND a named `thrower` fiber whose `prelude.throw` finds no handler inside the task. The
    // throw does NOT ride the ceiling up past the watch (which is what used to force a throw guard around
    // every forked task): the runtime tears the failed fiber down and re-emits `failed(id, name, error)` at
    // the watch, where a handler for it — installed next to `on_message` — reports the record up as
    // `fail_seen`. The error is the THROWN VALUE ITSELF, so the handler reads `error.message`.
    const persistence = new StoringPersistence();
    const handleBody: Operation[] = [
      { kind: "loadAgent", output: 150, name: createAgentName("worker") },
      { kind: "loadLiteral", output: 151, value: { kind: "string", value: "arg" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 150],
          ["argument", 151],
        ],
        output: 152,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 152,
        output: 153,
      },
      { kind: "loadAgent", output: 156, name: createAgentName("thrower") },
      { kind: "loadLiteral", output: 157, value: { kind: "string", value: "x" } },
      { kind: "loadLiteral", output: 148, value: { kind: "string", value: "monitor" } },
      {
        kind: "makeRecord",
        entries: [
          ["nursery", 61],
          ["task", 156],
          ["argument", 157],
          ["name", 148],
        ],
        output: 149,
      },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.fork") },
        argument: 149,
        output: 147,
      },
      { kind: "makeRecord", entries: [["nursery", 61]], output: 154 },
      {
        kind: "delegate",
        target: { kind: "name", name: createAgentName("prelude.region.watch") },
        argument: 154,
        output: 155,
      },
      { kind: "exit", target: 14, value: 155 },
    ];
    const ir = withThrowingAgents(watchIr({ handleBody }));
    // Install a `failed` handler next to the default `on_message` one: report the failure record up as
    // `fail_seen` (the test's observable), then answer the failed event with null.
    const handleBlock = ir.blocks[14]?.block;
    if (handleBlock === undefined || handleBlock.kind !== "handle") {
      throw new Error("watchIr must place the handle at block 14");
    }
    handleBlock.handlers.push({ request: createAgentName("prelude.region.failed"), body: 20 });
    ir.blocks[20] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("fail_seen") },
            argument: 200,
            output: 201,
          },
          { kind: "loadLiteral", output: 202, value: { kind: "null" } },
          { kind: "continue", target: 14, value: 202, modifiers: [] },
        ],
      },
      parameters: { parameter: 200 },
    };
    ir.blocks[22] = {
      block: { kind: "agent", body: 23, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    };
    ir.blocks[23] = {
      block: { kind: "request", name: createAgentName("fail_seen"), input: 220 },
      parameters: { parameter: 220 },
    };
    ir.entries[createAgentName("fail_seen")] = { block: 22, private: false };

    const actor = makeActor(ir, persistence);
    actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const seen = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fail_seen")),
    );
    const argument = seen.argument;
    if (argument?.kind !== "record") throw new Error("fail_seen must carry the failed record");
    expect(argument.fields.name).toEqual({ kind: "string", value: "monitor" });
    const id = argument.fields.id;
    if (id?.kind !== "string") throw new Error("failed must carry a string id");
    expect(id.value).toMatch(/^fiber:/);
    // The payload is the thrown value VERBATIM — a data record, not a rendered message. That is the whole
    // difference from `crashed`: a handler matches it exactly as a `prelude.throw` handler would.
    expect(argument.fields.error).toEqual({
      kind: "record",
      fields: { message: { kind: "string", value: "upstream refused" } },
    });
    // The failed fiber is fully retired while the nursery lives on: the provide's bridges shrink back to
    // the continuation + the steady worker.
    await eventually(async () => {
      const provide = (await peekRegionProvides(persistence))[0];
      return provide !== undefined && provide.innerCalls.length === 2 ? true : undefined;
    });

    // Answer the report; the handler's null answer to the failed event itself is swallowed (no fiber to
    // descend to), freeing the watch — so the steady worker's on_message still round-trips end-to-end.
    await actor.answerEscalation(seen.escalation, { kind: "null" });
    const report = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_report")),
    );
    const reported = report.argument?.kind === "record" ? report.argument.fields.value : undefined;
    expect(reported).toEqual({ kind: "string", value: "answered" });
    await actor.answerEscalation(report.escalation, { kind: "null" });
  });

  test("only a throw raised INSIDE a fiber is trapped: the handler's own throw, raised above the watch while answering a fiber, still escapes the region", async () => {
    // The containment boundary, proved from the other side. The worker fiber performs an ORDINARY
    // `on_message` — which must still relay to the watch unchanged — and the handler answering it at the
    // watch's caller raises `prelude.throw` instead of resuming. That throw is the CONTINUATION's, not a
    // fiber's (a handler body escalates from its install site, which is above the watch), so it must NOT be
    // trapped as `failed`: it relays up past the provide and fails the run, exactly as it did before fibers'
    // throws were trapped at all. A `failed` event here would mean the reactor is trapping on the request
    // name rather than on the raiser being a fiber.
    const ir = withThrowingAgents(
      watchIr({ handler: raiseThrowOperations("handler refused", 160, 14) }),
    );
    const actor = makeActor(ir);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The run fails with the HANDLER's throw payload, which is only reachable if it escaped the region.
    await expect(result).rejects.toThrow(/handler refused/);
    // ...and no `failed` event was ever synthesised: the trap fired for no throw at all.
    expect(
      actor
        .listOpenEscalations()
        .find((open) => open.request === createAgentName("prelude.region.failed")),
    ).toBeUndefined();
  });

  test("a fiber's throw is buffered as `failed` with no watch, and a panic in the same shape still buffers as `crashed`", async () => {
    // The two endings stay TWO, told apart by the ask the fiber raised and by nothing else. Both fibers run
    // the delayed-watch shape (the continuation parks on `gate` with NO watch registered), so each ending is
    // written into the durable MAILBOX as a SYNTHETIC entry — no child leg, nothing at the run root — and
    // only the watch that registers later re-emits it. Reading the buffer directly is what proves the
    // reactor chose the request name from the raiser's ask rather than collapsing both into one event.
    for (const shape of [
      { task: "thrower", request: "prelude.region.failed" },
      { task: "panicker", request: "prelude.region.crashed" },
    ]) {
      const persistence = new StoringPersistence();
      const ir = withGate(
        withThrowingAgents(
          withRegistryAgents(
            watchIr({
              handleBody: forkHoldThenWatch({ task: shape.task, argument: "x", name: "boom" }),
            }),
          ),
        ),
      );
      const actor = makeActor(ir, persistence);
      actor.startRun(createAgentName("main"), SNAPSHOT, null);

      await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
      );
      const buffered = await eventually(async () => {
        const provide = (await peekRegionProvides(persistence))[0];
        return provide !== undefined && provide.mailbox.length === 1 ? provide : undefined;
      });
      const entry = buffered.mailbox[0];
      expect(entry?.child).toBeNull();
      expect(entry?.ask.kind === "request" ? entry.ask.request : null).toEqual(
        createAgentName(shape.request),
      );

      // Answer the gate: the watch registers and re-emits the buffered ending, which bubbles PAST the
      // on_message-only handle to the run root as the typed event, still naming the fiber's tag.
      const gate = await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName("gate")),
      );
      await actor.answerEscalation(gate.escalation, { kind: "null" });
      const ended = await waitUntil(() =>
        actor.listOpenEscalations().find((open) => open.request === createAgentName(shape.request)),
      );
      const argument = ended.argument;
      if (argument?.kind !== "record") throw new Error("an ending event must carry its record");
      expect(argument.fields.name).toEqual({ kind: "string", value: "boom" });
      await actor.answerEscalation(ended.escalation, { kind: "null" });
    }
  });
});
