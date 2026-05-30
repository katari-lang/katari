// Orchestrator — the heart of request processing.
//
// Each HTTP request, or each sidecar response, triggers "one tick". A tick:
//
//   1. Acquires the snapshot row lock (withTransaction + withSnapshotLock)
//   2. Loads the snapshot (irModule + sidecarBundle)
//   3. Builds per-tick modules via the injected TickModulesFactory
//   4. Registers modules on ExternalEventBus
//   5. The caller (HTTP route, or sidecar dispatcher) pushes the initial event
//   6. bus.drain() resolves the entire event chain
//   7. CoreModule.persist writes back the checkpoint
//   8. commit
//
// The Orchestrator is parameterized over:
//   - `OrchestratorStorage`  — snapshot resolution, locking, recovery queries
//   - `TickModulesFactory`   — builds per-tick modules with concrete storage adapters
//
// This allows the Orchestrator to live in `@katari-lang/runtime` while
// concrete storage / module wiring stays in the host package (api-server,
// local CLI, etc.).

import { ExternalEventBus } from "../bus.js";
import type { Logger } from "../engine/logger.js";
import type { CoreModule } from "../modules/core.js";
import type { FfiModule } from "../modules/ffi.js";
import type { SidecarManager } from "../sidecar/sidecar-manager.js";
import type { ChildToParent } from "../sidecar/types.js";
import type {
  ApiLikeModule,
  OrchestratorProjectId,
  OrchestratorSnapshotId,
  OrchestratorStorage,
  ResolvedSnapshot,
  TickModulesFactory,
} from "./types.js";

export type TickContext<SnapshotId extends OrchestratorSnapshotId = OrchestratorSnapshotId> = {
  snapshotId: SnapshotId;
  api: ApiLikeModule;
  ffi: FfiModule | null;
  core: CoreModule;
  bus: ExternalEventBus;
  /**
   * The transactional storage handle for this tick. The host can
   * downcast to its concrete type when the route handler needs
   * direct storage access (e.g. `runsAudit.list`).
   */
  storage: OrchestratorStorage<SnapshotId>;
};

/** Thrown when the snapshot id passed to `tick` does not exist. */
export class SnapshotNotFound extends Error {
  constructor(public readonly snapshotId: string) {
    super(`snapshot ${snapshotId} does not exist`);
  }
}

/** Thrown when no snapshot exists for the given project. */
export class NoSnapshotForProject extends Error {
  constructor(public readonly projectId: string) {
    super(`no snapshot exists for project ${projectId}`);
  }
}

export class Orchestrator<
  SnapshotId extends OrchestratorSnapshotId = OrchestratorSnapshotId,
  ProjectId extends OrchestratorProjectId = OrchestratorProjectId,
> {
  constructor(
    private readonly storage: OrchestratorStorage<SnapshotId, ProjectId>,
    private readonly factory: TickModulesFactory<SnapshotId>,
    private readonly sidecarManager: SidecarManager<SnapshotId>,
    private readonly logger: Logger,
  ) {
    sidecarManager.setMessageHandler((snapshotId, msg) => this.onSidecarMessage(snapshotId, msg));
  }

  async tick<T>(
    snapshotId: SnapshotId,
    fn: (ctx: TickContext<SnapshotId>) => Promise<T>,
  ): Promise<T> {
    return this.runTick(async (tx) => {
      const sid = snapshotId;
      const snapshot = await tx.getSnapshot(sid);
      if (snapshot === null) throw new SnapshotNotFound(sid);
      return { snapshotId: sid, snapshot };
    }, fn);
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
    fn: (ctx: TickContext<SnapshotId>) => Promise<T>,
  ): Promise<T> {
    return this.runTick(async (tx) => {
      let sid = input.snapshotId;
      if (sid === undefined) {
        const latest = await tx.latestSnapshot(input.projectId);
        if (latest === null) throw new NoSnapshotForProject(input.projectId);
        sid = latest;
      }
      const snapshot = await tx.getSnapshot(sid);
      if (snapshot === null) throw new SnapshotNotFound(sid);
      return { snapshotId: sid, snapshot };
    }, fn);
  }

  private async runTick<T>(
    resolveSnapshot: (tx: OrchestratorStorage<SnapshotId, ProjectId>) => Promise<{
      snapshotId: SnapshotId;
      snapshot: ResolvedSnapshot;
    }>,
    fn: (ctx: TickContext<SnapshotId>) => Promise<T>,
  ): Promise<T> {
    return this.storage.withTransaction(async (tx) => {
      const { snapshotId, snapshot } = await resolveSnapshot(tx);
      return tx.withSnapshotLock(tx, snapshotId, async () => {
        // Make sure the sidecar process exists (idempotent).
        await this.sidecarManager.ensureStarted({
          key: snapshotId,
          bundle: snapshot.sidecarBundle,
        });

        const bus = new ExternalEventBus(this.logger);

        const modules = this.factory.build({
          snapshotId,
          snapshot,
          logger: this.logger,
          bus,
        });

        // Register modules on the bus. FfiModule is optional.
        if (modules.ffi !== null) {
          bus.registerAll([
            { name: "api", module: modules.api },
            { name: "core", module: modules.core },
            { name: "ffi", module: modules.ffi },
            { name: "env", module: modules.env },
          ]);
        } else {
          bus.registerAll([
            { name: "api", module: modules.api },
            { name: "core", module: modules.core },
            { name: "env", module: modules.env },
          ]);
        }

        await modules.core.load({});
        // FfiModule keeps an in-memory escalation relay map; load()
        // rebuilds it from the persisted rows. Without this, a
        // CORE->FFI->CORE escalateAck arriving in a later tick than the
        // original escalate is dropped as "unknown escalation" (the
        // per-tick instance starts with an empty map).
        if (modules.ffi !== null) await modules.ffi.load();

        const ctx: TickContext<SnapshotId> = {
          snapshotId,
          api: modules.api,
          ffi: modules.ffi,
          core: modules.core,
          bus,
          storage: tx,
        };
        const result = await fn(ctx);

        await bus.drain();

        await modules.core.persist({});

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
    const snapshotIds = await this.storage.listLiveSnapshotIds();
    for (const snapshotId of snapshotIds) {
      const snapshot = await this.storage.getSnapshot(snapshotId);
      if (snapshot === null) continue;
      await this.sidecarManager.ensureStarted({
        key: snapshotId,
        bundle: snapshot.sidecarBundle,
      });
      // recoverInflight needs an FfiModule + FfiStore bound to this snapshot.
      // Run inside a short tx so reads are consistent.
      await this.storage.withTransaction(async (_tx) => {
        const bus = new ExternalEventBus(this.logger);
        const modules = this.factory.build({
          snapshotId,
          snapshot,
          logger: this.logger,
          bus,
        });
        if (modules.ffi !== null) {
          await modules.ffi.recoverInflight();
        }
      });
    }
  }

  // ─── Sidecar message handler ────────────────────────────────────────────

  private async onSidecarMessage(snapshotId: SnapshotId, msg: ChildToParent): Promise<void> {
    await this.tick(snapshotId, async (ctx) => {
      if (ctx.ffi === null) {
        this.logger.log("error", "orchestrator: sidecar message for snapshot without FfiModule", {
          snapshotId,
          type: msg.type,
        });
        return;
      }
      await ctx.ffi.dispatchSidecarMessage(msg);
    }).catch((err) => {
      const delegationId = "delegationId" in msg ? msg.delegationId : "(none)";
      this.logger.log("error", "orchestrator: tick failed for sidecar message", {
        snapshotId,
        type: msg.type,
        delegationId,
        err: err instanceof Error ? err.message : String(err),
        stack: err instanceof Error ? err.stack : undefined,
      });
    });
  }
}
