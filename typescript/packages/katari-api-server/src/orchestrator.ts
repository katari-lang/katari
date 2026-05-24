// Orchestrator — the heart of request processing.
//
// Each HTTP request, or each sidecar response, triggers "one tick". A tick:
//
//   1. Acquires the snapshot row lock (withTransaction + withSnapshotLock)
//   2. Loads CoreModule from engine_checkpoints
//   3. Creates ApiModule / FfiModule per-tick with a transaction
//   4. Registers the 3 modules on ExternalEventBus
//   5. The caller (HTTP route, or sidecar dispatcher) pushes the initial event
//   6. bus.drain() resolves the entire event chain
//   7. CoreModule.persist writes back the checkpoint
//   8. commit
//
// Since FFI sidecar responses happen asynchronously, the orchestrator handles
// the "ChildToParent from sidecar -> tick launch" conversion via
// SidecarManager's `setMessageHandler`.

import {
  CORE_ENDPOINT,
  CoreModule,
  ENV_ENDPOINT,
  EnvModule,
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
import { StorageEnvStore } from "./modules/env-store.js";
import { StorageFfiStore } from "./modules/ffi-store.js";
import { StorageDelegationStore } from "./modules/delegation-store.js";
import {
  NoSnapshotForProject,
  SnapshotNotFound,
} from "./services/snapshot-service.js";
import type {
  ProjectId,
  SnapshotId,
  Storage,
} from "./storage/types.js";

// Re-exported so callers that import from the orchestrator (= the public
// entry for tick error mapping) can still resolve them. The canonical
// definitions live in services/snapshot-service.ts.
export { NoSnapshotForProject, SnapshotNotFound };

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
    return this.runTick(
      async (tx) => {
        const sid = snapshotId;
        const snapshot = await tx.snapshots.get(sid);
        if (snapshot === null) throw new SnapshotNotFound(sid);
        return { snapshotId: sid, snapshot };
      },
      fn,
    );
  }

  /**
   * Like 'tick', but resolves the snapshot id inside the transaction.
   * Use this when the caller has `(projectId, snapshotId?)` rather than
   * a concrete snapshot id; the old shape resolved the snapshot via a
   * separate read first, leaving a window where the snapshot could be
   * deleted before the tick acquired its lock.
   */
  async tickResolved<T>(
    input: { projectId: ProjectId; snapshotId?: SnapshotId | undefined },
    fn: (ctx: TickContext) => Promise<T>,
  ): Promise<T> {
    return this.runTick(
      async (tx) => {
        let sid = input.snapshotId;
        if (sid === undefined) {
          const latest = await tx.snapshots.latest(input.projectId);
          if (latest === null) throw new NoSnapshotForProject(input.projectId);
          sid = latest;
        }
        const snapshot = await tx.snapshots.get(sid);
        if (snapshot === null) throw new SnapshotNotFound(sid);
        return { snapshotId: sid, snapshot };
      },
      fn,
    );
  }

  private async runTick<T>(
    resolveSnapshot: (
      tx: Storage,
    ) => Promise<{
      snapshotId: SnapshotId;
      snapshot: NonNullable<Awaited<ReturnType<Storage["snapshots"]["get"]>>>;
    }>,
    fn: (ctx: TickContext) => Promise<T>,
  ): Promise<T> {
    return this.storage.withTransaction(async (tx) => {
      const { snapshotId, snapshot } = await resolveSnapshot(tx);
      return tx.withSnapshotLock(tx, snapshotId, async () => {

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
          // Audit sink for outbound delegate events. Writes one row to
          // `delegations` per CORE → X call so the admin tree view can
          // render the call hierarchy. Scoped to this snapshot.
          delegationStore: new StorageDelegationStore(tx, snapshotId),
        });
        const api = new ApiModule({ snapshotId, tx, logger: this.logger });

        const bus = new ExternalEventBus(this.logger);

        const env = new EnvModule({
          endpoint: ENV_ENDPOINT,
          store: new StorageEnvStore(tx),
          logger: this.logger,
          onBusResponse: (event) => bus.push(event),
        });

        // Pass FfiModule a scope-bound FfiStore + the corresponding sidecar.
        // For snapshots without a sidecar, don't register the ffi module itself.
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
            { name: "env", module: env },
          ]);
        } else {
          // Prepare an empty placeholder for snapshots without FFI (= type
          // satisfaction). If a delegate arrives, the bus emits a "no module" warn.
          ffi = makeNoOpFfi();
          bus.registerAll([
            { name: "api", module: api },
            { name: "core", module: core },
            { name: "env", module: env },
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
   * On boot: for each snapshot that has running/cancelling agents, spawn
   * the subprocess and send `restoredDelegate` to the sidecar for any
   * in-flight delegations (FfiModule.recoverInflight).
   */
  async recoverOnBoot(): Promise<void> {
    // Snapshots that still own a live delegation (= ApiModule-issued root,
    // or a child CORE / FFI hasn't acked yet) — these need their sidecar
    // respawned so in-flight ext calls don't sit forever.
    const snapshotIds = await this.storage.delegations.listLiveSnapshotIds();
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
  // routed via `bus.registerAll` minus `ffi`, so this object SHOULD
  // never be invoked. Returning `{} as FfiModule` would crash with
  // "x is not a function" on any accidental call. Throw a clear error
  // instead so a registration bug surfaces with a useful message.
  const thrower =
    (method: string): ((...args: unknown[]) => never) =>
    () => {
      throw new Error(
        `orchestrator: FfiModule.${method} called on a sidecar-less snapshot — this is a registration bug`,
      );
    };
  return {
    feed: thrower("feed"),
    persist: thrower("persist"),
    load: thrower("load"),
    recoverInflight: thrower("recoverInflight"),
    dispatchSidecarMessage: thrower("dispatchSidecarMessage"),
  } as unknown as FfiModule;
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
