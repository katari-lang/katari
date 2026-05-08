// PoisonHandler.
//
// Extracted from AgentService — handles the "engine threw an
// irrecoverable; entire version is suspect" path:
//   1. Mark the triggering agent as `error` (insert if not yet
//      persisted, otherwise update).
//   2. Bulk-mark every running/cancelling sibling on the same version
//      as `error`.
//   3. Drop the snapshot on disk (so the next acquire reloads cleanly).
//   4. Evict the registry cache.
//
// Each step is best-effort and idempotent so a partial failure here
// doesn't make things much worse than they already are.

import { type Logger } from "katari-runtime";
import { MachineNotFound } from "../registry.js";
import type { MachineRegistry } from "../registry.js";
import type { AgentId, AgentRow, Storage, VersionId } from "../storage/types.js";

export class PoisonHandler {
  constructor(
    private readonly storage: Storage,
    private readonly registry: MachineRegistry,
    private readonly logger: Logger,
  ) {}

  async poison(
    versionId: VersionId,
    triggeringAgentId: AgentId,
    triggeringRow: AgentRow,
    err: unknown,
  ): Promise<void> {
    const message = errorMessage(err);
    this.logger.log("error", "applyEvent threw — poisoning version", {
      versionId,
      triggeringAgentId,
      error: message,
    });
    try {
      // The triggering agent may not be persisted yet (startAgent path
      // inserts inside the rolled-back tx). Insert-or-update via insert
      // first, swallowing any duplicate-key error.
      await this.storage.agents.insert({
        ...triggeringRow,
        state: "error",
        errorMessage: message,
        updatedAt: new Date().toISOString(),
      });
    } catch {
      await this.storage.agents.setState(triggeringAgentId, {
        state: "error",
        errorMessage: message,
      });
    }
    await this.storage.agents.markAllRunningAsError(
      versionId,
      "machine poisoned by sibling failure",
    );
    await this.storage.snapshots.delete(versionId);
    this.registry.evict(versionId);
  }
}

function errorMessage(err: unknown): string {
  if (err instanceof MachineNotFound) return err.message;
  if (err instanceof Error) return err.message;
  return String(err);
}
