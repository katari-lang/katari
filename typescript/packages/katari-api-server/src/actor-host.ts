// Concrete warm per-project actor host for api-server.
//
// Replaces the old per-snapshot Orchestrator. A single ApiServerActorHost owns
// one warm ProjectActor per project (created on first touch, kept warm). Each
// actor wires the 4 modules (core / api / env / ffi-mux) onto its bus and
// serializes every quantum for its project. The host holds no transaction and
// no lock — each module opens its own tx inside `feed` (1 quantum = 1 tx).
//
// The host's extra responsibilities over the generic ProjectActorHost:
//   - build the concrete module bundle for a project (with storage adapters)
//   - route sidecar messages (snapshot → project → actor → ffi lane)
//   - boot recovery (respawn sidecars for snapshots with in-flight ext work)

import {
  type ChildToParent,
  CORE_ENDPOINT,
  CoreModule,
  type CoreStorage,
  type DelegationId,
  EnvModule,
  type EscalationId,
  type ExternalEventBus,
  type FfiLaneBackend,
  FfiMux,
  type IRModule,
  type Logger,
  type ParentToChild,
  type ProjectActor,
  type ProjectActorContext,
  ProjectActorHost,
  type Sidecar,
  type SidecarManager,
} from "@katari-lang/runtime";
import { ApiModule } from "./adapters/api-module.js";
import { StorageEntityStore } from "./adapters/entity-store.js";
import { StorageEnvStore } from "./adapters/env-store.js";
import { StorageFfiStore } from "./adapters/ffi-store.js";
import type { ProjectId, SnapshotId, Storage } from "./storage/types.js";

/** Concrete module bundle for one project's actor. */
export type ApiServerModules = {
  core: CoreModule;
  api: ApiModule;
  env: EnvModule;
  ffi: FfiMux | null;
};

export type ApiServerActorContext = ProjectActorContext<ApiServerModules>;

/** Katari Protocol coordinates a spawned sidecar needs to call back into this
 *  api-server's data plane (produce / consume / persist). */
export type SidecarProtocolCoords = {
  /** Base URL of this api-server (e.g. http://127.0.0.1:8000). */
  baseUrl: string;
  /** Bearer token (= the api key) the sidecar presents on protocol calls. */
  token: string;
};

export class ApiServerActorHost {
  private readonly host: ProjectActorHost<ApiServerModules>;

  constructor(
    private readonly storage: Storage,
    private readonly sidecarManager: SidecarManager<SnapshotId>,
    private readonly logger: Logger,
    private readonly protocol: SidecarProtocolCoords,
  ) {
    this.host = new ProjectActorHost<ApiServerModules>(
      (projectId, bus) => this.buildModules(projectId as ProjectId, bus),
      logger,
    );
    // A sidecar message (the manager keys it by snapshot) re-enters its
    // project's actor as a serialized quantum, dispatched into the right lane.
    sidecarManager.setMessageHandler((snapshotId, msg) => this.onSidecarMessage(snapshotId, msg));
  }

  /** Run one serialized quantum on `projectId`'s warm actor. */
  runForProject<T>(
    projectId: ProjectId,
    fn: (ctx: ApiServerActorContext) => Promise<T>,
  ): Promise<T> {
    return this.host.forProject(projectId).run(fn);
  }

  /** The warm actor for `projectId` (created on first touch). */
  actor(projectId: ProjectId): ProjectActor<ApiServerModules> {
    return this.host.forProject(projectId);
  }

  // ─── Module factory ──────────────────────────────────────────────────────

  private buildModules(projectId: ProjectId, bus: ExternalEventBus): ApiServerModules {
    const storage = this.storage;
    const logger = this.logger;

    const coreStorage: CoreStorage = {
      withTransaction: (fn) =>
        storage.withTransaction((tx) =>
          fn({
            shards: tx.shards,
            projectIndex: tx.projectIndex,
            values: tx.values,
            entities: new StorageEntityStore(tx, projectId),
          }),
        ),
    };

    const getIR = async (snapshot: string): Promise<IRModule> => {
      const snap = await storage.snapshots.get(snapshot as SnapshotId);
      if (snap === null) throw new Error(`core.getIR: snapshot ${snapshot} not found`);
      return snap.irModule;
    };

    const core = new CoreModule({
      endpoint: CORE_ENDPOINT,
      projectId,
      storage: coreStorage,
      getIR,
      logger,
    });

    const api = new ApiModule({ projectId, storage, logger });

    const env = new EnvModule({
      store: new StorageEnvStore(storage, projectId),
      logger,
      onBusResponse: (event) => bus.push(event),
    });

    const ffi = new FfiMux(
      this.ffiBackend(projectId),
      (event) => bus.push(event),
      logger,
      // Project-scoped (root storage, non-tx like the FFI relay store): the FFI
      // ext entities + the refs ext code produces. The lane mints an ext entity
      // per inbound delegate and ascends its escaping refs on terminal.
      new StorageEntityStore(storage, projectId),
      storage.values,
      projectId,
    );

    return { core, api, env, ffi };
  }

  private ffiBackend(projectId: ProjectId): FfiLaneBackend {
    const storage = this.storage;
    const sidecarManager = this.sidecarManager;
    const protocol = this.protocol;
    return {
      async ensureSidecar(snapshot: string): Promise<boolean> {
        const snap = await storage.snapshots.get(snapshot as SnapshotId);
        // The sidecar runs user ext code; it reaches our value data plane via
        // the Katari Protocol env (katari-port reads these). PROJECT_ID is
        // per-project; OWNER=ffi tags refs the ext produces. The api key flows
        // as PROTOCOL_TOKEN (a distinct name, so the subprocess env filter that
        // strips KATARI_API_KEY does not also strip this).
        await sidecarManager.ensureStarted({
          key: snapshot as SnapshotId,
          bundle: snap?.sidecarBundle ?? null,
          env: {
            KATARI_PROTOCOL_URL: protocol.baseUrl,
            KATARI_PROTOCOL_TOKEN: protocol.token,
            KATARI_PROJECT_ID: projectId,
            KATARI_SIDECAR_OWNER: "ffi",
          },
        });
        return sidecarManager.hasSidecar(snapshot as SnapshotId);
      },
      sidecar(snapshot: string): Sidecar {
        return {
          async send(msg: ParentToChild) {
            await sidecarManager.send(snapshot as SnapshotId, msg);
          },
          onMessage() {},
          async start() {},
          async shutdown() {},
        };
      },
      store(snapshot: string) {
        return new StorageFfiStore(storage, snapshot as SnapshotId);
      },
      async delegationSnapshot(delegationId: DelegationId): Promise<string | null> {
        return (await storage.ffiDelegations.get(delegationId))?.snapshotId ?? null;
      },
      async escalationSnapshot(escalationId: EscalationId): Promise<string | null> {
        return (await storage.ffiEscalations.get(escalationId))?.snapshotId ?? null;
      },
    };
  }

  // ─── Sidecar message routing ────────────────────────────────────────────

  private async onSidecarMessage(snapshotId: SnapshotId, msg: ChildToParent): Promise<void> {
    const snap = await this.storage.snapshots.get(snapshotId);
    if (snap === null) {
      this.logger.log("warn", "actor-host: sidecar message for unknown snapshot", { snapshotId });
      return;
    }
    await this.runForProject(snap.projectId, async ({ modules }) => {
      if (modules.ffi !== null) {
        await modules.ffi.dispatchSidecarMessage(snapshotId, msg);
      }
    }).catch((err) => {
      this.logger.log("error", "actor-host: sidecar message tick failed", {
        snapshotId,
        err: err instanceof Error ? err.message : String(err),
      });
    });
  }

  // ─── Boot recovery ──────────────────────────────────────────────────────

  /**
   * Respawn sidecars + notify in-flight ext delegations for every snapshot
   * that still owns FFI work, then run each lane's `recoverInflight`.
   */
  async recoverOnBoot(): Promise<void> {
    const snapshotIds = await this.storage.ffiDelegations.listLiveSnapshotIds();
    for (const snapshotId of snapshotIds) {
      const snap = await this.storage.snapshots.get(snapshotId);
      if (snap === null) continue;
      await this.runForProject(snap.projectId, async ({ modules }) => {
        if (modules.ffi !== null) await modules.ffi.recoverLane(snapshotId);
      }).catch((err) => {
        this.logger.log("error", "actor-host: ffi recovery failed", {
          snapshotId,
          err: err instanceof Error ? err.message : String(err),
        });
      });
    }
  }
}

export function createApiServerHost(
  storage: Storage,
  sidecarManager: SidecarManager<SnapshotId>,
  logger: Logger,
  protocol: SidecarProtocolCoords,
): ApiServerActorHost {
  return new ApiServerActorHost(storage, sidecarManager, logger, protocol);
}
