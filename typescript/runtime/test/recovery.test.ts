// Recovery integration test: drive an actor to a durable suspend point (an in-flight external call),
// then resume the project in a *fresh* actor sharing the same StoringPersistence — exercising the whole
// recovery path (serialise at the turn boundary → reload → reactivate → rebuild routing → re-dispatch the
// open external → make progress past it). This is the first end-to-end test of `reactivate`; the codec
// round-trip test covers only the pure serialise/deserialise step.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { FfiResult } from "../src/runtime/event/types.js";
import type { ExternalCall, ExternalRunner } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { StubExternalRunner } from "../src/runtime/external/runner.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-recovery" as ProjectId;
const SNAPSHOT = "snapshot-recovery" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** A recording external runner: logs each dispatched key, and optionally completes some keys immediately
 *  (the others stay in flight forever, modelling a slow external call). */
function recordingRunner(complete: Record<string, boolean>): {
  runner: ExternalRunner;
  dispatched: string[];
} {
  const dispatched: string[] = [];
  let sink: ((result: FfiResult) => void) | null = null;
  const runner: ExternalRunner = {
    onResult(register) {
      sink = register;
    },
    dispatch(call: ExternalCall) {
      dispatched.push(call.key);
      if (complete[call.key]) {
        sink?.({
          kind: "ffiResult",
          instance: call.instance,
          thread: call.thread,
          value: { kind: "string", value: `${call.key}-done` },
        });
      }
    },
    cancel() {},
  };
  return { runner, dispatched };
}

function makeActor(
  ir: IRModule,
  persistence: StoringPersistence,
  external: ExternalRunner = new StubExternalRunner(),
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
      const edge = persistence.peekDelegation(run);
      return edge?.state === "done" ? edge : undefined;
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
    actorTwo.answerEscalation(escalation, { kind: "integer", value: 42 });
    const done = await waitUntil(() => {
      const edge = persistence.peekDelegation(run);
      return edge?.state === "done" ? edge : undefined;
    });
    expect(done.result).toEqual({ kind: "integer", value: 42 });
    expect(actorTwo.listOpenEscalations()).toHaveLength(0);
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
    // The failure is durable in Layer 1 by the time the run settles (recorded before the promise rejects).
    const edge = persistence.peekDelegation(run);
    expect(edge?.state).toBe("failed");
    expect(edge?.errorMessage).toMatch(/panic.*number/);
    // And the run's root instance (and its descendants) were torn down — nothing left suspended.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
  });
});
