// FfiModule snapshot stamp / strip at the sidecar boundary.
//
// The snapshot rides inside the agent def id (CORE/FFI-private, opaque to the
// bus). The FFI module is the boundary where that id meets a sidecar whose
// handler registry is keyed by the BARE qname (the sidecar already IS the
// right snapshot's code). So:
//
//   - inbound  CORE→FFI delegate (`ext.tool@snap`) → strip → `ipcDelegate ext.tool`
//   - outbound ext-spawned CORE child (`some.agent`) → stamp → `delegate some.agent@snap`
//
// (escalate / throw stay bare — they are requests, not delegate targets.)

import { describe, expect, it } from "vitest";
import {
  encodeCoreAgentDefId,
  encodeFfiAgentDefId,
} from "../src/agent-def-id.js";
import type { AgentDefId } from "../src/agent-def-id.js";
import { CORE_ENDPOINT, FFI_ENDPOINT } from "../src/modules/endpoints.js";
import { FfiModule } from "../src/modules/ffi.js";
import type { ExternalEvent } from "../src/engine/event.js";
import { createDelegationId } from "../src/engine/id.js";
import { noopLogger } from "../src/engine/logger.js";
import type { Sidecar } from "../src/sidecar/sidecar.js";
import type { FfiStore, FfiPendingDelegation, FfiPendingEscalation } from "../src/sidecar/store.js";
import type { ChildToParent, ParentToChild } from "../src/sidecar/types.js";
import type { QualifiedName } from "../src/ir/types.js";

const SNAP = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

/** In-memory FfiStore — enough for the boundary assertions. */
class MemFfiStore implements FfiStore {
  readonly delegations = new Map<string, FfiPendingDelegation>();
  readonly escalations = new Map<string, FfiPendingEscalation>();
  async insertDelegation(row: FfiPendingDelegation): Promise<void> {
    this.delegations.set(row.delegationId, row);
  }
  async getDelegation(id: string): Promise<FfiPendingDelegation | null> {
    return this.delegations.get(id) ?? null;
  }
  async setDelegationState(id: string, state: "running" | "cancelling"): Promise<boolean> {
    const row = this.delegations.get(id);
    if (row === undefined) return false;
    row.state = state;
    return true;
  }
  async deleteDelegation(id: string): Promise<boolean> {
    return this.delegations.delete(id);
  }
  async listDelegations(): Promise<FfiPendingDelegation[]> {
    return [...this.delegations.values()];
  }
  async listChildrenOf(parentId: string): Promise<FfiPendingDelegation[]> {
    return [...this.delegations.values()].filter((r) => r.parentExtDelegationId === parentId);
  }
  async insertEscalation(row: FfiPendingEscalation): Promise<void> {
    this.escalations.set(row.escalationId, row);
  }
  async getEscalation(id: string): Promise<FfiPendingEscalation | null> {
    return this.escalations.get(id) ?? null;
  }
  async deleteEscalation(id: string): Promise<boolean> {
    return this.escalations.delete(id);
  }
  async listEscalations(): Promise<FfiPendingEscalation[]> {
    return [...this.escalations.values()];
  }
}

/** Sidecar that records every `send` so we can inspect the agent def id. */
class CapturingSidecar implements Sidecar {
  readonly sent: ParentToChild[] = [];
  async send(msg: ParentToChild): Promise<void> {
    this.sent.push(msg);
  }
  onMessage(): void {}
  async start(): Promise<void> {}
  async shutdown(): Promise<void> {}
}

function makeModule(): {
  ffi: FfiModule;
  sidecar: CapturingSidecar;
  store: MemFfiStore;
  bus: ExternalEvent[];
} {
  const sidecar = new CapturingSidecar();
  const store = new MemFfiStore();
  const bus: ExternalEvent[] = [];
  const ffi = new FfiModule({
    endpoint: FFI_ENDPOINT,
    snapshotId: SNAP,
    sidecar,
    store,
    logger: noopLogger,
    onSidecarResponse: (event) => bus.push(event),
  });
  return { ffi, sidecar, store, bus };
}

describe("FfiModule snapshot boundary", () => {
  it("strips the snapshot from an inbound delegate before the sidecar sees it", async () => {
    const { ffi, sidecar, store } = makeModule();
    const delegationId = createDelegationId();
    const stamped = encodeFfiAgentDefId({
      kind: "qname",
      value: "ext.tool" as QualifiedName,
      snapshot: SNAP,
    });

    await ffi.feed({
      from: CORE_ENDPOINT,
      to: FFI_ENDPOINT,
      payload: { kind: "delegate", delegationId, agentDefId: stamped, args: {} },
    });

    const sent = sidecar.sent.find((m) => m.type === "ipcDelegate");
    expect(sent).toBeDefined();
    // The sidecar receives the BARE qname (its handler key).
    expect((sent as { agentDefId: AgentDefId }).agentDefId).toBe("ext.tool");
    // The store row also holds the bare form, so `ipcDelegateRestarted` on
    // recovery keeps presenting the bare qname.
    expect(store.delegations.get(delegationId)?.agentDefId).toBe("ext.tool");
  });

  it("stamps this sidecar's snapshot onto a CORE child the ext spawns", async () => {
    const { ffi, bus, store } = makeModule();
    const parentDelegationId = createDelegationId();
    const childDelegationId = createDelegationId();

    const msg: ChildToParent = {
      type: "ipcChildDelegate",
      parentDelegationId,
      delegationId: childDelegationId,
      // The ext names the CORE child by bare qname — no notion of snapshots.
      agentDefId: "some.agent" as AgentDefId,
      args: {},
    };
    await ffi.dispatchSidecarMessage(msg);

    const delegate = bus.find((e) => e.payload.kind === "delegate");
    expect(delegate).toBeDefined();
    expect(delegate?.to).toBe(CORE_ENDPOINT);
    // CORE needs the stamp to create the child shard on the matching IR.
    const expected = encodeCoreAgentDefId({
      kind: "qname",
      value: "some.agent" as QualifiedName,
      snapshot: SNAP,
    });
    if (delegate?.payload.kind === "delegate") {
      expect(delegate.payload.agentDefId).toBe(expected);
    }
    expect(store.delegations.get(childDelegationId)?.agentDefId).toBe(expected);
  });

  it("leaves the throw escalate bare (a request, not a delegate target)", async () => {
    const { ffi, bus, store } = makeModule();
    const delegationId = createDelegationId();
    // Seed a pending parent ext delegation so the error has a peer to ack to.
    await store.insertDelegation({
      delegationId,
      peerEndpoint: CORE_ENDPOINT,
      agentDefId: "ext.tool" as AgentDefId,
      args: {},
      state: "running",
      createdAt: new Date().toISOString(),
      parentExtDelegationId: null,
    });

    await ffi.dispatchSidecarMessage({
      type: "ipcDelegateError",
      delegationId,
      message: "boom",
    });

    const escalate = bus.find((e) => e.payload.kind === "escalate");
    expect(escalate).toBeDefined();
    if (escalate?.payload.kind === "escalate") {
      // primitive.throw is a protocol-common request id — never stamped.
      expect(escalate.payload.agentDefId).toBe("primitive.throw");
    }
  });
});
