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
});
