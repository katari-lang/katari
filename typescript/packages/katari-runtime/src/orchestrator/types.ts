// Abstract storage / factory interfaces the Orchestrator depends on.
//
// The Orchestrator needs to:
//   1. Resolve a snapshot id (from project or directly)
//   2. Acquire a per-snapshot lock inside a transaction
//   3. Construct the 4 modules (Core, Api, Ffi, Env) for one tick
//   4. Load/persist CoreModule state
//   5. List live snapshot ids for boot recovery
//
// Concrete implementations live in the host package (e.g. api-server
// provides Postgres-backed adapters). The Orchestrator itself lives in
// `@katari-lang/runtime` so it can be reused for `katari run --local`
// and other embeddings.

import type { ExternalEventBus } from "../bus.js";
import type { Logger } from "../engine/logger.js";
import type { IRModule } from "../ir/types.js";
import type { Module } from "../module.js";
import type { CoreModule } from "../modules/core.js";
import type { EnvModule } from "../modules/env.js";
import type { FfiModule } from "../modules/ffi.js";
import type { SidecarBundle } from "../sidecar/types.js";

// ─── Branded id types ─────────────────────────────────────────────────────
//
// The Orchestrator is generic over the host's id types. api-server uses
// `string & { __brand: "SnapshotId" }` etc.; a local CLI runner might
// use plain strings. We only require that they are strings at runtime.

/** A snapshot identifier. Branded in the host; the Orchestrator treats it as opaque. */
export type OrchestratorSnapshotId = string;

/** A project identifier. Branded in the host; the Orchestrator treats it as opaque. */
export type OrchestratorProjectId = string;

// ─── Resolved snapshot ────────────────────────────────────────────────────

/** The subset of a snapshot row the Orchestrator needs to build modules. */
export type ResolvedSnapshot = {
  /** Project the snapshot belongs to (= ambient scope for value refs). */
  projectId: string;
  irModule: IRModule;
  sidecarBundle: SidecarBundle | null;
};

// ─── Tick modules factory ─────────────────────────────────────────────────

/**
 * The "api" module inside a tick. The Orchestrator exposes it on
 * `TickContext` so route handlers can call domain methods (startRun,
 * cancelRun, answerEscalation, ...).
 *
 * We use `Module` as the lower bound — the Orchestrator doesn't know
 * about the concrete api module type. The host widens `TickContext.api`
 * at the call site.
 */
export type ApiLikeModule = Module;

/**
 * Bundle of per-tick modules that the host's factory produces.
 *
 * The Orchestrator registers them on the bus, calls load/persist where
 * needed, and exposes them on `TickContext`. The factory is responsible
 * for constructing the modules with the right storage adapters.
 */
export type TickModules = {
  core: CoreModule;
  api: ApiLikeModule;
  ffi: FfiModule | null;
  env: EnvModule;
};

/**
 * Factory that builds per-tick modules. Called once per tick inside the
 * transaction + snapshot lock.
 *
 * The host (api-server) implements this by constructing its concrete
 * `ApiModule`, `StorageFfiStore`, `StorageDelegationStore`, etc. from
 * the transactional `Storage` handle.
 */
export interface TickModulesFactory<
  SnapshotId extends OrchestratorSnapshotId = OrchestratorSnapshotId,
> {
  build(opts: {
    snapshotId: SnapshotId;
    snapshot: ResolvedSnapshot;
    logger: Logger;
    bus: ExternalEventBus;
  }): TickModules;
}

// ─── Orchestrator storage ─────────────────────────────────────────────────

/**
 * Abstract storage the Orchestrator uses for snapshot resolution,
 * locking, and recovery queries.
 *
 * The concrete impl lives in the host. For api-server this wraps the
 * full `Storage` interface; for a local runner it might be a simple
 * in-memory map.
 */
export interface OrchestratorStorage<
  SnapshotId extends OrchestratorSnapshotId = OrchestratorSnapshotId,
  ProjectId extends OrchestratorProjectId = OrchestratorProjectId,
> {
  /**
   * Run `fn` inside a backend-native transaction. The argument is
   * a transactional view of the same storage.
   */
  withTransaction<T>(
    fn: (tx: OrchestratorStorage<SnapshotId, ProjectId>) => Promise<T>,
  ): Promise<T>;

  /**
   * Acquire a per-snapshot advisory lock within the current transaction.
   * Must be called inside `withTransaction`.
   */
  withSnapshotLock<T>(
    tx: OrchestratorStorage<SnapshotId, ProjectId>,
    snapshotId: SnapshotId,
    fn: () => Promise<T>,
  ): Promise<T>;

  /** Fetch a snapshot by id. Returns null when not found. */
  getSnapshot(id: SnapshotId): Promise<ResolvedSnapshot | null>;

  /** Latest snapshot id for a project. Returns null when none exists. */
  latestSnapshot(projectId: ProjectId): Promise<SnapshotId | null>;

  /** Snapshot ids that still own at least one live delegation. Used for boot recovery. */
  listLiveSnapshotIds(): Promise<SnapshotId[]>;
}
