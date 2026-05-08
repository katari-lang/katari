// Regression for BUG-01 in /review/02-phase2-modules.md.
//
// Before the fix, recoverOnBoot called `agents.cancelAgent(row.id)` to
// resume a `cancelling` agent — but `cancelAgent` gates on
// expectedState=running and silently no-op'd on `cancelling` rows. The
// engine never received the second terminate, and the agent stayed
// cancelling forever.
//
// We reproduce the scenario:
//   1. Start an agent that pauses on an FFI delegate (so engine has live
//      state to cancel).
//   2. Cancel it → row state goes to `cancelling`, engine sends terminate
//      to FFI but no terminateAck arrives yet.
//   3. Persist snapshot. Simulate restart with a fresh registry.
//   4. recoverOnBoot is expected to call resumeCancellingOnBoot (not
//      cancelAgent) so the engine re-issues terminate.
//   5. Feed in the FFI terminateAck — the agent should now transition to
//      `cancelled`.

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

    // Drive engine to the "paused on external" state.
    const machine = createMachine(moduleRow.irModule);
    const apiDelegationId = createDelegationId();
    const startOut = applyEvent(machine, {
      from: "API",
      to: "CORE",
      kind: "delegate",
      qualifiedName: "main",
      args: {},
      delegationId: apiDelegationId,
    });
    const ffiEvent = startOut.find(
      (e) => e.kind === "delegate" && e.from === "CORE" && e.to === "FFI",
    );
    if (ffiEvent === undefined || ffiEvent.kind !== "delegate") {
      throw new Error("expected outbound FFI delegate");
    }
    const ffiDelegationId = ffiEvent.delegationId;

    // Persist the agent row.
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

    // Send terminate (host side — flip row state, drive engine).
    applyEvent(machine, {
      from: "API",
      to: "CORE",
      kind: "terminate",
      delegationId: apiDelegationId,
    });
    await storage.agents.setState(agentId, { state: "cancelling" });
    await storage.snapshots.upsert(versionId, serializeMachine(machine));

    // === Simulate process restart ===
    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const agents = new AgentService(storage, registry, logger);
    await recoverOnBoot(storage, registry, logger, agents);

    // The handle should be loaded.
    expect(registry.isLoaded(versionId)).toBe(true);

    // Now deliver the FFI terminateAck. With BUG-01 fixed,
    // resumeCancellingOnBoot has already driven a fresh terminate
    // through the engine, so the engine knows to reply terminateAck to
    // the API once FFI acks. (For the legacy engine, the original
    // terminate was already sent before the restart; the second one
    // from resume is idempotent.)
    const handle = await registry.acquire(versionId);
    const finishOut = handle.feedEvent({
      from: "FFI",
      to: "CORE",
      kind: "terminateAck",
      delegationId: ffiDelegationId,
    });
    for (const event of finishOut) {
      if (
        event.kind === "terminateAck" &&
        event.from === "CORE" &&
        event.to === "API"
      ) {
        const row = await storage.agents.findByDelegationId(event.delegationId);
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

    const logger = noopLogger;
    const registry = new MachineRegistry(storage, logger);
    const agents = new AgentService(storage, registry, logger);

    // Should not throw, should not change state — running stays running.
    await agents.resumeCancellingOnBoot(agentId);
    const row = await agents.getAgent(agentId);
    expect(row.state).toBe("running");
  });
});
