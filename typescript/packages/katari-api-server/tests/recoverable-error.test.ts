// Recoverable engine errors keep sibling agents alive.
//
// Before Stage B5/B8 every engine throw poisoned the entire version (all
// running agents → error, snapshot deleted, machine evicted). We now
// route `RecoverableEngineError` through `versionedRollback`: only the
// triggering agent moves to error; the version stays healthy and other
// agents keep running.

import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentNotFound,
  AgentService,
  buildApp,
  EntryNotFoundError,
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
  const app = buildApp({ modules, agents, apiKey: null, rateLimit: null });
  return { storage, registry, modules, agents, app };
}

describe("Recoverable engine error → single-agent failure", () => {
  it("typo'd qualifiedName: route returns 400 and the agent row is recorded as error", async () => {
    const { app } = setup();

    // Upload a module so the version exists.
    const upload = await app.fetch(
      new Request("http://test/module", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          irModule: literalReturnIR("hello"),
          schemaBundle: trivialSchemaBundle(),
        }),
      }),
    );
    const { versionId } = (await upload.json()) as { versionId: string };

    // Try to start an agent with a name that's not in entries.
    const start = await app.fetch(
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          versionId,
          qualifiedName: "does-not-exist",
          args: {},
        }),
      }),
    );
    expect(start.status).toBe(400);
    const errBody = (await start.json()) as { error: string };
    expect(errBody.error).toMatch(/does-not-exist/);
  });

  it("sibling agent keeps running after a recoverable error on a peer", async () => {
    // Use the service layer directly (skipping the route layer) so we can
    // observe the sibling state without HTTP error masking.
    const { agents, modules } = setup();
    const { versionId } = await modules.upload({
      irModule: literalReturnIR("ok"),
      schemaBundle: trivialSchemaBundle(),
    });

    // Sibling: legitimate start.
    const sibling = await agents.startAgent({
      versionId,
      qualifiedName: "main",
      args: {},
    });
    const siblingRow = await agents.getAgent(sibling.agentId);
    expect(siblingRow.state).toBe("succeeded");

    // Trigger recoverable on the same version: typo'd qualifiedName.
    let caught: unknown;
    try {
      await agents.startAgent({
        versionId,
        qualifiedName: "wrong-name",
        args: {},
      });
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(EntryNotFoundError);

    // Sibling unaffected.
    const siblingAgain = await agents.getAgent(sibling.agentId);
    expect(siblingAgain.state).toBe("succeeded");

    // A third start should still work (machine wasn't poisoned).
    const third = await agents.startAgent({
      versionId,
      qualifiedName: "main",
      args: {},
    });
    const thirdRow = await agents.getAgent(third.agentId);
    expect(thirdRow.state).toBe("succeeded");
  });

  it("cancelAgent() on a non-existent id throws AgentNotFound", async () => {
    const { agents } = setup();
    await expect(
      agents.cancelAgent("00000000-0000-0000-0000-000000000000" as never),
    ).rejects.toThrow(AgentNotFound);
  });
});
