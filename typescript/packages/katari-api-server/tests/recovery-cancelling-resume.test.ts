// Regression for BUG-01: recovery resumes `cancelling` agents.

import { describe, expect, it } from "vitest";
import {
  CORE_ENDPOINT,
  EngineHandle,
  createDelegationId,
  endpoint,
} from "katari-runtime";
import {
  AgentService,
  InMemoryStorage,
  MachineRegistry,
  recoverOnBoot,
} from "../src/index.js";
import type { AgentId, AgentRow } from "../src/index.js";
import { pausesOnExternalIR, trivialSchemaBundle } from "./helpers.js";

describe("recovery: cancelling agents are resumed", () => {
  it("re-issues terminate for a cancelling agent and lets it complete via terminateAck", async () => {
    const storage = new InMemoryStorage();
    const versionId = await storage.modules.insert({
      irModule: pausesOnExternalIR(),
      schemaBundle: trivialSchemaBundle(),
      name: "test",
    });
    const moduleRow = await storage.modules.get(versionId);
    if (moduleRow === null) throw new Error("module missing");

    const machine = EngineHandle.create(moduleRow.irModule);
    const apiDelegationId = createDelegationId();
    const startResult = machine.startAgent("main", {}, apiDelegationId);
    const ffiEvent = startResult.outbound.find(
      (e) => e.payload.kind === "delegate" && e.to.startsWith("ext:"),
    );
    if (ffiEvent === undefined || ffiEvent.payload.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffiEvent.payload.delegationId;

    const agentId = "00000000-0000-7000-8000-000000000aaa" as AgentId;
    const now = new Date().toISOString();
    const agentRow: AgentRow = {
      id: agentId,
      delegationId: apiDelegationId,
      versionId,
      qualifiedName: "main",
      args: {},
      state: "running",
      createdAt: now,
      updatedAt: now,
    };
    await storage.agents.insert(agentRow);

    machine.cancelAgent(apiDelegationId);
    await storage.agents.setState(agentId, { state: "cancelling" });
    await storage.snapshots.upsert(versionId, machine.toSnapshot());

    // === Simulate process restart ===
    const logger = (await import("katari-runtime")).noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    await recoverOnBoot(storage, registry, logger, agents);

    expect(registry.isLoaded(versionId)).toBe(true);

    // Now deliver the FFI terminateAck on the recovered handle.
    const handle = await registry.acquire(versionId);
    const ffiSelf = endpoint("ext://ffi");
    const finishOut = handle.feedEvent({
      from: ffiSelf,
      to: CORE_ENDPOINT,
      payload: { kind: "terminateAck", delegationId: ffiDelegationId },
    });
    for (const event of finishOut.outbound) {
      if (
        event.payload.kind === "terminateAck" &&
        event.from.startsWith("core:")
      ) {
        const row = await storage.agents.findByDelegationId(event.payload.delegationId);
        if (row !== null) {
          await storage.agents.setState(row.id, { state: "cancelled" });
        }
      }
    }

    const refreshed = await agents.getAgent(agentId);
    expect(refreshed.state).toBe("cancelled");
  });

  it("resumeCancellingOnBoot is a no-op for non-cancelling agents", async () => {
    const storage = new InMemoryStorage();
    const versionId = await storage.modules.insert({
      irModule: pausesOnExternalIR(),
      schemaBundle: trivialSchemaBundle(),
      name: "test",
    });
    const moduleRow = await storage.modules.get(versionId);
    if (moduleRow === null) throw new Error("module missing");

    const agentId = "00000000-0000-7000-8000-000000000bbb" as AgentId;
    const now = new Date().toISOString();
    await storage.agents.insert({
      id: agentId,
      delegationId: createDelegationId(),
      versionId,
      qualifiedName: "main",
      args: {},
      state: "running",
      createdAt: now,
      updatedAt: now,
    });

    const logger = (await import("katari-runtime")).noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const agents = new AgentService(storage, registry, logger);

    await agents.resumeCancellingOnBoot(agentId);
    const row = await agents.getAgent(agentId);
    expect(row.state).toBe("running");
  });
});
