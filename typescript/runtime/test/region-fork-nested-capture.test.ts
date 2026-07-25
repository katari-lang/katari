// Regression: a `region.fork` whose task closure captures a scope that BINDS ANOTHER CLOSURE — the nested-capture
// twin of `region-fork-capture.test.ts`. The transfer that parks a forked task's environment on the provide walks
// what the value captures (`engine/ascent.ts`); a walk that stopped at the task's own lexical chain moved that
// chain but left the INNER closure's chain owned by the forker, so the forker's teardown reclaimed it while the
// detached fiber still had to dispatch that inner closure — the production shape where a handler forks a task that
// later calls the `on_decide` callback it was handed.
//
// Topology:
//   main()           -> region.provide(continuation)
//   continuation(v)  -> nursery = v.value; route({ nursery }); handle { watch(nursery) } with fiber_ask/fiber_report
//   route({nursery}) -> cb = make_cb();                    // route REOWNS make_cb's scope (the ack's reown)
//                       fork(nursery, task = <closure over route's scope, which binds cb>, arg);
//                       return handle                      // route tears down here
//   make_cb()        -> secret = "SECRET"; return <closure reading secret>
//   task(input)      -> escalate fiber_ask (suspend until route is gone); cb(); report what it returned
//
// So the fiber's later `cb()` reads a variable two chains deep from the value that crossed the fork boundary. A
// shallow transfer loses it: the closure dispatch lands in a scope whose parent was freed, `readVariable` finds
// nothing, and the deterministic "variable N is unbound in scope M" throw the substrate drops hangs the run.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { afterEach, describe, expect, test, vi } from "vitest";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-region-nested-capture" as ProjectId;
const SNAPSHOT = "snapshot-region-nested-capture" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

function nestedCaptureIr(): IRModule {
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
      // continuation: bind the nursery, run `route` (which forks and returns), then enter the handle+watch that
      // services the fiber's escalations — the same white hole the sibling test installs.
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
            { kind: "makeRecord", entries: [["nursery", 61]], output: 63 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("route") },
              argument: 63,
              output: 64,
            },
            { kind: "call", target: 22, output: 66 },
            { kind: "exit", target: 6, value: 66 },
          ],
        },
        parameters: { parameter: 60 },
      },
      // route: obtain `cb` from a SUB-CALL (so route re-owns make_cb's scope on the ack), build the task closure
      // over its own scope — which binds `cb` but is a different chain from cb's — fork it, and return.
      8: {
        block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      9: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 90, field: "nursery", output: 91 },
            { kind: "makeRecord", entries: [], output: 97 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("make_cb") },
              argument: 97,
              output: 92,
            },
            { kind: "makeClosure", output: 93, agent: 16 },
            { kind: "loadLiteral", output: 96, value: { kind: "string", value: "arg" } },
            {
              kind: "makeRecord",
              entries: [
                ["nursery", 91],
                ["task", 93],
                ["argument", 96],
              ],
              output: 94,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.fork") },
              argument: 94,
              output: 95,
            },
            { kind: "exit", target: 8, value: 95 },
          ],
        },
        parameters: { parameter: 90 },
      },
      // fiber_ask: the unhandled request the fiber suspends on, so `route` finishes first.
      10: {
        block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      11: {
        block: { kind: "request", name: createAgentName("fiber_ask"), input: 110 },
        parameters: { parameter: 110 },
      },
      // fiber_report: the fiber's value-carrying escalation.
      14: {
        block: { kind: "agent", body: 15, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      15: {
        block: { kind: "request", name: createAgentName("fiber_report"), input: 150 },
        parameters: { parameter: 150 },
      },
      20: {
        block: { kind: "agent", body: 21, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      21: {
        block: { kind: "external", key: "prelude.region.watch", input: 210, reactor: "region" },
        parameters: { parameter: 210 },
      },
      // The handle around the watch: answer `fiber_ask` to resume the fiber, break out on `fiber_report` with the
      // value the fiber read through the nested closure.
      22: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 23,
          handlers: [
            { request: createAgentName("fiber_ask"), body: 24 },
            { request: createAgentName("fiber_report"), body: 25 },
          ],
          thenClause: null,
        },
        parameters: {},
      },
      23: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [["nursery", 61]], output: 231 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.region.watch") },
              argument: 231,
              output: 232,
            },
            { kind: "exit", target: 22, value: 232 },
          ],
        },
        parameters: {},
      },
      24: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 241, value: { kind: "null" } },
            { kind: "continue", target: 22, value: 241, modifiers: [] },
          ],
        },
        parameters: { parameter: 240 },
      },
      25: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 250, field: "value", output: 251 },
            { kind: "exit", target: 22, value: 251 },
          ],
        },
        parameters: { parameter: 250 },
      },
      // The forked task (block 16): suspend on fiber_ask until `route` is gone, then DISPATCH the nested closure
      // `cb` (variable 92, bound in route's now-parked scope) and report what it returned.
      16: {
        block: { kind: "agent", body: 17, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      17: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 171 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("fiber_ask") },
              argument: 171,
              output: 172,
            },
            { kind: "makeRecord", entries: [], output: 175 },
            { kind: "delegate", target: { kind: "value", variable: 92 }, argument: 175, output: 176 },
            { kind: "makeRecord", entries: [["value", 176]], output: 173 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("fiber_report") },
              argument: 173,
              output: 174,
            },
            { kind: "exit", target: 16, value: 176 },
          ],
        },
        parameters: { parameter: 170 },
      },
      // make_cb: bind the secret and return a closure over it — the INNER closure, whose chain is the one a
      // shallow fork transfer left behind.
      30: {
        block: { kind: "agent", body: 31, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      31: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 301, value: { kind: "string", value: "SECRET" } },
            { kind: "makeClosure", output: 302, agent: 32 },
            { kind: "exit", target: 30, value: 302 },
          ],
        },
        parameters: { parameter: 300 },
      },
      // cb's body: read the captured secret (variable 301, in make_cb's scope).
      32: {
        block: { kind: "agent", body: 33, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      33: {
        block: {
          kind: "sequence",
          result: null,
          operations: [{ kind: "exit", target: 32, value: 301 }],
        },
        parameters: { parameter: 330 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("prelude.region.provide")]: { block: 2, private: false },
      [createAgentName("prelude.region.fork")]: { block: 4, private: false },
      [createAgentName("prelude.region.watch")]: { block: 20, private: false },
      [createAgentName("fiber_report")]: { block: 14, private: false },
      [createAgentName("continuation")]: { block: 6, private: false },
      [createAgentName("route")]: { block: 8, private: false },
      [createAgentName("fiber_ask")]: { block: 10, private: false },
      [createAgentName("make_cb")]: { block: 30, private: false },
    },
    names: {},
  };
}

function makeActor(persistence: StoringPersistence): ProjectActor {
  const ir = nestedCaptureIr();
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
  });
}

describe("region fork of a closure capturing a nested closure", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  test("a fiber dispatches the callback its task closure captured, after the forker is gone", async () => {
    const errors: string[] = [];
    vi.spyOn(console, "error").mockImplementation((line: unknown) => {
      if (typeof line === "string") errors.push(line);
    });

    const persistence = new StoringPersistence();
    const actor = makeActor(persistence);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The fiber's second turn calls `cb` — two chains removed from the value that crossed the fork — long after
    // `route` (which owned cb's captured scope) has torn down. The reported value is what the fiber's `cb()`
    // returned, so the run resolving with "SECRET" is proof the whole nested environment survived the transfer.
    await expect(result).resolves.toEqual({ kind: "string", value: "SECRET" });
    expect(errors.filter((line) => line.includes("is unbound in scope"))).toEqual([]);
    expect(errors.filter((line) => line.includes("scope not found"))).toEqual([]);
    // Everything the fork parked on the provide is reclaimed with it — no scope outlives the settled region.
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
  }, 8000);
});
