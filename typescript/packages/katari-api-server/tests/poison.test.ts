// Verifies the poison path: a non-Recoverable engine error marks every
// running agent on the version as `error`, deletes the snapshot row, and
// evicts the in-memory machine.
//
// We trigger poison by uploading an IR with a `statementCall` pointing
// at a non-existent blockId. The runtime's `spawnChild` raises a plain
// `Error` (not `RecoverableEngineError`) for missing blocks — that
// classification reflects "the IR is structurally broken; we can't trust
// the surrounding state either" — so the api-server poisons the whole
// version.

import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { trivialSchemaBundle } from "./helpers.js";
import type { Block, IRModule, VarId } from "katari-runtime/dist/ir/types.js";

/** IR whose entry block calls a non-existent block id (=> spawnChild throws). */
function brokenCallIR(): IRModule {
  const blocks: Record<number, Block> = {
    0: {
      kind: "blockUser",
      body: {
        kind: "blockKindAgent",
        parameters: [],
        statements: [
          // Call blockId 999 — no such block.
          {
            kind: "statementCall",
            body: {
              target: { kind: "callTargetBlock", block: 999 },
              arguments: [],
              output: 0 as VarId,
            },
          },
          {
            kind: "statementExit",
            body: { exitKind: "exitKindReturn", value: 0 as VarId },
          },
        ],
      },
    },
  };
  return {
    metadata: { schemaVersion: 1 },
    name: "broken",
    blocks: Object.fromEntries(
      Object.entries(blocks).map(([k, v]) => [k, v]),
    ),
    entries: { main: 0 },
    nameTable: { varNames: {}, blockNames: {} },
  };
}

describe("poison flow", () => {
  it("non-recoverable engine error: triggering agent + machine poison the version", async () => {
    const storage = new InMemoryStorage();
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const modules = new ModuleService(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    const app = buildApp({ modules, agents, apiKey: null, rateLimit: null });

    const upload = await app.fetch(
      new Request("http://test/module", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          irModule: brokenCallIR(),
          schemaBundle: trivialSchemaBundle(),
        }),
      }),
    );
    const { versionId } = (await upload.json()) as { versionId: string };

    const start = await app.fetch(
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ versionId, qualifiedName: "main", args: {} }),
      }),
    );
    expect(start.status).toBe(201);
    const { agentId } = (await start.json()) as { agentId: string };

    const got = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const row = (await got.json()) as { state: string; errorMessage?: string };
    expect(row.state).toBe("error");
    expect(row.errorMessage).toMatch(/block 999 not found/);

    // Snapshot row was deleted, machine evicted.
    expect(await storage.snapshots.get(versionId as never)).toBeNull();
    expect(registry.isLoaded(versionId as never)).toBe(false);
  });
});
