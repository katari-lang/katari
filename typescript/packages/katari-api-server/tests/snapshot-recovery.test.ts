import { describe, expect, it } from "vitest";
import {
  applyEvent,
  createDelegationId,
  createMachine,
  noopLogger,
  serializeMachine,
} from "katari-runtime";
import {
  AgentService,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
  recoverOnBoot,
} from "../src/index.js";
import type { AgentId, AgentRow } from "../src/index.js";
import { pausesOnExternalIR, trivialSchemaBundle } from "./helpers.js";

describe("snapshot recovery", () => {
  it("recovers a paused agent from snapshot, then completes via FFI ack", async () => {
    // First "process": upload a module, start an agent that pauses on
    // external, persist snapshot, then drop everything and simulate restart.
    const storage = new InMemoryStorage();
    const versionId = await storage.modules.insert({
      irModule: pausesOnExternalIR(),
      schemaBundle: trivialSchemaBundle(),
      name: "test",
    });
    const moduleRow = await storage.modules.get(versionId);
    if (moduleRow === null) throw new Error("module disappeared");

    // Drive the engine directly so we can observe the FFI delegation id
    // before the snapshot is taken. Mirrors what AgentService.startAgent
    // would do internally.
    const machine = createMachine(moduleRow.irModule);
    const apiDelegationId = createDelegationId();
    const agentId = "00000000-0000-7000-8000-000000000abc" as AgentId;
    const out = applyEvent(machine, {
      from: "API",
      to: "CORE",
      kind: "delegate",
      qualifiedName: "main",
      args: {},
      delegationId: apiDelegationId,
    });
    const ffiEvent = out.find(
      (e) => e.kind === "delegate" && e.from === "CORE" && e.to === "FFI",
    );
    if (ffiEvent === undefined || ffiEvent.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffiEvent.delegationId;

    // Persist the agent row (separate AgentId vs DelegationId) and snapshot.
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
    await storage.snapshots.upsert(versionId, serializeMachine(machine));

    // Second "process": fresh registry / services against the same storage.
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    new ModuleService(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    await recoverOnBoot(storage, registry, logger);

    expect(registry.isLoaded(versionId)).toBe(true);

    // Deliver the FFI ack on the recovered handle and mirror the parts of
    // AgentService.routeOutbound that flip agent state. (The full route
    // path is exercised by the e2e test; here we only need to prove the
    // recovered machine actually completes.)
    const handle = await registry.acquire(versionId);
    const finishOut = handle.feedEvent({
      from: "FFI",
      to: "CORE",
      kind: "delegateAck",
      delegationId: ffiDelegationId,
      value: { kind: "string", value: "recovered" },
    });
    for (const event of finishOut) {
      if (
        event.kind === "delegateAck" &&
        event.from === "CORE" &&
        event.to === "API"
      ) {
        const row = await storage.agents.findByDelegationId(event.delegationId);
        if (row !== null) {
          await storage.agents.setState(row.id, {
            state: "succeeded",
            result: event.value,
          });
        }
      }
    }

    const row = await agents.getAgent(agentId);
    expect(row.state).toBe("succeeded");
    expect(row.result).toEqual({ kind: "string", value: "recovered" });
  });

  it("missing snapshot at boot flips running agents to error", async () => {
    const storage = new InMemoryStorage();
    const versionId = await storage.modules.insert({
      irModule: pausesOnExternalIR(),
      schemaBundle: trivialSchemaBundle(),
      name: "test",
    });
    const now = new Date().toISOString();
    await storage.agents.insert({
      id: "00000000-0000-7000-8000-000000000001" as AgentId,
      delegationId: createDelegationId(),
      versionId,
      qualifiedName: "main",
      args: {},
      state: "running",
      createdAt: now,
      updatedAt: now,
    });

    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    await recoverOnBoot(storage, registry, logger);

    const rows = await storage.agents.list();
    expect(rows.every((r) => r.state === "error")).toBe(true);
  });
});
