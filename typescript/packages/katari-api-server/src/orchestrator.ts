// Orchestrator — request 処理の中心。
//
// 各 HTTP request、または各 sidecar 応答が「1 tick」を起こす。tick は:
//
//   1. snapshot の row lock を取る (withTransaction + withSnapshotLock)
//   2. CoreModule を engine_checkpoints から load
//   3. ApiModule / FfiModule は per-tick で tx を抱えて作成
//   4. ExternalEventBus に 3 module を register
//   5. caller (HTTP route, または sidecar dispatcher) が初期 event を push
//   6. bus.drain() で全 event chain を解消
//   7. CoreModule.persist で checkpoint を書き戻す
//   8. commit
//
// FFI sidecar 応答は async に起きるので、orchestrator は SidecarManager の
// `setMessageHandler` 経由で「sidecar からの ChildToParent → tick 起動」
// 変換を引き受ける。

import {
  CORE_ENDPOINT,
  CoreModule,
  ExternalEventBus,
  FFI_ENDPOINT,
  FfiModule,
  valueFromRaw,
  type ChildToParent,
  type ExternalEvent,
  type Logger,
  type RawValue,
  type SidecarBundle,
  type SidecarManager,
  type Sidecar,
  type Value,
} from "@katari-lang/runtime";
import { ApiModule } from "./modules/api-module.js";
import { StorageFfiStore } from "./modules/ffi-store.js";
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
    private readonly sidecarManager: SidecarManager<SnapshotId>,
    private readonly logger: Logger,
  ) {
    sidecarManager.setMessageHandler((snapshotId, msg) =>
      this.onSidecarMessage(snapshotId, msg),
    );
  }

  async tick<T>(
    snapshotId: SnapshotId,
    fn: (ctx: TickContext) => Promise<T>,
  ): Promise<T> {
    return this.storage.withTransaction(async (tx) => {
      return tx.withSnapshotLock(tx, snapshotId, async () => {
        const snapshot = await tx.snapshots.get(snapshotId);
        if (snapshot === null) throw new SnapshotNotFound(snapshotId);

        // Make sure the sidecar process exists (idempotent).
        await this.sidecarManager.ensureStarted({
          key: snapshotId,
          bundle: snapshot.sidecarBundle,
        });

        const core = new CoreModule({
          endpoint: CORE_ENDPOINT,
          snapshotId,
          irModule: snapshot.irModule,
          logger: this.logger,
        });
        const api = new ApiModule({ snapshotId, tx, logger: this.logger });

        const bus = new ExternalEventBus(this.logger);

        // FfiModule は scope-bound な FfiStore + 該当 sidecar を渡す。
        // sidecar が無い snapshot の場合は ffi module 自体を register しない。
        const sidecar = this.sidecarFor(snapshotId);
        let ffi: FfiModule;
        if (sidecar !== null) {
          const store = new StorageFfiStore(tx, snapshotId);
          ffi = new FfiModule({
            endpoint: FFI_ENDPOINT,
            sidecar,
            store,
            logger: this.logger,
            onSidecarResponse: (event) => bus.push(event),
          });
          bus.registerAll([
            { name: "api", module: api },
            { name: "core", module: core },
            { name: "ffi", module: ffi },
          ]);
        } else {
          // FFI を持たない snapshot 用に空の placeholder を用意 (= type
          // satisfaction)。delegate が来ても bus が "no module" warn を出す。
          ffi = makeNoOpFfi();
          bus.registerAll([
            { name: "api", module: api },
            { name: "core", module: core },
          ]);
        }

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
   * Boot 時: running/cancelling agent を持つ snapshot に対して subprocess
   * を spawn し、in-flight delegation について `restoredDelegate` を sidecar
   * に送る (FfiModule.recoverInflight)。
   */
  async recoverOnBoot(): Promise<void> {
    const snapshotIds = await this.storage.agents.listRunningSnapshotIds();
    for (const snapshotId of snapshotIds) {
      const snapshot = await this.storage.snapshots.get(snapshotId);
      if (snapshot === null) continue;
      await this.sidecarManager.ensureStarted({
        key: snapshotId,
        bundle: snapshot.sidecarBundle,
      });
      const sidecar = this.sidecarFor(snapshotId);
      if (sidecar === null) continue;
      // recoverInflight needs an FfiModule + FfiStore bound to this snapshot.
      // Run inside a short tx so the store reads are consistent.
      await this.storage.withTransaction(async (tx) => {
        const store = new StorageFfiStore(tx, snapshotId);
        const ffi = new FfiModule({
          endpoint: FFI_ENDPOINT,
          sidecar,
          store,
          logger: this.logger,
          // Sidecar responses produced during recoverInflight will be
          // routed when the next tick fires (= next sidecar message
          // handler invocation). Here we drop synchronous sidecar
          // responses; the real responses come back asynchronously
          // through `setMessageHandler`.
          onSidecarResponse: () => {},
        });
        await ffi.recoverInflight();
      });
    }
  }

  // ─── Sidecar message handler ────────────────────────────────────────────

  private async onSidecarMessage(
    snapshotId: SnapshotId,
    msg: ChildToParent,
  ): Promise<void> {
    // Open a fresh tick and route the message through the per-tick
    // FfiModule. FfiModule.dispatchSidecarMessage updates the store
    // and pushes the resulting bus events; bus.drain() then runs the
    // engine + downstream modules to completion.
    await this.tick(snapshotId, async (ctx) => {
      await ctx.ffi.dispatchSidecarMessage(msg);
    }).catch((err) => {
      // A failed tick on a sidecar message means the originating
      // delegation is stuck — the ack/throw it was carrying never
      // applied. We log the delegationId (when present) so operators
      // can locate the agent. A future revision should transition the
      // affected delegation to `error` in a fresh tx; for now the
      // operator must inspect logs and manually cancel.
      const delegationId =
        "delegationId" in msg ? msg.delegationId : "(none)";
      this.logger.log("error", "orchestrator: tick failed for sidecar message", {
        snapshotId,
        type: msg.type,
        delegationId,
        err: err instanceof Error ? err.message : String(err),
        stack: err instanceof Error ? err.stack : undefined,
      });
    });
  }

  private sidecarFor(snapshotId: SnapshotId): Sidecar | null {
    if (!this.sidecarManager.hasSidecar(snapshotId)) return null;
    // SidecarManager doesn't expose direct Sidecar references; we proxy
    // via a thin shim that forwards `send` and stores the inbound handler
    // for the FfiModule to receive sidecar messages. The per-tick
    // FfiModule then uses this proxy as its sidecar.
    const manager = this.sidecarManager;
    return {
      async send(msg) {
        await manager.send(snapshotId, msg);
      },
      onMessage(_cb) {
        // The real message handler is set on the manager via
        // setMessageHandler in the orchestrator constructor; per-tick
        // FfiModule subscriptions are no-op (the orchestrator-level
        // dispatch routes each message to a fresh tick).
      },
      async start() {
        // Already started by ensureStarted.
      },
      async shutdown() {
        // Lifecycle owned by SidecarManager.
      },
    };
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

function makeNoOpFfi(): FfiModule {
  // Used when a snapshot has no sidecar bundle. delegations are still
  // routed via `bus.registerAll` minus `ffi`, so this object is a pure
  // type-fill — never invoked.
  return {} as FfiModule;
}

/** Lift the sidecar-side raw `args` map into the bus's internal `Value`
 * shape. Used when forwarding a sidecar `escalate` into the bus. */
function argsRawToValue(
  args: Record<string, RawValue>,
): Record<string, Value> {
  const out: Record<string, Value> = {};
  for (const [k, v] of Object.entries(args)) out[k] = valueFromRaw(v);
  return out;
}
