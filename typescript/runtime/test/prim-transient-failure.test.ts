// A prim's failure is a THREE-way sum, and the runtime must not collapse it to two. `env.get_secret` /
// `env.get_all` read the project's env store INSIDE a react turn, so a transient DB blip there is the same
// retryable class as an IR-store blip — NOT a deterministic panic. The engine's prim seam rethrows a
// `TransientError` so the substrate replays the turn from durable state; a deterministic error (any other
// throw) stays a panic that fails the run.
//
// Both tests drive a run whose body is `prelude.env.get_all` over a stubbed `EnvReader`. The run's launch is
// seeded as a durable delegate (the shape a crash leaves behind — a retry drops the WARM state and replays
// from durable, so an in-memory `startRun` command would be lost by the very drop under test). A transient
// read then retries to completion; a deterministic one fails the run.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { type EnvReader, registerHostPrims } from "../src/runtime/engine/host-prims.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { TransientError } from "../src/runtime/engine/transient-error.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import {
  type InstanceId,
  newDelegationId,
  newInstanceId,
  newOutboxSeq,
  type ProjectId,
  type SnapshotId,
} from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-prim-transient" as ProjectId;
const SNAPSHOT = "snapshot-prim-transient" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

// agent main() { return read_env({}) }
// read_env is an agent whose body is the `prelude.env.get_all` primitive (a host I/O prim). `get_all` returns
// a PUBLIC record, so the run result crosses the user boundary without redaction.
const IR: IRModule = {
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
            target: { kind: "name", name: createAgentName("read_env") },
            argument: 20,
            output: 21,
          },
          { kind: "exit", target: 0, value: 21 },
        ],
      },
      parameters: { parameter: 11 },
    },
    6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
    7: {
      block: { kind: "primitive", name: "prelude.env.get_all", input: 8 },
      parameters: { parameter: 8 },
    },
  },
  entries: {
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("read_env")]: { block: 6, private: false },
  },
  names: {},
};

function makeActor(persistence: StoringPersistence, env: EnvReader): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(IR.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), IR);
  }
  const prims = new PrimRegistry();
  registerHostPrims(prims, { env });
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims,
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    persistence,
  });
}

/** Seed a durable run launch (delegation + `runs` row + the undelivered `delegate` in the outbox) — the state
 *  a crash leaves after `startRun` committed but before the run ran. `activate()` then replays it. */
function seedDurableRun(persistence: StoringPersistence): InstanceId {
  const run = newInstanceId();
  const delegation = newDelegationId();
  persistence.seedDelegation(delegation, { caller: run, fromReactor: "api", toReactor: "core" });
  persistence.seedRun(run, {
    name: "main",
    qualifiedName: createAgentName("main"),
    snapshotId: SNAPSHOT,
    argument: null,
  });
  persistence.seedOutbox({
    seq: newOutboxSeq(),
    event: {
      kind: "delegate",
      from: "api",
      to: "core",
      run,
      delegation,
      target: { kind: "named", name: createAgentName("main"), snapshot: SNAPSHOT },
      argument: null,
    },
  });
  return run;
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("prim transient infra failure", () => {
  test("a transient env-store failure retries the turn to completion (does NOT fail the run)", async () => {
    // The reader raises a TransientError on its first read (a DB blip), then succeeds. The runtime must drop +
    // reload + replay from durable state — not fail the run — so the second read lands and the run completes.
    let reads = 0;
    const env: EnvReader = {
      async readSecret() {
        return null;
      },
      async readPublic() {
        reads += 1;
        if (reads === 1) throw new TransientError("env store DB blip");
        return { HOST: "example.com" };
      },
    };
    const persistence = new StoringPersistence();
    const run = seedDurableRun(persistence);
    const actor = makeActor(persistence, env);
    await actor.activate();

    const done = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "done" ? record : undefined;
    });
    expect(done.result).toEqual({
      kind: "record",
      fields: { HOST: { kind: "string", value: "example.com" } },
    });
    // The read was retried: the first raise was transient, not terminal.
    expect(reads).toBeGreaterThanOrEqual(2);
    // Recovery quiesced — nothing left suspended, the outbox drained.
    await waitUntil(() => (persistence.outboxSize() === 0 ? true : undefined));
    expect(persistence.instanceCount()).toBe(0);
  });

  test("a deterministic env-store failure panics and fails the run (unchanged classification)", async () => {
    // A non-TransientError throw out of the reader is a deterministic bug: it must panic and fail the run, the
    // same as any other deterministic prim failure — never enter the retry loop.
    let reads = 0;
    const env: EnvReader = {
      async readSecret() {
        return null;
      },
      async readPublic() {
        reads += 1;
        throw new Error("permanent env store bug");
      },
    };
    const persistence = new StoringPersistence();
    const run = seedDurableRun(persistence);
    const actor = makeActor(persistence, env);
    await actor.activate();

    const failed = await waitUntil(() => {
      const record = persistence.peekRun(run);
      return record?.state === "error" ? record : undefined;
    });
    expect(failed.errorMessage).toMatch(/permanent env store bug/);
    // A deterministic failure is not retried — the panic fails the run on the first (and only) read.
    expect(reads).toBe(1);
    // The failed run's root tore down; nothing is left suspended.
    await waitUntil(() => (persistence.instanceCount() === 0 ? true : undefined));
  });
});
