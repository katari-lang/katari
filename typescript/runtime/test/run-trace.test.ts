// The execution trace: every external event a run's turns produce is journaled (`run_events`) in the
// same commit that sends it, stamped with the run's id (its permanent run instance). These tests drive
// hand-built IR through the ProjectActor over a StoringPersistence and assert the journaled stream —
// the trace's exactly-once, ordering, and attribution — plus the pure read-side projection.

import {
  createAgentName,
  type IRModule,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { projectRunEvent } from "../src/modules/run/run-events.repository.js";
import { ProjectActor, RunCancelledError } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { DelegationId, InstanceId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-trace" as ProjectId;
const SNAPSHOT = "snapshot-trace" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

function makeActor(ir: IRModule, persistence: StoringPersistence): ProjectActor {
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
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

/** agent main() { 7 } */
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

/** agent main() { ask_value({}) } — the request escapes the run root, awaiting a user's answer. */
function runRootRequestIr(): IRModule {
  return {
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
}

describe("run trace journal", () => {
  test("a run's events are journaled in causal order, all stamped with the run's id", async () => {
    const persistence = new StoringPersistence();
    const actor = makeActor(constantIr(), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await expect(result).resolves.toEqual({ kind: "integer", value: 7 });

    const events = persistence.journalFor(run);
    expect(events.map((event) => event.kind)).toEqual(["delegate", "delegateAck"]);
    // Every event carries the run's own id (the trace context), and the whole exchange rides one
    // delegation — which is NOT the run id (the run is its instance; the delegation is the live edge).
    for (const event of events) expect(event.run).toBe(run);
    const [delegate, delegateAck] = events;
    if (delegate?.kind !== "delegate" || delegateAck?.kind !== "delegateAck") {
      throw new Error("journal shape mismatch");
    }
    expect(delegate.target).toEqual({
      kind: "named",
      name: createAgentName("main"),
      snapshot: SNAPSHOT,
    });
    expect(delegate.delegation).not.toBe(run);
    expect(delegateAck.delegation).toBe(delegate.delegation);
    expect(delegateAck.value).toEqual({ kind: "integer", value: 7 });
    // The journal outlives the outbox: the delivery rows drained to empty, the trace remains.
    await waitUntil(() => (persistence.outboxSize() === 0 ? true : undefined));
    expect(persistence.journalFor(run)).toHaveLength(2);
  });

  test("an escalation's round trip (escalate → escalateAck) is journaled under the run", async () => {
    const persistence = new StoringPersistence();
    const actor = makeActor(runRootRequestIr(), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const open = await waitUntil(() => {
      const list = actor.listOpenEscalations();
      return list.length > 0 ? list : undefined;
    });
    const escalation = open[0]?.escalation;
    if (escalation === undefined) throw new Error("no open escalation");
    await actor.answerEscalation(escalation, { kind: "integer", value: 42 });
    await expect(result).resolves.toEqual({ kind: "integer", value: 42 });

    const kinds = persistence.journalFor(run).map((event) => event.kind);
    // delegate main → delegate ask_value (the request leaf is a child instance) → the request escapes
    // hop by hop (leaf → main's instance, then main's root → api), the answer descends the same two
    // hops, the leaf returns, and main returns. The trace records each hop — that is the point.
    expect(kinds).toEqual([
      "delegate",
      "delegate",
      "escalate",
      "escalate",
      "escalateAck",
      "escalateAck",
      "delegateAck",
      "delegateAck",
    ]);
    for (const event of persistence.journalFor(run)) expect(event.run).toBe(run);
  });

  test("a cancel's terminate cascade is journaled under the run", async () => {
    const persistence = new StoringPersistence();
    const actor = makeActor(runRootRequestIr(), persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => (actor.listOpenEscalations().length > 0 ? true : undefined));
    await actor.cancelRun(run, "user requested");
    await expect(result).rejects.toBeInstanceOf(RunCancelledError);

    const kinds = persistence.journalFor(run).map((event) => event.kind);
    expect(kinds.filter((kind) => kind === "terminate").length).toBeGreaterThan(0);
    expect(kinds[kinds.length - 1]).toBe("terminateAck");
    for (const event of persistence.journalFor(run)) expect(event.run).toBe(run);
  });
});

describe("leaf call inlining", () => {
  /** agent main() { box(value = add(left = 2, right = 3)) } — where `add` is a primitive-bodied
   *  agent and `box` a constructor, both in the foreign "leaf" module. Pre-inlining this journaled
   *  THREE delegations (main, add, box — 6+ events); inlined, only main's own delegate/ack remain. */
  function leafCallIr(): { main: IRModule; leaf: IRModule } {
    const main: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: {
          block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} },
          parameters: {},
        },
        1: {
          block: {
            kind: "sequence",
            result: 25,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 2 } },
              { kind: "loadLiteral", output: 21, value: { kind: "integer", value: 3 } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 20],
                  ["right", 21],
                ],
                output: 22,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("leaf.add") },
                argument: 22,
                output: 23,
              },
              { kind: "makeRecord", entries: [["value", 23]], output: 24 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("leaf.box") },
                argument: 24,
                output: 25,
              },
            ],
          },
          parameters: { parameter: 11 },
        },
      },
      entries: { [createAgentName("main")]: { block: 0, private: false } },
      names: {},
    };
    const leaf: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: {
          block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} },
          parameters: {},
        },
        1: { block: { kind: "primitive", name: "prelude.add", input: 30 }, parameters: { parameter: 30 } },
        2: {
          block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, defaults: {} },
          parameters: {},
        },
        3: {
          block: { kind: "construct", name: createAgentName("leaf.box"), input: 40 },
          parameters: { parameter: 40 },
        },
      },
      entries: {
        [createAgentName("leaf.add")]: { block: 0, private: false },
        [createAgentName("leaf.box")]: { block: 2, private: false },
      },
      names: {},
    };
    return { main, leaf };
  }

  test("a primitive/constructor-bodied callee runs in-instance: no delegation, no journal rows", async () => {
    const persistence = new StoringPersistence();
    const { main, leaf } = leafCallIr();
    const registry = new SnapshotRegistry();
    registry.set(SNAPSHOT, "", main);
    registry.set(SNAPSHOT, "leaf", leaf);
    const actor = new ProjectActor({
      projectId: PROJECT,
      ir: registry,
      prims: new PrimRegistry(),
      blobs: new InMemoryBlobStore(),
      external: new StubFfiTransport(),
      http: new StubHttpTransport(),
      persistence,
    });
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // The whole pipeline computed: add ran as an in-instance prim, box tagged the record in place.
    await expect(result).resolves.toEqual({
      kind: "record",
      ctor: createAgentName("leaf.box"),
      fields: { value: { kind: "integer", value: 5 } },
    });
    // The journal carries ONLY the run's own delegation — the leaf calls never crossed an instance
    // boundary, so they produced no events (and no instance / outbox / delegation rows).
    expect(persistence.journalFor(run).map((event) => event.kind)).toEqual([
      "delegate",
      "delegateAck",
    ]);
  });
});

describe("run event projection", () => {
  const RUN = "run-instance" as InstanceId;
  const DELEGATION = "delegation-1234abcd-rest" as DelegationId;

  function row(event: ExternalEvent) {
    return { seq: 1, event, createdAt: new Date("2026-07-06T12:00:00Z") };
  }

  test("a delegate projects its target, argument, and a correlatable summary", () => {
    const view = projectRunEvent(
      row({
        kind: "delegate",
        delegation: DELEGATION,
        target: { kind: "named", name: createAgentName("main"), snapshot: SNAPSHOT },
        argument: { kind: "integer", value: 1 },
        from: "api",
        to: "core",
        run: RUN,
      }),
    );
    expect(view.kind).toBe("delegate");
    expect(view.target).toEqual({ kind: "agent", name: createAgentName("main") });
    expect(view.payload).toBe(1);
    expect(view.summary).toBe("delegate api→core main [delegati]");
  });

  test("an escalate projects its ask / request and redacts a private payload", () => {
    const view = projectRunEvent(
      row({
        kind: "escalate",
        delegation: DELEGATION,
        escalation: "escalation-9876fedc-rest" as never,
        ask: {
          kind: "request",
          request: createAgentName("ask_value"),
          argument: { kind: "string", value: "s3cret", private: true },
        },
        from: "core",
        to: "api",
        run: RUN,
      }),
    );
    expect(view.ask).toBe("request");
    expect(view.request).toBe(createAgentName("ask_value"));
    // The user-facing boundary: a private value degrades to the redaction marker, never the secret.
    expect(JSON.stringify(view.payload)).not.toContain("s3cret");
    expect(view.summary).toBe("escalate core→api request ask_value [delegati/escalati]");
  });

  test("a terminate leg carries no payload", () => {
    const view = projectRunEvent(
      row({
        kind: "terminateAck",
        delegation: DELEGATION,
        from: "core",
        to: "api",
        run: RUN,
      }),
    );
    expect(view.payload).toBeNull();
    expect(view.escalationId).toBeNull();
    expect(view.summary).toBe("terminateAck core→api [delegati]");
  });
});
