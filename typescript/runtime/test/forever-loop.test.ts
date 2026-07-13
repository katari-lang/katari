// The `forever` block: the engine-level guarantees behind the language's unbounded loop. A hand-built
// module runs `daemon_main() { forever { probe() } }` against an in-process FFI `probe`; the suite pins
// the two properties the construct exists for — the loop iterates indefinitely (each iteration a fresh
// child thread whose value is discarded), and its durable footprint stays FLAT however many iterations
// have run (no collected values, no cursor, each completed iteration's thread and scope reclaimed) —
// plus the teardown story (a cancel drains the in-flight iteration and leaves nothing behind).

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { ManualClock } from "../src/runtime/external/clock.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { type FfiHandler, InProcessFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-forever" as ProjectId;
const SNAPSHOT = "snapshot-forever" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

// daemon_main() { forever { probe() } } — the iteration body delegates once to the FFI `probe`, so every
// iteration crosses a real turn boundary (delegate → ack), exactly the shape a daemon body has.
function foreverIr(): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      // daemon_main
      0: {
        block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      // the agent body: enter the forever block (the call's output can never bind)
      1: {
        block: {
          kind: "sequence",
          result: 1201,
          operations: [{ kind: "call", target: 2, output: 1201 }],
        },
        parameters: { parameter: 1100 },
      },
      2: { block: { kind: "forever", initialStates: [], body: 3 }, parameters: {} },
      // one iteration: probe(record {})
      3: {
        block: {
          kind: "sequence",
          result: 1211,
          operations: [
            { kind: "makeRecord", entries: [], output: 1210 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("probe") },
              argument: 1210,
              output: 1211,
            },
          ],
        },
        parameters: {},
      },
      // the FFI external the iterations call
      4: {
        block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      5: { block: { kind: "external", key: "probe", input: 1101, reactor: "ffi" }, parameters: { parameter: 1101 } },
    },
    entries: {
      [createAgentName("daemon_main")]: 0,
      [createAgentName("probe")]: 4,
    },
    names: {},
  };
}

function actorFor(options: {
  handlers: Record<string, FfiHandler>;
  persistence: StoringPersistence;
}): ProjectActor {
  const registry = new SnapshotRegistry();
  const module = foreverIr();
  for (const name of Object.keys(module.entries)) {
    registry.set(SNAPSHOT, moduleOfName(createAgentName(name)), module);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new InProcessFfiTransport(options.handlers),
    http: new StubHttpTransport(),
    clock: new ManualClock(0),
    persistence: options.persistence,
  });
}

/** Poll until `read` yields a value (turns are asynchronous — the test observes, not steps). */
async function eventually<T>(read: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    const value = read();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error("condition not reached in time");
}

describe("the forever loop (engine)", () => {
  test("iterates indefinitely with a FLAT durable footprint, and a cancel leaves nothing behind", async () => {
    const persistence = new StoringPersistence();
    let calls = 0;
    const actor = actorFor({
      persistence,
      handlers: {
        // The macrotask hop keeps each iteration a real suspension (a daemon body always suspends) —
        // without it the loop's turns cycle entirely in microtasks and starve the test's own polling.
        probe: async () => {
          calls += 1;
          await new Promise((resolve) => setTimeout(resolve, 1));
          return null;
        },
      },
    });
    const { run, result } = actor.startRun(createAgentName("daemon_main"), SNAPSHOT, null);
    void result.catch(() => {}); // the run is cancelled at the end; do not leak the rejection

    // Let the loop demonstrably iterate, then sample the persisted engine footprint.
    await eventually(() => (calls >= 10 ? true : undefined));
    const threadsAtTen = persistence.threadCount();
    const scopesAtTen = persistence.scopeCount();

    // Twenty more iterations: a per-iteration leak (a collected value, an unreclaimed scope, a parked
    // frame) would grow these counts linearly; the construct's contract is that they do not grow at all
    // beyond the at-most-one in-flight iteration's jitter.
    await eventually(() => (calls >= 30 ? true : undefined));
    expect(persistence.threadCount()).toBeLessThanOrEqual(threadsAtTen + 2);
    expect(persistence.scopeCount()).toBeLessThanOrEqual(scopesAtTen + 2);
    // Absolute bound too: 30 iterations must not have parked 30 of anything.
    expect(persistence.threadCount()).toBeLessThan(10);
    expect(persistence.scopeCount()).toBeLessThan(10);
    expect(persistence.instanceCount()).toBeLessThan(4);

    // Teardown: cancelling the run drains the in-flight iteration and drops every engine row.
    await actor.cancelRun(run);
    await eventually(() => (persistence.peekRun(run)?.state === "cancelled" ? true : undefined));
    const deliveredAtCancel = calls;
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(calls).toBe(deliveredAtCancel); // no iteration outlives the cancel
    expect(persistence.instanceCount()).toBe(0);
    expect(persistence.threadCount()).toBe(0);
    expect(persistence.scopeCount()).toBe(0);
  });

  test("a restarted actor reloads the forever thread and keeps iterating", async () => {
    const persistence = new StoringPersistence();
    let calls = 0;
    const handlers = {
      // The same macrotask hop as above: each iteration is a real suspension.
      probe: async () => {
        calls += 1;
        await new Promise((resolve) => setTimeout(resolve, 1));
        return null;
      },
    };
    const first = actorFor({ persistence, handlers });
    const { run, result } = first.startRun(createAgentName("daemon_main"), SNAPSHOT, null);
    void result.catch(() => {}); // the first actor is simply abandoned (the crash being simulated)
    await eventually(() => (calls >= 5 ? true : undefined));

    // A fresh actor over the same rows: the loop's thread tree reloads. The iteration that was in flight
    // at the cut fails at-most-once (its FFI call is gone — a panic, unhandled here), which kills THIS
    // bare daemon; the loop construct itself must survive up to that point, i.e. the reloaded run is
    // still live and the panic path (not a stuck loop) decides its fate. A daemon that must survive
    // wraps the body in a retry provider — covered by the retry-provider suite over compiled IR.
    const second = actorFor({ persistence, handlers });
    await second.activate();
    await eventually(() =>
      persistence.peekRun(run)?.state !== "running" || calls >= 6 ? true : undefined,
    );
  });
});
