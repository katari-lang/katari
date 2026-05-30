// Concrete OrchestratorStorage + TickModulesFactory for api-server.
//
// These adapters bridge the runtime's abstract orchestrator interfaces to
// the api-server's Storage interface, concrete adapters, and ApiModule.
//
// The key challenge is that `TickModulesFactory.build()` is called inside
// `withTransaction`, so the modules need a tx-scoped Storage handle. We
// thread it via `AsyncLocalStorage`: `withTransaction` calls `run(tx,
// ...)`, and `factory.build` reads `getStore()`. A previous implementation
// used a shared `{ current: tx }` ref — that broke under concurrent ticks
// (= the second tick to enter `withTransaction` overwrote the first
// tick's tx; the first tick's modules then sent queries on the second
// tick's pg connection, which was already blocked on the advisory-lock
// acquire that only the first tick could release → cross-tick deadlock,
// 10-connection pool exhausted, every HTTP request hung).
//
// `AsyncLocalStorage.run(tx, fn)` scopes `tx` to `fn`'s async chain only,
// so concurrent ticks each see their own tx.

import { AsyncLocalStorage } from "node:async_hooks";
import {
  CORE_ENDPOINT,
  CoreModule,
  ENV_ENDPOINT,
  EnvModule,
  type ExternalEventBus,
  FFI_ENDPOINT,
  FfiModule,
  type Logger,
  Orchestrator,
  type OrchestratorStorage,
  type ParentToChild,
  type ResolvedSnapshot,
  type SidecarManager,
  type TickContext,
  type TickModules,
  type TickModulesFactory,
} from "@katari-lang/runtime";
import { ApiModule } from "./adapters/api-module.js";
import { StorageDelegationStore } from "./adapters/delegation-store.js";
import { StorageEnvStore } from "./adapters/env-store.js";
import { StorageFfiStore } from "./adapters/ffi-store.js";
import type { ProjectId, SnapshotId, Storage } from "./storage/types.js";

// ─── Api-server-specific TickContext ───────────────────────────────────────

/**
 * Api-server's enriched TickContext. The `api` field is narrowed to the
 * concrete `ApiModule` so route handlers can call domain methods
 * (startRun, cancelRun, answerEscalation, ...).
 *
 * Since the runtime's `TickContext.api` is typed as `ApiLikeModule`
 * (= `Module`), callers that need `ApiModule` methods cast through this
 * type at the tick call site.
 */
export type ApiServerTickContext = TickContext<SnapshotId> & {
  api: ApiModule;
};

// ─── ApiServerOrchestrator ────────────────────────────────────────────────

/**
 * Thin wrapper that narrows the runtime Orchestrator's `TickContext` to
 * `ApiServerTickContext` so route handlers can access `ctx.api.startRun`
 * etc. without manual casting.
 *
 * At runtime the `api` field is already an `ApiModule` (the factory
 * creates it); the wrapper only adjusts the TypeScript types.
 */
export class ApiServerOrchestrator {
  constructor(private readonly inner: Orchestrator<SnapshotId, ProjectId>) {}

  async tick<T>(snapshotId: SnapshotId, fn: (ctx: ApiServerTickContext) => Promise<T>): Promise<T> {
    return this.inner.tick(snapshotId, (ctx) => fn(ctx as ApiServerTickContext));
  }

  async tickResolved<T>(
    input: { projectId: ProjectId; snapshotId?: SnapshotId | undefined },
    fn: (ctx: ApiServerTickContext) => Promise<T>,
  ): Promise<T> {
    return this.inner.tickResolved(input, (ctx) => fn(ctx as ApiServerTickContext));
  }

  async recoverOnBoot(): Promise<void> {
    return this.inner.recoverOnBoot();
  }
}

// ─── Convenience: create an Orchestrator for api-server ───────────────────

/**
 * Creates an Orchestrator wired to the api-server's Storage and adapters.
 *
 * Internally, a mutable `txRef` is shared between the OrchestratorStorage
 * adapter and the TickModulesFactory so `factory.build()` always sees the
 * transaction-scoped Storage, even though it's set once at construction.
 */
export function createApiServerOrchestrator(
  storage: Storage,
  sidecarManager: SidecarManager<SnapshotId>,
  logger: Logger,
): ApiServerOrchestrator {
  // Per-tick tx threaded via AsyncLocalStorage so concurrent ticks don't
  // clobber each other's tx (see file header). Reads outside any tick
  // fall back to the non-tx-scoped top-level `storage`.
  const txStore = new AsyncLocalStorage<Storage>();
  const currentTx = (): Storage => txStore.getStore() ?? storage;

  const adapter = buildStorageAdapter(storage, txStore);
  const factory = buildTickModulesFactory(currentTx, sidecarManager);

  const inner = new Orchestrator<SnapshotId, ProjectId>(adapter, factory, sidecarManager, logger);
  return new ApiServerOrchestrator(inner);
}

// ─── Internal: OrchestratorStorage adapter ────────────────────────────────

function buildStorageAdapter(
  storage: Storage,
  txStore: AsyncLocalStorage<Storage>,
): OrchestratorStorage<SnapshotId, ProjectId> {
  const self: OrchestratorStorage<SnapshotId, ProjectId> = {
    async withTransaction<T>(
      fn: (tx: OrchestratorStorage<SnapshotId, ProjectId>) => Promise<T>,
    ): Promise<T> {
      return storage.withTransaction(async (tx) => {
        const txAdapter: OrchestratorStorage<SnapshotId, ProjectId> = {
          // Nested transactions reuse the same adapter shape.
          withTransaction: self.withTransaction,

          async withSnapshotLock<T2>(
            _txArg: OrchestratorStorage<SnapshotId, ProjectId>,
            snapshotId: SnapshotId,
            fn2: () => Promise<T2>,
          ): Promise<T2> {
            return tx.withSnapshotLock(tx, snapshotId, fn2);
          },

          async getSnapshot(id: SnapshotId) {
            const snap = await tx.snapshots.get(id);
            if (snap === null) return null;
            return {
              projectId: snap.projectId,
              irModule: snap.irModule,
              sidecarBundle: snap.sidecarBundle,
            };
          },

          async latestSnapshot(projectId: ProjectId) {
            return tx.snapshots.latest(projectId);
          },

          async listLiveSnapshotIds() {
            return tx.delegations.listLiveSnapshotIds();
          },
        };
        return txStore.run(tx, () => fn(txAdapter));
      });
    },

    async withSnapshotLock<T>(
      _tx: OrchestratorStorage<SnapshotId, ProjectId>,
      snapshotId: SnapshotId,
      fn: () => Promise<T>,
    ): Promise<T> {
      return storage.withSnapshotLock(storage, snapshotId, fn);
    },

    async getSnapshot(id: SnapshotId) {
      const snap = await storage.snapshots.get(id);
      if (snap === null) return null;
      return {
        projectId: snap.projectId,
        irModule: snap.irModule,
        sidecarBundle: snap.sidecarBundle,
      };
    },

    async latestSnapshot(projectId: ProjectId) {
      return storage.snapshots.latest(projectId);
    },

    async listLiveSnapshotIds() {
      return storage.delegations.listLiveSnapshotIds();
    },
  };

  return self;
}

// ─── Internal: TickModulesFactory ─────────────────────────────────────────

function buildTickModulesFactory(
  currentTx: () => Storage,
  sidecarManager: SidecarManager<SnapshotId>,
): TickModulesFactory<SnapshotId> {
  return {
    build(opts: {
      snapshotId: SnapshotId;
      snapshot: ResolvedSnapshot;
      logger: Logger;
      bus: ExternalEventBus;
    }): TickModules {
      const tx = currentTx();
      const { snapshotId, snapshot, logger, bus } = opts;

      const core = new CoreModule({
        endpoint: CORE_ENDPOINT,
        snapshotId,
        irModule: snapshot.irModule,
        logger,
        delegationStore: new StorageDelegationStore(tx, snapshotId),
        // Persist-time promotion: large inline strings in CORE state are
        // written to the (tx-scoped) value store as owner=core refs so the
        // checkpoint stays small. projectId scopes the refs.
        projectId: snapshot.projectId,
        valueStore: tx.values,
      });

      const api = new ApiModule({ snapshotId, tx, logger });

      const env = new EnvModule({
        endpoint: ENV_ENDPOINT,
        store: new StorageEnvStore(tx),
        logger,
        onBusResponse: (event) => bus.push(event),
      });

      let ffi: FfiModule | null = null;
      if (sidecarManager.hasSidecar(snapshotId)) {
        const mgr = sidecarManager;
        const sidecar = {
          async send(msg: ParentToChild) {
            await mgr.send(snapshotId, msg);
          },
          onMessage(_cb: unknown) {},
          async start() {},
          async shutdown() {},
        };
        const store = new StorageFfiStore(tx, snapshotId);
        ffi = new FfiModule({
          endpoint: FFI_ENDPOINT,
          sidecar,
          store,
          logger,
          onSidecarResponse: (event) => bus.push(event),
        });
      }

      return { core, api, ffi, env, checkpoints: tx.checkpoints };
    },
  };
}
