// FfiModule — per-tick wrapper around the long-lived SidecarManager.
//
// 役割: 6 event のうち FFI 宛の inbound (= CORE 側から来る delegate /
// terminate / escalateAck) を sidecar に IPC 送信、pending 行を DB に persist。
// sidecar からの応答 (delegateAck / terminateAck / escalate) は SidecarManager
// が onMessage で受けて、orchestrator に転送 → 別 tick で bus に push される。
//
// per-tick: 1 request の中で生きる。sidecar process は跨いで生存。

import {
  decodeCoreAgentDefId,
  encodeCoreAgentDefId,
  type ExternalEvent,
  type Logger,
  type Module,
} from "katari-runtime";
import type { ParentToChild } from "katari-runtime/dist/sidecar/types.js";
import { CORE_ENDPOINT, FFI_ENDPOINT } from "./endpoints.js";
import type { SidecarManager } from "./sidecar-manager.js";
import type { Storage, SnapshotId } from "../storage/types.js";

export type FfiModuleOptions = {
  snapshotId: SnapshotId;
  tx: Storage;
  sidecarManager: SidecarManager;
  logger: Logger;
};

export class FfiModule implements Module {
  readonly endpoint = FFI_ENDPOINT;
  private readonly snapshotId: SnapshotId;
  private readonly tx: Storage;
  private readonly sidecarManager: SidecarManager;
  private readonly logger: Logger;

  constructor(opts: FfiModuleOptions) {
    this.snapshotId = opts.snapshotId;
    this.tx = opts.tx;
    this.sidecarManager = opts.sidecarManager;
    this.logger = opts.logger;
  }

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    switch (event.payload.kind) {
      case "delegate":
        await this.handleDelegate(event);
        return { outbound: [] };
      case "terminate":
        await this.handleTerminate(event);
        return { outbound: [] };
      case "escalateAck":
        await this.handleEscalateAck(event);
        return { outbound: [] };
      case "delegateAck":
      case "terminateAck":
      case "escalate":
        // FFI is the sender side of the original delegate; these are
        // responses from sidecar that arrive here only via the Sidecar
        // → orchestrator → bus loop. They should target whoever sent
        // the original delegate (= CORE), not us.
        this.logger.log("debug", "ffi: unexpected inbound from peer", {
          kind: event.payload.kind,
          from: event.from,
        });
        return { outbound: [] };
    }
  }

  async persist(_tx: unknown): Promise<void> {
    // tx 経由で書き通し済 → no-op。
  }

  async load(_tx: unknown): Promise<void> {
    // tx 経由で必要時に読み出すので no-op。
  }

  // ─── Inbound handlers ──────────────────────────────────────────────────

  private async handleDelegate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "delegate") return;
    const { delegationId, agentDefId, args } = event.payload;
    if (!this.sidecarManager.hasSidecar(this.snapshotId)) {
      this.logger.log("warn", "ffi: snapshot has no sidecar; cannot dispatch delegate", {
        snapshotId: this.snapshotId,
        delegationId,
      });
      return;
    }
    await this.tx.ffiDelegations.insert({
      delegationId,
      snapshotId: this.snapshotId,
      peerEndpoint: event.from,
      agentDefId,
      args,
      state: "running",
      createdAt: new Date().toISOString(),
    });
    await this.sidecarManager.send(this.snapshotId, {
      type: "delegate",
      delegationId,
      agentDefId,
      args,
    });
  }

  private async handleTerminate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "terminate") return;
    const { delegationId } = event.payload;
    const ok = await this.tx.ffiDelegations.setState(delegationId, "cancelling");
    if (!ok) {
      this.logger.log("debug", "ffi: terminate for unknown delegation", {
        delegationId,
      });
      return;
    }
    if (this.sidecarManager.hasSidecar(this.snapshotId)) {
      await this.sidecarManager.send(this.snapshotId, {
        type: "terminate",
        delegationId,
      });
    }
  }

  private async handleEscalateAck(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "escalateAck") return;
    const { escalationId, value } = event.payload;
    const pending = await this.tx.ffiEscalations.get(escalationId);
    if (pending === null) {
      this.logger.log("debug", "ffi: escalateAck for unknown escalation", {
        escalationId,
      });
      return;
    }
    await this.tx.ffiEscalations.delete(escalationId);
    if (this.sidecarManager.hasSidecar(this.snapshotId)) {
      await this.sidecarManager.send(this.snapshotId, {
        type: "escalateAck",
        escalationId,
        value,
      });
    }
  }
}

// Build the IPC `parentToChild` payload for a sidecar message — currently
// inlined; export the helper if more callers need it.
void (null as unknown as ParentToChild);
void decodeCoreAgentDefId;
void encodeCoreAgentDefId;
void CORE_ENDPOINT;
