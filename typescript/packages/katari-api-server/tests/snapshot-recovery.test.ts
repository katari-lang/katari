// Snapshot recovery: the engine pauses on an outbound FFI delegate, the
// host persists the snapshot + agent row, then a fresh process boots and
// resumes the agent by feeding the FFI ack via the recovered handle.

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
  ModuleService,
  recoverOnBoot,
} from "../src/index.js";
import type { AgentId, AgentRow } from "../src/index.js";
import { pausesOnExternalIR, trivialSchemaBundle } from "./helpers.js";

describe("snapshot recovery", () => {
  it("recovers a paused agent from snapshot, then completes via FFI ack", async () => {
    const storage = new InMemoryStorage();
    const versionId = await storage.modules.insert({
      irModule: pausesOnExternalIR(),
      schemaBundle: trivialSchemaBundle(),
      name: "test",
    });
    const moduleRow = await storage.modules.get(versionId);
    if (moduleRow === null) throw new Error("module disappeared");

    // Drive the engine directly to the "paused on FFI" state.
    const machine = EngineHandle.create(moduleRow.irModule);
    const apiDelegationId = createDelegationId();
    const agentId = "00000000-0000-7000-8000-000000000abc" as AgentId;
    const out = machine.startAgent("main", {}, apiDelegationId);
    const ffiEvent = out.outbound.find(
      (e) => e.payload.kind === "delegate" && e.to.startsWith("ext:"),
    );
    if (ffiEvent === undefined || ffiEvent.payload.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffiEvent.payload.delegationId;

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
    await storage.snapshots.upsert(versionId, machine.toSnapshot());

    // Second "process": fresh registry/services against the same storage.
    const logger = (await import("katari-runtime")).noopLogger;
    const registry = new MachineRegistry(storage, logger);
    new ModuleService(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    await recoverOnBoot(storage, registry, logger);

    expect(registry.isLoaded(versionId)).toBe(true);

    const handle = await registry.acquire(versionId);
    const ffiSelf = endpoint("ext://ffi");
    const finishOut = handle.feedEvent({
      from: ffiSelf,
      to: CORE_ENDPOINT,
      payload: {
        kind: "delegateAck",
        delegationId: ffiDelegationId,
        value: { kind: "string", value: "recovered" },
      },
    });
    for (const event of finishOut.outbound) {
      if (
        event.payload.kind === "delegateAck" &&
        event.from.startsWith("core:")
      ) {
        const row = await storage.agents.findByDelegationId(event.payload.delegationId);
        if (row !== null) {
          await storage.agents.setState(row.id, {
            state: "succeeded",
            result: event.payload.value,
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

    const logger = (await import("katari-runtime")).noopLogger;
    const registry = new MachineRegistry(storage, logger);
    await recoverOnBoot(storage, registry, logger);

    const rows = await storage.agents.list();
    expect(rows.every((r) => r.state === "error")).toBe(true);
  });
});
