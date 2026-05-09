// End-to-end cancel flow against the new engine.
//   1. Start an agent that suspends on FFI.
//   2. POST /agent/:id/cancel → state="cancelling", outbound CORE→FFI terminate.
//   3. Locate the FFI delegationId from the registry snapshot.
//   4. Feed the FFI terminateAck → engine emits terminateAck CORE→API.
//   5. Mirror routeOutbound's setState path so the row reaches "cancelled".

import { describe, expect, it } from "vitest";
import { CORE_ENDPOINT, endpoint, noopLogger, type DelegationId } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { pausesOnExternalIR, trivialSchemaBundle } from "./helpers.js";

describe("cancel agent e2e (suspended on FFI → cancel → terminateAck → cancelled)", () => {
  it("flips state running → cancelling → cancelled", async () => {
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

    const cancelResp = await app.fetch(
      new Request(`http://test/agent/${agentId}/cancel`, { method: "POST" }),
    );
    expect(cancelResp.status).toBe(200);
    const cancelRow = (await cancelResp.json()) as { state: string };
    expect(cancelRow.state).toBe("cancelling");

    // Locate the FFI delegationId from the engine snapshot.
    const handle = await registry.acquire(versionId as never);
    const snap = handle.toSnapshot();
    const ffiIds = Object.keys(snap.ffiDelegations);
    expect(ffiIds.length).toBe(1);
    const ffiDelegationId = ffiIds[0]!;

    // Feed the FFI terminateAck.
    const ffiSelf = endpoint("ext://ffi");
    const out = handle.feedEvent({
      from: ffiSelf,
      to: CORE_ENDPOINT,
      payload: {
        kind: "terminateAck",
        delegationId: ffiDelegationId as DelegationId,
      },
    });
    for (const event of out.outbound) {
      if (
        event.payload.kind === "terminateAck" &&
        event.from.startsWith("core:")
      ) {
        const row = await storage.agents.findByDelegationId(event.payload.delegationId);
        if (row !== null) {
          await storage.agents.setState(
            row.id,
            { state: "cancelled" },
            { expectedState: "cancelling" },
          );
        }
      }
    }

    const after = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const afterRow = (await after.json()) as { state: string };
    expect(afterRow.state).toBe("cancelled");
  });
});
