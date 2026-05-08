// MachineRebuilder.
//
// Extracted from AgentService — handles the "engine state got mutated
// before a throw, restore from pre-call snapshot" path. The caller must
// hold the version's mutex around `rollback`.

import { MachineHandle, type Logger } from "katari-runtime";
import type { MachineRegistry } from "../registry.js";
import type { Storage, VersionId } from "../storage/types.js";

export class MachineRebuilder {
  constructor(
    private readonly storage: Storage,
    private readonly registry: MachineRegistry,
    private readonly logger: Logger,
  ) {}

  /**
   * Rebuild the in-memory machine from `snap` and place it in the registry
   * cache, replacing any handle that was there. Awaits the rebuild — the
   * previous fire-and-forget version released the mutex before completion,
   * letting concurrent acquires hit the still-poisoned handle (BUG-02).
   */
  async rollback(
    versionId: VersionId,
    snap: ReturnType<MachineHandle["toSnapshot"]>,
  ): Promise<void> {
    try {
      const moduleRow = await this.storage.modules.get(versionId);
      if (moduleRow === null) {
        this.registry.evict(versionId);
        return;
      }
      const fresh = MachineHandle.fromSnapshot(moduleRow.irModule, snap, this.logger);
      this.registry.replaceHandle(versionId, fresh);
    } catch (err) {
      this.logger.log("error", "rollback rebuild failed", {
        versionId,
        error: err instanceof Error ? err.message : String(err),
      });
      this.registry.evict(versionId);
    }
  }
}
