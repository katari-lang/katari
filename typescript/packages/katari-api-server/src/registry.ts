// In-memory registry of `MachineHandle`s, keyed by version. The runtime
// engine itself is single-version-per-machine; the registry is what makes
// "many concurrent versions running" possible at the api layer.
//
// Each version's machine is loaded lazily on first acquire and kept around
// while at least one agent on it remains alive. After a poison event the
// machine is evicted; the next acquire builds a fresh one (snapshot row is
// expected to have been deleted by the caller).

import { MachineHandle, type Logger } from "katari-runtime";
import type { Storage, VersionId } from "./storage/types.js";

export class MachineNotFound extends Error {
  constructor(public readonly versionId: VersionId) {
    super(`module version ${versionId} does not exist`);
  }
}

export class MachineRegistry {
  private readonly machines = new Map<VersionId, MachineHandle>();

  constructor(
    private readonly storage: Storage,
    private readonly logger: Logger,
  ) {}

  /**
   * Return the live `MachineHandle` for `versionId`, loading it from
   * storage on the first call. Throws `MachineNotFound` if the version
   * does not exist.
   */
  async acquire(versionId: VersionId): Promise<MachineHandle> {
    const cached = this.machines.get(versionId);
    if (cached !== undefined) return cached;

    const moduleRow = await this.storage.modules.get(versionId);
    if (moduleRow === null) throw new MachineNotFound(versionId);

    const snap = await this.storage.snapshots.get(versionId);
    const handle =
      snap !== null
        ? MachineHandle.fromSnapshot(moduleRow.irModule, snap, this.logger)
        : MachineHandle.create(moduleRow.irModule, this.logger);
    this.machines.set(versionId, handle);
    this.logger.log("info", "machine loaded", {
      versionId,
      fromSnapshot: snap !== null,
    });
    return handle;
  }

  /**
   * Drop the in-memory machine for `versionId`. Used after a poison event
   * or when the api server wants to free memory; the next `acquire` will
   * re-load (or rebuild) it.
   */
  evict(versionId: VersionId): void {
    if (this.machines.delete(versionId)) {
      this.logger.log("info", "machine evicted", { versionId });
    }
  }

  /** For tests / debugging. */
  isLoaded(versionId: VersionId): boolean {
    return this.machines.has(versionId);
  }
}
