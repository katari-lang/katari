// End-to-end cancel flow:
//   1. Start an agent that suspends on FFI (so it doesn't auto-complete).
//   2. POST /agent/:id/cancel → state moves to "cancelling", outbound
//      CORE→FFI terminate is emitted.
//   3. Simulate the FFI sidecar acknowledging the terminate.
//   4. The agent state lands on "cancelled".
//
// The api-server's `routeOutbound` only knows about delegateAck/terminateAck
// originating from CORE→API; the inbound FFI ack arrives via
// MachineHandle.feedEvent (no public REST endpoint exists for it yet, since
// the FFI executor isn't built — Stage 5+). To exercise the full path we
// reach into the registry to grab the handle and feed the ack manually.

import { describe, expect, it } from "vitest";
import { noopLogger, type DelegationId } from "katari-runtime";
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

    // 1. Upload module + start agent. The agent calls an external block,
    // so it suspends on the outbound CORE→FFI delegate and stays running.
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

    const beforeCancel = await app.fetch(new Request(`http://test/agent/${agentId}`));
    expect(((await beforeCancel.json()) as { state: string }).state).toBe("running");

    // 2. POST cancel → state="cancelling", and we capture the FFI delegationId
    // by grabbing the in-memory handle's outbound events on the next feedEvent.
    // The simpler observation path: state in DB.
    const cancelResp = await app.fetch(
      new Request(`http://test/agent/${agentId}/cancel`, { method: "POST" }),
    );
    expect(cancelResp.status).toBe(200);
    const cancelRow = (await cancelResp.json()) as { state: string; delegationId: string };
    expect(cancelRow.state).toBe("cancelling");

    // 3. Locate the FFI delegationId. The handle's snapshot exposes
    // `delegations` keyed by FFI id. We grab the one ExternalThread that
    // exists (the agent we just started has exactly one outstanding FFI).
    const handle = await registry.acquire(versionId as never);
    const snap = handle.toSnapshot();
    expect(snap.delegations).toHaveLength(1);
    const ffiDelegationId = snap.delegations[0]!.delegationId;

    // 4. Feed the FFI terminateAck into the engine. routeOutbound runs
    // inside the runtime adapter, so we reach the same path the api-server
    // uses internally: feedEvent → applyEvent → outbound terminateAck CORE→API.
    // We then have to mirror the parts of routeOutbound the api-server
    // does, since feedEvent is below the AgentService layer.
    const out = handle.feedEvent({
      from: "FFI",
      to: "CORE",
      kind: "terminateAck",
      delegationId: ffiDelegationId,
    });
    for (const event of out) {
      if (
        event.kind === "terminateAck" &&
        event.from === "CORE" &&
        event.to === "API"
      ) {
        const row = await storage.agents.findByDelegationId(
          event.delegationId as DelegationId,
        );
        if (row !== null) {
          await storage.agents.setState(row.id, { state: "cancelled" }, { expectedState: "cancelling" });
        }
      }
    }

    // 5. Final state.
    const after = await app.fetch(new Request(`http://test/agent/${agentId}`));
    const afterRow = (await after.json()) as { state: string };
    expect(afterRow.state).toBe("cancelled");
  });
});
