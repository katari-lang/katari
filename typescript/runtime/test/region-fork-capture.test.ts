// Regression: a `region.fork` whose task is a CLOSURE capturing the forking instance's scope. The production
// discord-bot `route_region_call` forks a nested closure `start` that captures `monitor` (an agent value) and
// `monitor_name` (a string), into a nursery owned by an OUTER instance, then RETURNS the fiber handle. The
// forking instance tears down, and — before this fix — its intra-instance GC / teardown reclaimed the captured
// scope while the detached fiber still needed it, so the fiber's later read of a captured variable threw
// "variable N is unbound in scope M" (a deterministic throw the substrate drops, hanging the run silently).
//
// Topology mirrored here:
//   main()            -> region.provide(continuation)
//   continuation(v)   -> nursery = v.value; handle = route({ nursery }); join(nursery, handle)
//   route({nursery})  -> secret = "SECRET"; fork(nursery, task = <closure reading secret>, arg); return handle
//   task(input)       -> escalate fiber_ask (suspend); then read the captured `secret` and return it
//
// `route` returns (tears down) before the fiber reads `secret`, so a broken runtime loses the captured scope.

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

const PROJECT = "project-region-capture" as ProjectId;
const SNAPSHOT = "snapshot-region-capture" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

function captureIr(): IRModule {
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
      // continuation: bind the nursery, delegate to `route` (which forks + returns a handle), then join it.
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
            { kind: "loadAgent", output: 62, name: createAgentName("route") },
            { kind: "makeRecord", entries: [["nursery", 61]], output: 63 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("route") },
              argument: 63,
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
              target: { kind: "name", name: createAgentName("prelude.region.join") },
              argument: 65,
              output: 66,
            },
            { kind: "exit", target: 6, value: 66 },
          ],
        },
        parameters: { parameter: 60 },
      },
      // route: bind a secret, build a CLOSURE capturing it, fork it into the nursery, then RETURN the handle
      // (route's instance tears down here — the moment that reclaims the captured scope in a broken runtime).
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
            { kind: "loadLiteral", output: 92, value: { kind: "string", value: "SECRET" } },
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
      // fiber_ask: an unhandled request the fiber escalates to suspend on (so `route` tears down first).
      10: {
        block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      11: {
        block: { kind: "request", name: createAgentName("fiber_ask"), input: 110 },
        parameters: { parameter: 110 },
      },
      // join wrapper.
      14: {
        block: { kind: "agent", body: 15, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      15: {
        block: { kind: "external", key: "prelude.region.join", input: 150, reactor: "region" },
        parameters: { parameter: 150 },
      },
      // The forked closure (block 16). It first escalates fiber_ask to suspend, THEN reads the captured
      // variable 92 (bound in `route`'s scope, its lexical parent) and returns it. The second read is the one
      // that fails on a broken runtime — `route` has torn down by then.
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
            { kind: "exit", target: 16, value: 92 },
          ],
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
      [createAgentName("route")]: { block: 8, private: false },
      [createAgentName("fiber_ask")]: { block: 10, private: false },
    },
    names: {},
  };
}

function makeActor(persistence: StoringPersistence): ProjectActor {
  const ir = captureIr();
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

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 2000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("region fork of a scope-capturing closure", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  test("a fiber reads a variable its task closure captured from the (now torn-down) forking instance", async () => {
    const errors: string[] = [];
    vi.spyOn(console, "error").mockImplementation((line: unknown) => {
      if (typeof line === "string") errors.push(line);
    });

    const persistence = new StoringPersistence();
    const actor = makeActor(persistence);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The fiber has escalated fiber_ask (so it is suspended); `route` has resumed with the handle and torn
    // down by now. Answering the escalation drives the fiber's SECOND turn, where it reads the captured secret.
    const fiberAsk = await waitUntil(() =>
      actor.listOpenEscalations().find((open) => open.request === createAgentName("fiber_ask")),
    );
    await actor.answerEscalation(fiberAsk.escalation, { kind: "null" });

    // Fixed: the fiber reads its captured "SECRET" and returns it; the join hands it back and the run resolves.
    await expect(result).resolves.toEqual({ kind: "string", value: "SECRET" });
    // And no deterministic throw was swallowed on the way (the silent-failure signature of the bug).
    expect(errors.filter((line) => line.includes("is unbound in scope"))).toEqual([]);
    // The captured environment was transferred onto the provide, so the nursery's drop reclaims it — nothing
    // dangles behind the completed run.
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
    expect(persistence.envelopeCount("region")).toBe(0);
    expect(persistence.outboxSize()).toBe(0);
  }, 8000);
});
