// The `prelude.retry` providers driven end to end over their REAL compiled IR — the standing net behind
// the "re-invocation works" claim, which previously rested on a throwaway probe. The fixture
// (`test/fixtures/retry_probe/`) is a tiny katari project whose `ir.json` is committed alongside it;
// regenerate after a compiler / stdlib change with:
//
//   cd haskell && stack exec katari -- build -C ../typescript/runtime/test/fixtures/retry_probe \
//     -o ../typescript/runtime/test/fixtures/retry_probe/ir.json
//
// (The suite fails loudly on drift — a stale fixture cannot silently pass.) Covered here:
//   (a) `retry.forever` catches BOTH failure channels (a typed FFI throw, then a JS-error panic), backs
//       off through real durable `time.sleep` timers on a ManualClock, and the continuation's eventual
//       success value escapes the loop and returns.
//   (b) `retry.attended`, unhandled: a failure performs `retry.attention`, which surfaces as an OPEN
//       run-root escalation; answering it through the same facade the escalation service uses re-runs
//       the block, and the re-run's success value returns.
//   (c) `retry.attended`, intercepted: an application handler answers `attention` with `next null`, so
//       failures re-run immediately and nothing ever escalates.

import { readFileSync } from "node:fs";
import { createAgentName, type IRModule } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { ManualClock } from "../src/runtime/external/clock.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type FfiHandler,
  FfiThrow,
  InProcessFfiTransport,
} from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-retry" as ProjectId;
const SNAPSHOT = "snapshot-retry" as SnapshotId;

/** The compiled fixture: module name -> IRModule, exactly what `katari build` wrote. */
const COMPILED: Record<string, IRModule> = JSON.parse(
  readFileSync(new URL("./fixtures/retry_probe/ir.json", import.meta.url), "utf8"),
);

function actorFor(options: { clock: ManualClock; handlers: Record<string, FfiHandler> }): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const [moduleName, moduleIr] of Object.entries(COMPILED)) {
    registry.set(SNAPSHOT, moduleName, moduleIr);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new InProcessFfiTransport(options.handlers),
    http: new StubHttpTransport(),
    clock: options.clock,
    persistence: new InMemoryPersistence(),
  });
}

/** Poll until `read` yields a value (reactor turns are asynchronous — the test observes, not steps). */
async function eventually<T>(read: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt += 1) {
    const value = read();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error("condition not reached in time");
}

/** A probe that fails through `plan` (one entry per call: a typed throw or a panic) then succeeds. */
function scriptedProbe(plan: Array<"throw" | "panic">, success: string): {
  handler: FfiHandler;
  calls: () => number;
} {
  let calls = 0;
  return {
    calls: () => calls,
    handler: () => {
      calls += 1;
      const step = plan[calls - 1];
      if (step === "throw") throw new FfiThrow({ attempt: calls });
      if (step === "panic") throw new Error(`probe panic on attempt ${calls}`);
      return success;
    },
  };
}

/** Drive the ManualClock across the provider's durable backoff sleeps until `settled` reports true. */
async function advanceThroughBackoffs(clock: ManualClock, settled: () => boolean): Promise<void> {
  for (let round = 0; round < 100 && !settled(); round += 1) {
    await eventually(() => (settled() || clock.pendingCount() > 0 ? true : undefined));
    if (settled()) return;
    clock.advanceBy(50); // comfortably past the capped 5/10/20ms backoff ladder
  }
}

describe("prelude.retry over compiled IR", () => {
  test("forever catches both failure channels, sleeps its backoff, and returns the eventual success", async () => {
    const clock = new ManualClock(1_700_000_000_000);
    // One typed throw, then one panic: both channels must fold into `failed` and be retried.
    const probe = scriptedProbe(["throw", "panic"], "forever ready");
    const actor = actorFor({ clock, handlers: { "retry_probe.probe": probe.handler } });
    const { result } = actor.startRun(createAgentName("retry_probe.forever_main"), SNAPSHOT, null);
    let value: Value | undefined;
    void result.then((resolved) => {
      value = resolved;
    });
    await advanceThroughBackoffs(clock, () => value !== undefined);
    expect(value).toEqual({ kind: "string", value: "forever ready" });
    expect(probe.calls()).toBe(3);
  });

  test("attended, unhandled: a failure parks as an open attention question; answering re-runs to success", async () => {
    const clock = new ManualClock(1_700_000_000_000);
    const probe = scriptedProbe(["throw"], "attended ready");
    const actor = actorFor({ clock, handlers: { "retry_probe.probe": probe.handler } });
    const { result } = actor.startRun(createAgentName("retry_probe.attended_main"), SNAPSHOT, null);
    let value: Value | undefined;
    void result.then((resolved) => {
      value = resolved;
    });

    // The failure surfaces as an open run-root escalation carrying the attention request.
    const open = await eventually(() => {
      const escalations = actor.listOpenEscalations();
      return escalations.length > 0 ? escalations[0] : undefined;
    });
    expect(open.request).toBe("prelude.retry.attention");
    expect(value).toBeUndefined(); // the run is parked, not failed

    // Answer through the same facade the escalation service uses: attention answers `null`, re-running
    // the block; the probe now succeeds and the success value comes back.
    await actor.answerEscalation(open.escalation, { kind: "null" });
    await eventually(() => (value !== undefined ? true : undefined));
    expect(value).toEqual({ kind: "string", value: "attended ready" });
    expect(probe.calls()).toBe(2);
    expect(actor.listOpenEscalations()).toEqual([]);
  });

  test("attended, intercepted: an application handler answers `next null`, so re-runs happen without escalation", async () => {
    const clock = new ManualClock(1_700_000_000_000);
    const probe = scriptedProbe(["throw", "throw"], "intercepted ready");
    const actor = actorFor({ clock, handlers: { "retry_probe.probe": probe.handler } });
    const { result } = actor.startRun(
      createAgentName("retry_probe.intercepted_main"),
      SNAPSHOT,
      null,
    );
    const value = await result;
    expect(value).toEqual({ kind: "string", value: "intercepted ready" });
    expect(probe.calls()).toBe(3);
    // Nothing ever escalated: the application handler consumed every attention in-process.
    expect(actor.listOpenEscalations()).toEqual([]);
  });
});
