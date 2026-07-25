// Repro for the tsukasa rc9 crash: "internal error: scope not found: N".
//
// Shape (the exact production topology, minimized):
//   main()  -> handle { request gate(cb) { next null } } around: delegate tool()
//   tool()  -> secret = "SECRET"; cb = <closure capturing tool's live scope>;
//              delegate gate({ cb });          // the approve_async twin: a request-bodied agent
//              "done"                          // tool CARRIES ON after the perform returns
//   gate()  -> body is a `request gate` block  // raises the ask from its own fresh instance
//
// What goes wrong today:
//   1. gate's instance escalates; the closure's captured scopes are owned by TOOL, so the raiser-side
//      release is a no-op for them (reactor.ts `send`/escalate).
//   2. The relay hop THROUGH tool re-raises the ask; tool's own send releases the carried value's
//      captured scopes FROM TOOL — i.e. tool's LIVE thread scope goes in-transit (owner = null).
//   3. main reowns the carried value (core-reactor onEscalate) — main now OWNS tool's live scope.
//   4. The handler answers `next null` and drops the payload; at main's turn boundary the
//      intra-instance GC frees the closure's chain (owned by main, unreachable from main).
//   5. gate's instance resumes, returns; the delegateAck's callAck writes the result into tool's
//      thread scope — which no longer exists. `getScope` throws "scope not found: N", the substrate
//      drops the turn and fails the run with "internal error: scope not found: N".
//
// A FIXED runtime resolves the run with "done" (and the parked/answered ask never steals the
// raiser-side instances' live scopes).

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-escalation-capture" as ProjectId;
const SNAPSHOT = "snapshot-escalation-capture" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

function escalationCaptureIr(): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      // main: enter the handle (block 20), return its value.
      0: {
        block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "call", target: 20, output: 12 },
            { kind: "exit", target: 0, value: 12 },
          ],
        },
        parameters: { parameter: 10 },
      },
      // The handle around the tool call: catches `gate`, answers null, retains NOTHING of the payload
      // (the production approval handler forks a fiber and answers at once — same drop of the ask).
      20: {
        block: {
          kind: "handle",
          parallel: false,
          initialStates: [],
          body: 21,
          handlers: [{ request: createAgentName("gate"), body: 22 }],
          thenClause: null,
        },
        parameters: {},
      },
      21: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "makeRecord", entries: [], output: 210 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("tool") },
              argument: 210,
              output: 211,
            },
            { kind: "exit", target: 20, value: 211 },
          ],
        },
        parameters: {},
      },
      // gate's handler: answer null immediately (the approve_async handler's `next null`).
      22: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 221, value: { kind: "null" } },
            { kind: "continue", target: 20, value: 221, modifiers: [] },
          ],
        },
        parameters: { parameter: 220 },
      },
      // tool (the send_to twin): bind a secret, capture it in a closure, delegate the request-bodied
      // `gate` agent with the closure, then CARRY ON (the callAck write after gate returns is the one
      // that lands in tool's — by then freed — thread scope).
      2: {
        block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      3: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "loadLiteral", output: 31, value: { kind: "string", value: "SECRET" } },
            { kind: "makeClosure", output: 32, agent: 6 },
            { kind: "makeRecord", entries: [["cb", 32]], output: 33 },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("gate") },
              argument: 33,
              output: 34,
            },
            { kind: "loadLiteral", output: 35, value: { kind: "string", value: "done" } },
            { kind: "exit", target: 2, value: 35 },
          ],
        },
        parameters: { parameter: 30 },
      },
      // gate: the approve_async twin — an agent whose body IS the `gate` request block, so delegating
      // to it raises the ask from a fresh instance ("raised under approval.approve_async").
      4: {
        block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      5: {
        block: { kind: "request", name: createAgentName("gate"), input: 50 },
        parameters: { parameter: 50 },
      },
      // cb (the on_decide twin): reads the captured variable 31. Never dispatched in this test — the
      // crash happens before any decision; its captured scope is what the escalation steals.
      6: {
        block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      7: {
        block: {
          kind: "sequence",
          result: null,
          operations: [{ kind: "exit", target: 6, value: 31 }],
        },
        parameters: { parameter: 70 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("tool")]: { block: 2, private: false },
      [createAgentName("gate")]: { block: 4, private: false },
    },
    names: {},
  };
}

function makeActor(persistence: StoringPersistence): ProjectActor {
  const ir = escalationCaptureIr();
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

describe("a closure riding a cross-instance escalation", () => {
  test("the raiser-side caller survives its ask being answered (its live scopes are not GC'd away)", async () => {
    const persistence = new StoringPersistence();
    const actor = makeActor(persistence);
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // Keep an unsettled promise from crashing the worker on a failed run.
    result.catch(() => {});

    const record = await waitUntil(() => {
      const stored = persistence.peekRun(run);
      return stored !== undefined && stored.state !== "running" ? stored : undefined;
    });

    // Correct behavior: the run completes with tool's "done". Today it fails with
    // "internal error: scope not found: N" — the pinned bug.
    expect(record.errorMessage ?? "").not.toMatch(/scope not found/);
    expect(record.state).toBe("done");
  }, 8000);
});
