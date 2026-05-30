// ProjectActor — a warm, per-project actor that owns the project's modules.
//
// One actor per project, held in memory by {@link ProjectActorHost}. It owns:
//   - the 4 warm modules (core / api / env / ffi) for this project
//   - the bus that routes between them
//   - a serial queue that serializes every quantum for this project
//
// The actor is a thin proxy in the spirit of the design's "host": its only job
// is to (1) serialize, (2) let the caller kick off work on a module, and (3)
// drain the bus. It holds NO transaction and NO lock of its own — each module
// opens its own transaction inside `feed` (1 quantum = 1 tx). Serialization is
// the actor's serial queue (= the per-project boundary); the snapshot a piece
// of work runs on is module-private state (CORE shard `currentSnapshot`, FFI
// lane), never the actor's concern.

import { ExternalEventBus } from "../bus.js";
import type { Logger } from "../engine/logger.js";
import type { Module } from "../module.js";
import { SerialQueue } from "./serial-queue.js";

/** The four modules an actor wires onto its bus. `ffi` is optional (a project
 *  whose snapshots declare no ext agents needs no sidecar). The concrete types
 *  are a host concern — the actor only needs the {@link Module} shape, but it
 *  is generic over the bundle so callers see the concrete `api` / `ffi`. */
export type ProjectActorModules = {
  core: Module;
  api: Module;
  env: Module;
  ffi: Module | null;
};

/** Context handed to a `run` callback: the bus to kick work onto, plus the
 *  project's modules (concrete types preserved via the bundle type). */
export type ProjectActorContext<M extends ProjectActorModules> = {
  bus: ExternalEventBus;
  modules: M;
};

export class ProjectActor<M extends ProjectActorModules = ProjectActorModules> {
  readonly bus: ExternalEventBus;
  readonly modules: M;
  private readonly queue = new SerialQueue();

  /**
   * @param buildModules builds the module bundle given the actor's bus — the
   *        bus must exist first because ENV / FFI capture it as their
   *        `onBusResponse` (the route back into the drain for async work).
   */
  constructor(logger: Logger, buildModules: (bus: ExternalEventBus) => M) {
    this.bus = new ExternalEventBus(logger);
    this.modules = buildModules(this.bus);
    const entries = [
      { name: "api", module: this.modules.api },
      { name: "core", module: this.modules.core },
      { name: "env", module: this.modules.env },
    ];
    if (this.modules.ffi !== null) entries.push({ name: "ffi", module: this.modules.ffi });
    this.bus.registerAll(entries);
  }

  /**
   * Run `fn` then drain the bus, serialized against every other quantum for
   * this project. `fn` typically calls a domain method on a module (e.g.
   * `modules.api.startRun`) which pushes the initial event onto the bus.
   */
  run<T>(fn: (ctx: ProjectActorContext<M>) => Promise<T>): Promise<T> {
    return this.queue.run(async () => {
      const result = await fn({ bus: this.bus, modules: this.modules });
      await this.bus.drain();
      return result;
    });
  }
}
