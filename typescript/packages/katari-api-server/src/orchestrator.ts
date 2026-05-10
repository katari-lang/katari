// Orchestrator — request 処理の中心。
//
// 各 HTTP request、または各 sidecar 応答が「1 tick」を起こす。tick は:
//
//   1. snapshot の row lock を取る (withTransaction + withSnapshotLock)
//   2. CoreModule を engine_checkpoints から load
//   3. ApiModule / FfiModule は per-tick で tx を抱えて作成 (load 不要)
//   4. ExternalEventBus に 3 module を register
//   5. caller (HTTP route, または sidecar dispatcher) が初期 event を push
//   6. bus.drain() で全 event chain を解消
//   7. CoreModule.persist で checkpoint を書き戻す
//   8. commit
//
// FFI sidecar 応答は async に起きるので、orchestrator は SidecarManager の
// `setMessageHandler` 経由で「sidecar からの ChildToParent → ExternalEvent」
// 変換を引き受け、新しい tick を起こす。
//
// このパターンにより:
//   - api-server レイヤは in-memory state を持たない (= sidecar process 以外)
//   - 1 request 中の event chain は all-or-nothing で commit される
//   - long-running な FFI invoke は別 tick で resume するので request 自体は
//     早く返せる

import {
  decodeFfiAgentDefId,
  encodeFfiAgentDefId,
  ExternalEventBus,
  type ExternalEvent,
  type Logger,
  type Value,
} from "katari-runtime";
import { CoreModule } from "katari-runtime";
import type { ChildToParent } from "katari-runtime/dist/sidecar/types.js";
import { ApiModule } from "./modules/api-module.js";
import { CORE_ENDPOINT, FFI_ENDPOINT } from "./modules/endpoints.js";
import { FfiModule } from "./modules/ffi-module.js";
import type { SidecarManager } from "./modules/sidecar-manager.js";
import type {
  SnapshotId,
  Storage,
} from "./storage/types.js";

export class SnapshotNotFound extends Error {
  constructor(public readonly snapshotId: SnapshotId) {
    super(`snapshot ${snapshotId} not found`);
  }
}

export type TickContext = {
  snapshotId: SnapshotId;
  api: ApiModule;
  ffi: FfiModule;
  core: CoreModule;
  bus: ExternalEventBus;
  tx: Storage;
};

export class Orchestrator {
  constructor(
    private readonly storage: Storage,
    private readonly sidecarManager: SidecarManager,
    private readonly logger: Logger,
  ) {
    sidecarManager.setMessageHandler((snapshotId, msg) =>
      this.onSidecarMessage(snapshotId, msg),
    );
  }

  /**
   * One tick of request processing for `snapshotId`. The user `fn`
   * pushes initial events into `ctx.bus` (= via `ApiModule.startAgent`
   * etc.) and returns whatever the HTTP layer needs.
   */
  async tick<T>(
    snapshotId: SnapshotId,
    fn: (ctx: TickContext) => Promise<T>,
  ): Promise<T> {
    return this.storage.withTransaction(async (tx) => {
      return tx.withSnapshotLock(tx, snapshotId, async () => {
        const snapshot = await tx.snapshots.get(snapshotId);
        if (snapshot === null) throw new SnapshotNotFound(snapshotId);

        // Make sure the sidecar exists (idempotent).
        await this.sidecarManager.ensureStarted({
          snapshotId,
          bundle: snapshot.sidecarBundle,
        });

        const core = new CoreModule({
          endpoint: CORE_ENDPOINT,
          snapshotId,
          irModule: snapshot.irModule,
          logger: this.logger,
        });
        const api = new ApiModule({ snapshotId, tx, logger: this.logger });
        const ffi = new FfiModule({
          snapshotId,
          tx,
          sidecarManager: this.sidecarManager,
          logger: this.logger,
        });

        const bus = new ExternalEventBus(this.logger);
        bus.registerAll([
          { name: "api", module: api },
          { name: "core", module: core },
          { name: "ffi", module: ffi },
        ]);

        await core.load({ coreCheckpoints: tx.checkpoints });

        const ctx: TickContext = { snapshotId, api, ffi, core, bus, tx };
        const result = await fn(ctx);

        await bus.drain();

        await core.persist({ coreCheckpoints: tx.checkpoints });

        return result;
      });
    });
  }

  /**
   * Sidecar からの child→parent message を ExternalEvent に変換し、新しい
   * tick を起こす。
   *
   * Sidecar message → ExternalEvent への変換:
   *   - delegateAck     → FFI → CORE delegateAck
   *   - delegateError   → FFI → CORE delegateAck (with error sentinel
   *                                                value? for now, log + drop)
   *   - terminateAck    → FFI → CORE terminateAck
   *   - escalate        → FFI → CORE escalate
   *
   * `from` は FFI_ENDPOINT、`to` は元の peer (DB の peer_endpoint) を使う。
   * sidecar が知っているのは delegationId だけなので、peer は DB から逆引き。
   */
  private async onSidecarMessage(
    snapshotId: SnapshotId,
    msg: ChildToParent,
  ): Promise<void> {
    const event = await this.sidecarMessageToEvent(snapshotId, msg);
    if (event === null) return;
    await this.tick(snapshotId, async (ctx) => {
      ctx.bus.push(event);
    });
  }

  private async sidecarMessageToEvent(
    snapshotId: SnapshotId,
    msg: ChildToParent,
  ): Promise<ExternalEvent | null> {
    switch (msg.type) {
      case "delegateAck": {
        const peer = await this.lookupDelegationPeer(msg.delegationId);
        if (peer === null) return null;
        return {
          from: FFI_ENDPOINT,
          to: peer,
          payload: {
            kind: "delegateAck",
            delegationId: msg.delegationId,
            value: msg.value as Value,
          },
        };
      }
      case "delegateError": {
        // Surface as a recoverable failure: turn the in-flight FFI
        // delegation into a `terminateAck` and let CORE error out the
        // calling agent. Future work: dedicated `delegateError` event in
        // the 6-event protocol.
        const peer = await this.lookupDelegationPeer(msg.delegationId);
        this.logger.log("warn", "ffi sidecar delegate failed", {
          delegationId: msg.delegationId,
          message: msg.message,
        });
        if (peer === null) return null;
        return {
          from: FFI_ENDPOINT,
          to: peer,
          payload: {
            kind: "terminateAck",
            delegationId: msg.delegationId,
          },
        };
      }
      case "terminateAck": {
        const peer = await this.lookupDelegationPeer(msg.delegationId);
        if (peer === null) return null;
        return {
          from: FFI_ENDPOINT,
          to: peer,
          payload: {
            kind: "terminateAck",
            delegationId: msg.delegationId,
          },
        };
      }
      case "escalate": {
        const peer = await this.lookupDelegationPeer(msg.delegationId);
        if (peer === null) return null;
        // Persist the FFI's outbound escalate so terminations can clean up.
        await this.storage.ffiEscalations.insert({
          escalationId: msg.escalationId,
          delegationId: msg.delegationId,
          snapshotId,
          peerEndpoint: peer,
          agentDefId: msg.agentDefId,
          args: msg.args as Record<string, Value>,
          createdAt: new Date().toISOString(),
        });
        return {
          from: FFI_ENDPOINT,
          to: peer,
          payload: {
            kind: "escalate",
            delegationId: msg.delegationId,
            escalationId: msg.escalationId,
            agentDefId: msg.agentDefId,
            args: msg.args as Record<string, Value>,
          },
        };
      }
      case "ready":
      case "log":
        return null;
    }
  }

  private async lookupDelegationPeer(
    delegationId: import("katari-runtime").DelegationId,
  ): Promise<import("katari-runtime").Endpoint | null> {
    const row = await this.storage.ffiDelegations.get(delegationId);
    if (row === null) {
      this.logger.log("warn", "orchestrator: no FFI pending row for delegationId", {
        delegationId,
      });
      return null;
    }
    return row.peerEndpoint as import("katari-runtime").Endpoint;
  }

  /**
   * Boot 時: running/cancelling agent を持つ snapshot に対して subprocess
   * を spawn し、`restored` IPC で in-flight delegationId 一覧を通知する。
   */
  async recoverOnBoot(): Promise<void> {
    const snapshotIds = await this.storage.agents.listRunningSnapshotIds();
    for (const snapshotId of snapshotIds) {
      const snapshot = await this.storage.snapshots.get(snapshotId);
      if (snapshot === null) continue;
      await this.sidecarManager.ensureStarted({
        snapshotId,
        bundle: snapshot.sidecarBundle,
      });
      const pending = await this.storage.ffiDelegations.listBySnapshot(snapshotId);
      if (pending.length > 0 && this.sidecarManager.hasSidecar(snapshotId)) {
        await this.sidecarManager.send(snapshotId, {
          type: "restored",
          delegationIds: pending.map((p) => p.delegationId),
        });
      }
    }
  }
}

// Re-exports referenced by ffi-module / api-module via the runtime barrel.
void decodeFfiAgentDefId;
void encodeFfiAgentDefId;
