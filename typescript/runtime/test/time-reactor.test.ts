// End-to-end tests for the `time` reactor, driven through the whole ProjectActor with a controllable
// `ManualClock` (no real waits). A hand-built program calls `prelude.time.{now,sleep,watch}`; the reactor
// records the instant / arms the durable timer / fires deliver_to per occurrence, and its state persists in
// `time_instances` so a fresh actor over the same rows re-arms it.
//
// Covered: `now` records the clock's instant; `sleep` resolves at its deadline; `sleep` re-arms after a
// simulated restart; a deadline that passed while the runtime was down resolves immediately on recovery;
// `watch` delivers ticks for both the interval and cron schedule variants; a restart across missed
// occurrences fires exactly ONE catch-up then continues on schedule; cancel tears the watch down; and a
// deliver_to failure kills the watch.

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor, RunCancelledError } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { ManualClock, MAX_TIMER_DELAY_MS } from "../src/runtime/external/clock.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { type FfiHandler, InProcessFfiTransport } from "../src/runtime/external/runner.js";
import type { InstanceId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-time" as ProjectId;
const SNAPSHOT = "snapshot-time" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };
/** A round epoch (divisible by 1000, so the per-second cron lands on clean boundaries). */
const BASE = 1_700_000_000_000;

// A hand-built module exercising every time surface. Each agent's body is a sequence whose parameter is the
// agent's argument; the `prelude.time.*` externals carry their compiled fully-qualified key (what the reactor
// dispatches on), and the `deliver_to` agents forward each tick into an in-process FFI handler the test
// observes.
function timeIr(): IRModule {
  const agent = (body: number) => ({
    block: { kind: "agent" as const, body, schema: EMPTY_SCHEMA, description: "", defaults: {} },
    parameters: {},
  });
  const external = (key: string, input: number, reactor: "time" | "ffi") => ({
    block: { kind: "external" as const, key, input, reactor },
    parameters: { parameter: input },
  });
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      // now_main() { time.now() }
      0: agent(1),
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 1200 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.time.now") },
              argument: 1200,
              output: 1201,
            },
            { kind: "exit", target: 0, value: 1201 },
          ],
        },
        parameters: { parameter: 1100 },
      },
      // sleep_main(milliseconds) { time.sleep(milliseconds = milliseconds) }
      2: agent(3),
      3: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 1101, field: "milliseconds", output: 1210 },
            { kind: "makeRecord", entries: [["milliseconds", 1210]], output: 1211 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.time.sleep") },
              argument: 1211,
              output: 1212,
            },
            { kind: "exit", target: 2, value: 1212 },
          ],
        },
        parameters: { parameter: 1101 },
      },
      // watch_main(schedule) { time.watch(schedule = schedule, deliver_to = tick_agent) }
      4: agent(5),
      5: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 1102, field: "schedule", output: 1220 },
            { kind: "loadAgent", output: 1221, name: createAgentName("tick_agent") },
            {
              kind: "makeRecord",
              entries: [
                ["schedule", 1220],
                ["deliver_to", 1221],
              ],
              output: 1222,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.time.watch") },
              argument: 1222,
              output: 1223,
            },
            { kind: "exit", target: 4, value: 1223 },
          ],
        },
        parameters: { parameter: 1102 },
      },
      // watch_fail_main(schedule) { time.watch(schedule = schedule, deliver_to = boom_agent) }
      6: agent(7),
      7: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 1103, field: "schedule", output: 1230 },
            { kind: "loadAgent", output: 1231, name: createAgentName("boom_agent") },
            {
              kind: "makeRecord",
              entries: [
                ["schedule", 1230],
                ["deliver_to", 1231],
              ],
              output: 1232,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.time.watch") },
              argument: 1232,
              output: 1233,
            },
            { kind: "exit", target: 6, value: 1233 },
          ],
        },
        parameters: { parameter: 1103 },
      },
      // tick_agent(time) { record_tick(time = time) }
      8: agent(9),
      9: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 1104, field: "time", output: 1240 },
            { kind: "makeRecord", entries: [["time", 1240]], output: 1241 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("record_tick") },
              argument: 1241,
              output: 1242,
            },
            { kind: "exit", target: 8, value: 1242 },
          ],
        },
        parameters: { parameter: 1104 },
      },
      // boom_agent(time) { boom(time = time) }
      10: agent(11),
      11: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 1105, field: "time", output: 1250 },
            { kind: "makeRecord", entries: [["time", 1250]], output: 1251 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("boom") },
              argument: 1251,
              output: 1252,
            },
            { kind: "exit", target: 10, value: 1252 },
          ],
        },
        parameters: { parameter: 1105 },
      },
      // The reactor-backed externals (the compiled key is the fully-qualified name).
      12: agent(13),
      13: external("prelude.time.now", 1106, "time"),
      14: agent(15),
      15: external("prelude.time.sleep", 1107, "time"),
      16: agent(17),
      17: external("prelude.time.watch", 1108, "time"),
      // The FFI externals the deliver_to agents forward ticks into.
      18: agent(19),
      19: external("record_tick", 1109, "ffi"),
      20: agent(21),
      21: external("boom", 1110, "ffi"),
    },
    entries: {
      [createAgentName("now_main")]: 0,
      [createAgentName("sleep_main")]: 2,
      [createAgentName("watch_main")]: 4,
      [createAgentName("watch_fail_main")]: 6,
      [createAgentName("tick_agent")]: 8,
      [createAgentName("boom_agent")]: 10,
      [createAgentName("prelude.time.now")]: 12,
      [createAgentName("prelude.time.sleep")]: 14,
      [createAgentName("prelude.time.watch")]: 16,
      [createAgentName("record_tick")]: 18,
      [createAgentName("boom")]: 20,
    },
    names: {},
  };
}

function actorFor(options: {
  clock: ManualClock;
  handlers?: Record<string, FfiHandler>;
  persistence?: StoringPersistence;
}): ProjectActor {
  const registry = new SnapshotRegistry();
  const module = timeIr();
  for (const name of Object.keys(module.entries)) {
    registry.set(SNAPSHOT, moduleOfName(createAgentName(name)), module);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new InProcessFfiTransport(options.handlers ?? {}),
    http: new StubHttpTransport(),
    clock: options.clock,
    persistence: options.persistence ?? new InMemoryPersistence(),
  });
}

/** Poll until `read` yields a value (reactor turns are asynchronous — the test observes, not steps). */
async function eventually<T>(read: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 500; attempt += 1) {
    const value = read();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error("condition not reached in time");
}

/** A `deliver_to` FFI handler that appends each tick's scheduled epoch ms to `ticks` and resolves — so the
 *  serialized watch advances to the next occurrence. */
function recordingHandlers(ticks: number[]): Record<string, FfiHandler> {
  return {
    record_tick: (argument) => {
      const time = argument !== null && typeof argument === "object" ? argument : {};
      ticks.push(Number((time as { time?: unknown }).time));
      return null;
    },
    // A deliver_to that always fails (a thrown JS error is an infrastructure panic that kills the watch).
    boom: () => {
      throw new Error("deliver_to blew up");
    },
  };
}

function scheduleValue(operation: Value): Value {
  return { kind: "record", fields: { schedule: operation } };
}

function interval(milliseconds: number): Value {
  return {
    kind: "record",
    ctor: createAgentName("prelude.time.interval"),
    fields: { milliseconds: { kind: "number", value: milliseconds } },
  };
}

function cron(expression: string, timezone: string): Value {
  return {
    kind: "record",
    ctor: createAgentName("prelude.time.cron"),
    fields: {
      expression: { kind: "string", value: expression },
      timezone: { kind: "string", value: timezone },
    },
  };
}

describe("the time reactor — now and sleep", () => {
  test("now resolves with the clock's current instant (recorded, not recomputed)", async () => {
    const clock = new ManualClock(BASE);
    const actor = actorFor({ clock });
    const { result } = actor.startRun(createAgentName("now_main"), SNAPSHOT, null);
    const value = await result;
    // A whole-millisecond instant decodes as `integer` (a subtype of the declared `number`).
    expect(value).toEqual({ kind: "integer", value: BASE });
  });

  test("sleep resolves with null at its deadline, not before", async () => {
    const clock = new ManualClock(BASE);
    const actor = actorFor({ clock });
    const { result } = actor.startRun(
      createAgentName("sleep_main"),
      SNAPSHOT,
      { kind: "record", fields: { milliseconds: { kind: "number", value: 100 } } },
    );
    // The durable timer is armed asynchronously; wait for it, then confirm the sleep does not resolve early.
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));
    let settled = false;
    void result.then(() => {
      settled = true;
    });
    clock.advanceBy(60);
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(settled).toBe(false);
    clock.advanceBy(40);
    expect(await result).toEqual({ kind: "null" });
  });
});

describe("the time reactor — deadlines past the setTimeout ceiling", () => {
  // Node coerces a setTimeout delay past 2^31-1 ms to 1 ms, so a raw arm would fire a ~25-day-plus sleep
  // immediately (a runaway loop for a sparse watch). The reactor must hop in bounded chunks instead; the
  // `Clock` contract itself rejects an over-ceiling delay, so this test throws loudly if the chunking is
  // ever removed.
  test("a sleep farther out than one timer may carry hops in chunks and fires only at its deadline", async () => {
    const fortyDays = 40 * 24 * 60 * 60 * 1000; // comfortably past the ~24.8-day ceiling
    const clock = new ManualClock(BASE);
    const actor = actorFor({ clock });
    const { result } = actor.startRun(
      createAgentName("sleep_main"),
      SNAPSHOT,
      { kind: "record", fields: { milliseconds: { kind: "number", value: fortyDays } } },
    );
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));
    let settled = false;
    void result.then(() => {
      settled = true;
    });
    // Cross the first chunk boundary: the wake is short of the deadline, so the reactor re-arms the
    // remainder rather than firing.
    clock.advanceBy(MAX_TIMER_DELAY_MS);
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(settled).toBe(false);
    expect(clock.pendingCount()).toBe(1);
    // Cross the true deadline: the re-armed remainder fires and the sleep resolves.
    clock.advanceTo(BASE + fortyDays);
    expect(await result).toEqual({ kind: "null" });
  });
});

describe("the time reactor — sleep durability", () => {
  test("a sleep re-arms after a restart and fires at its persisted deadline", async () => {
    const persistence = new StoringPersistence();
    const clock1 = new ManualClock(BASE);
    const first = actorFor({ clock: clock1, persistence });
    const { run } = first.startRun(
      createAgentName("sleep_main"),
      SNAPSHOT,
      { kind: "record", fields: { milliseconds: { kind: "number", value: 200 } } },
    );
    await eventually(() => (clock1.pendingCount() > 0 ? true : undefined));

    // Restart: a fresh actor over the same rows, its clock only 50ms past the start (deadline not yet due).
    const clock2 = new ManualClock(BASE + 50);
    const second = actorFor({ clock: clock2, persistence });
    await second.activate();
    await eventually(() => (clock2.pendingCount() > 0 ? true : undefined));
    expect(persistence.peekRun(run)?.state).toBe("running");

    // Cross the persisted deadline (BASE + 200) — the re-armed timer fires and the run completes.
    clock2.advanceBy(200);
    await eventually(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.envelopeCount("time")).toBe(0);
  });

  test("a deadline that passed while the runtime was down resolves immediately on recovery", async () => {
    const persistence = new StoringPersistence();
    const clock1 = new ManualClock(BASE);
    const first = actorFor({ clock: clock1, persistence });
    const { run } = first.startRun(
      createAgentName("sleep_main"),
      SNAPSHOT,
      { kind: "record", fields: { milliseconds: { kind: "number", value: 200 } } },
    );
    await eventually(() => (clock1.pendingCount() > 0 ? true : undefined));

    // Restart with the clock already well past the deadline — recovery must fire at once, no advance needed.
    const clock2 = new ManualClock(BASE + 10_000);
    const second = actorFor({ clock: clock2, persistence });
    await second.activate();
    clock2.advanceBy(0); // flush the delay-0 (already-due) timer the recovery armed
    await eventually(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.envelopeCount("time")).toBe(0);
  });
});

describe("the time reactor — watch", () => {
  test("delivers a tick per occurrence for a fixed interval", async () => {
    const clock = new ManualClock(BASE);
    const ticks: number[] = [];
    const actor = actorFor({ clock, handlers: recordingHandlers(ticks) });
    const { run, result } = actor.startRun(
      createAgentName("watch_main"),
      SNAPSHOT,
      scheduleValue(interval(25)),
    );
    void result.catch(() => {}); // the run is cancelled at the end; do not leak the rejection
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));

    clock.advanceBy(25);
    await eventually(() => (ticks.length >= 1 ? true : undefined));
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined)); // the next occurrence re-armed
    clock.advanceBy(25);
    await eventually(() => (ticks.length >= 2 ? true : undefined));
    // Interval ticks are phase-anchored to the start (first tick one interval in).
    expect(ticks.slice(0, 2)).toEqual([BASE + 25, BASE + 50]);

    await actor.cancelRun(run).catch(() => {});
  });

  test("delivers a tick per occurrence for a cron schedule (with an explicit timezone)", async () => {
    const clock = new ManualClock(BASE);
    const ticks: number[] = [];
    const actor = actorFor({ clock, handlers: recordingHandlers(ticks) });
    const { run, result } = actor.startRun(
      createAgentName("watch_main"),
      SNAPSHOT,
      scheduleValue(cron("* * * * * *", "UTC")), // every second
    );
    void result.catch(() => {}); // the run is cancelled at the end; do not leak the rejection
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));

    clock.advanceBy(1000);
    await eventually(() => (ticks.length >= 1 ? true : undefined));
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));
    clock.advanceBy(1000);
    await eventually(() => (ticks.length >= 2 ? true : undefined));
    expect(ticks.slice(0, 2)).toEqual([BASE + 1000, BASE + 2000]);

    await actor.cancelRun(run).catch(() => {});
  });

  test("a restart across missed occurrences fires exactly one catch-up, then continues on schedule", async () => {
    const persistence = new StoringPersistence();
    const clock1 = new ManualClock(BASE);
    const ticksBefore: number[] = [];
    const first = actorFor({
      clock: clock1,
      handlers: recordingHandlers(ticksBefore),
      persistence,
    });
    first.startRun(createAgentName("watch_main"), SNAPSHOT, scheduleValue(interval(25)));
    // The first occurrence (BASE + 25) is persisted; nothing has fired yet.
    await eventually(() => (clock1.pendingCount() > 0 ? true : undefined));
    expect(ticksBefore).toEqual([]);

    // Restart 10 intervals later — many occurrences were "missed" while down.
    const clock2 = new ManualClock(BASE + 250);
    const ticks: number[] = [];
    const second = actorFor({ clock: clock2, handlers: recordingHandlers(ticks), persistence });
    await second.activate();
    clock2.advanceBy(0); // flush the immediate catch-up the recovery armed

    // Exactly ONE catch-up — the earliest missed occurrence — not a backfill of every missed one.
    await eventually(() => (ticks.length >= 1 ? true : undefined));
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(ticks).toEqual([BASE + 25]);

    // Then it continues on the original phase (the next occurrence strictly after the recovery instant).
    await eventually(() => (clock2.pendingCount() > 0 ? true : undefined));
    clock2.advanceBy(25);
    await eventually(() => (ticks.length >= 2 ? true : undefined));
    expect(ticks).toEqual([BASE + 25, BASE + 275]);
  });

  test("cancelling the run tears the watch down (no further ticks, no leftover state)", async () => {
    const persistence = new StoringPersistence();
    const clock = new ManualClock(BASE);
    const ticks: number[] = [];
    const actor = actorFor({ clock, handlers: recordingHandlers(ticks), persistence });
    const { run, result } = actor.startRun(
      createAgentName("watch_main"),
      SNAPSHOT,
      scheduleValue(interval(25)),
    );
    void result.catch(() => {});
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));
    clock.advanceBy(25);
    await eventually(() => (ticks.length >= 1 ? true : undefined));

    await actor.cancelRun(run);
    await eventually(() => (persistence.peekRun(run)?.state === "cancelled" ? true : undefined));
    // The endpoint is gone: advancing time delivers nothing more, and no time instance survives.
    const delivered = ticks.length;
    clock.advanceBy(1000);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(ticks.length).toBe(delivered);
    expect(persistence.envelopeCount("time")).toBe(0);
  });

  test("a deliver_to failure propagates and kills the watch", async () => {
    const persistence = new StoringPersistence();
    const clock = new ManualClock(BASE);
    const ticks: number[] = [];
    const actor = actorFor({ clock, handlers: recordingHandlers(ticks), persistence });
    const { run, result } = actor.startRun(
      createAgentName("watch_fail_main"),
      SNAPSHOT,
      scheduleValue(interval(25)),
    );
    const settled = result.then(
      () => "resolved",
      (error) => (error instanceof RunCancelledError ? "cancelled" : "error"),
    );
    await eventually(() => (clock.pendingCount() > 0 ? true : undefined));

    clock.advanceBy(25); // the first tick fires deliver_to, which panics
    await eventually(() => (persistence.peekRun(run)?.state === "error" ? true : undefined));
    expect(await settled).toBe("error");
    expect(persistence.envelopeCount("time")).toBe(0);
  });
});
