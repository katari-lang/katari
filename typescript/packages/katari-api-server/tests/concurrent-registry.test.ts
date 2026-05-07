// Concurrency tests for MachineRegistry / AgentService.
//
// Focus: the per-version mutex should serialize handle-mutating work, so
// even when N requests target the same version simultaneously, the
// resulting state is consistent (no lost agents, no duplicate inserts,
// the registry returns the same handle to all callers).

import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentService,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { literalReturnIR, trivialSchemaBundle } from "./helpers.js";

function setup() {
  const storage = new InMemoryStorage();
  const logger = noopLogger;
  const registry = new MachineRegistry(storage, logger);
  const modules = new ModuleService(storage, logger);
  const agents = new AgentService(storage, registry, logger);
  return { storage, registry, modules, agents };
}

describe("MachineRegistry concurrency", () => {
  it("acquire() racing on the same versionId returns the same handle instance", async () => {
    const { storage, registry, modules } = setup();
    const { versionId } = await modules.upload({
      irModule: literalReturnIR("hi"),
      schemaBundle: trivialSchemaBundle(),
    });
    void storage;

    const handles = await Promise.all([
      registry.acquire(versionId),
      registry.acquire(versionId),
      registry.acquire(versionId),
      registry.acquire(versionId),
    ]);

    // All four refs are the same JS object — the inFlight Map collapsed
    // the duplicate loads.
    for (let i = 1; i < handles.length; i++) {
      expect(handles[i]).toBe(handles[0]);
    }
  });

  it("multiple concurrent startAgent calls all complete (mutex serializes engine work)", async () => {
    const { modules, agents } = setup();
    const { versionId } = await modules.upload({
      irModule: literalReturnIR("hi"),
      schemaBundle: trivialSchemaBundle(),
    });

    // Fire 8 concurrent starts. Without the mutex this used to clobber
    // snapshots and lose agents; with it, each call commits in its own
    // transaction and all 8 agents end up succeeded.
    const results = await Promise.all(
      Array.from({ length: 8 }).map(() =>
        agents.startAgent({ versionId, qualifiedName: "main", args: {} }),
      ),
    );

    expect(results).toHaveLength(8);
    const ids = new Set(results.map((r) => r.agentId));
    expect(ids.size).toBe(8); // no duplicate ids

    const list = await agents.listAgents({ versionId });
    expect(list.length).toBeGreaterThanOrEqual(8);
    for (const row of list) {
      // Each one ran a literal-return IR, so all should have committed
      // to "succeeded".
      expect(row.state).toBe("succeeded");
      expect(row.result).toEqual({ kind: "string", value: "hi" });
    }
  });
});
