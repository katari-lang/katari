// FFI executor end-to-end:
//   1. Upload a module that calls an external block.
//   2. Wire an InProcessFFIExecutor with a handler returning a value.
//   3. Start the agent. The engine emits CORE→FFI delegate, AgentService
//      dispatches to the executor, the result feeds back as delegateAck.
//   4. The agent transitions to "succeeded" with the FFI value.

import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  InProcessFFIExecutor,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { pausesOnExternalIR, trivialSchemaBundle } from "./helpers.js";

describe("FFI executor: end-to-end via InProcess", () => {
  it("dispatches the FFI call and feeds the value back as delegateAck", async () => {
    const storage = new InMemoryStorage();
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const modules = new ModuleService(storage, logger);

    const ffi = InProcessFFIExecutor.of({
      "test.ext_call": async () => ({ kind: "string", value: "from-ffi" }),
    });

    const agents = new AgentService(storage, registry, logger, undefined, ffi);
    const app = buildApp({ modules, agents, apiKey: null, rateLimit: null });

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
        body: JSON.stringify({ versionId, qualifiedName: "main", args: {} }),
      }),
    );
    expect(start.status).toBe(201);
    const { agentId } = (await start.json()) as { agentId: string };

    await agents.drainFFI();

    const got = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const row = (await got.json()) as { state: string; result?: { value: string } };
    expect(row.state).toBe("succeeded");
    expect(row.result).toEqual({ kind: "string", value: "from-ffi" });
  });

  it("FFI failure: agent transitions to cancelled via terminateAck path", async () => {
    const storage = new InMemoryStorage();
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const modules = new ModuleService(storage, logger);

    const ffi = InProcessFFIExecutor.of({
      "test.ext_call": async () => {
        throw new Error("boom");
      },
    });
    const agents = new AgentService(storage, registry, logger, undefined, ffi);
    const app = buildApp({ modules, agents, apiKey: null, rateLimit: null });

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
        body: JSON.stringify({ versionId, qualifiedName: "main", args: {} }),
      }),
    );
    const { agentId } = (await start.json()) as { agentId: string };

    await agents.drainFFI();

    const got = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const row = (await got.json()) as { state: string };
    // The failure feeds terminateAck → engine cascades cancel → agent
    // ends in cancelled (or error if the engine couldn't reconcile).
    expect(["cancelled", "error"]).toContain(row.state);
  });
});
