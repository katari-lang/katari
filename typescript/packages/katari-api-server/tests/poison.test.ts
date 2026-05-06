import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { pausesOnExternalIR, trivialSchemaBundle } from "./helpers.js";

describe("poison flow", () => {
  it("FFI not implemented: agent + machine poison the version", async () => {
    const storage = new InMemoryStorage();
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const modules = new ModuleService(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    const app = buildApp({ modules, agents });

    const upload = await app.fetch(
      new Request("http://test/module", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          irModule: pausesOnExternalIR(),
          schemaBundle: trivialSchemaBundle(),
        }),
      }),
    );
    const { versionId } = (await upload.json()) as { versionId: string };

    const start = await app.fetch(
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          versionId,
          qualifiedName: "main",
          args: {},
        }),
      }),
    );
    expect(start.status).toBe(201);
    const { agentId } = (await start.json()) as { agentId: string };

    const got = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const row = (await got.json()) as { state: string; errorMessage?: string };
    expect(row.state).toBe("error");
    expect(row.errorMessage).toMatch(/FFI/);

    // Snapshot row was deleted, machine evicted.
    expect(await storage.snapshots.get(versionId as never)).toBeNull();
    expect(registry.isLoaded(versionId as never)).toBe(false);
  });
});
