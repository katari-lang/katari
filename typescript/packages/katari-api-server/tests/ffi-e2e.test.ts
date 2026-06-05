// FFI round-trip through the warm per-project actor + FfiMux.
//
// Exercises the whole CORE→FFI→sidecar→FFI→CORE→API path that the other
// api-server tests (sync agents) never touch:
//
//   startRun → CORE shard runs `main` → calls ext → CORE stamps the snapshot
//   on the FFI delegate → FfiMux decodes it, lazily spins a lane → the lane
//   STRIPS the snapshot so the MockSidecar handler (keyed by the bare qname)
//   matches → handler returns → ipcDelegateAck → FFI → CORE → delegateAck →
//   ApiModule.completeRun marks the run succeeded.
//
// A regression in the snapshot strip (or the mux routing) would fail the
// handler lookup and the run would never complete.

import type { IRModule } from "@katari-lang/runtime";
import type { Block, VarId } from "katari-runtime/dist/ir/types.js";
import { afterEach, describe, expect, it } from "vitest";
import {
  buildTestHarness,
  noOpSidecarBundle,
  trivialSchemaBundle,
  type TestHarness,
} from "./helpers.js";

/** `main` calls ext `test.ext_call` (a blockDelegate → delegateTargetExternal)
 *  and returns its result. Built with the current IR shapes (the stale
 *  `pausesOnExternalIR` helper used the removed `blockExternal` variant). */
function callsExtIR(): IRModule {
  const v0 = 0 as VarId;
  const blocks: Record<number, Block> = {
    1: {
      kind: "blockAgent",
      body: {
        qualifiedName: "test.main",
        defaults: {},
        entryBody: 2,
        name: "main",
        description: undefined,
        inputSchema: "{}",
        outputSchema: '{"type":"string"}',
        requestsSchema: "[]",
      },
    },
    2: {
      kind: "blockUser",
      body: {
        defaults: {},
        statements: [{ kind: "statementCall", body: { block: 3, output: v0 } }],
        trailing: v0,
      },
    },
    3: {
      kind: "blockDelegate",
      body: {
        target: {
          kind: "delegateTargetExternal",
          body: { endpoint: "FFI", dispatchName: "test.ext_call" },
        },
      },
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    blocks: blocks as IRModule["blocks"],
    entries: { main: 1 },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

let active: (TestHarness & { shutdown: () => Promise<void> }) | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

describe("FFI e2e through the actor", () => {
  it("an agent that calls an ext resolves via the sidecar and succeeds", async () => {
    const harness = buildTestHarness({
      // The ext handler is keyed by the BARE qname — CORE stamps the snapshot
      // on the wire and the FFI lane strips it before the sidecar sees it.
      // Handlers return RawValue (raw JSON): a string is just the bare string.
      ffiHandlers: {
        "test.ext_call": async () => "from-ext",
      },
    });
    active = harness;

    // Upload a snapshot whose `main` calls the ext. A non-null sidecar bundle
    // makes the harness spin a MockSidecar for the snapshot.
    const projectResp = await harness.app.fetch(
      new Request("http://test/project", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "ffi-proj" }),
      }),
    );
    const { project } = (await projectResp.json()) as { project: { id: string } };
    const snapResp = await harness.app.fetch(
      new Request(`http://test/project/${project.id}/snapshot`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          irModule: callsExtIR(),
          sidecarBundle: noOpSidecarBundle(),
          schemaBundle: trivialSchemaBundle(),
        }),
      }),
    );
    const { snapshotId } = (await snapResp.json()) as { snapshotId: string };

    const start = await harness.app.fetch(
      new Request(`http://test/project/${project.id}/run`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ snapshotId, qualifiedName: "main", args: {} }),
      }),
    );
    expect(start.status).toBe(201);
    const { runId } = (await start.json()) as { runId: string };

    // The sidecar response arrives asynchronously (MockSidecar resolves the
    // handler on a microtask, re-entering the actor via the message handler).
    // Poll the run state until it settles.
    let state = "running";
    let result: string | undefined;
    for (let i = 0; i < 50 && state === "running"; i++) {
      await new Promise((r) => setTimeout(r, 10));
      const got = await harness.app.fetch(
        new Request(`http://test/project/${project.id}/run/${runId}`),
      );
      const body = (await got.json()) as { run: { state: string; result?: string } };
      state = body.run.state;
      result = body.run.result;
    }

    expect(state).toBe("done");
    expect(result).toBe("from-ext");
  });
});
