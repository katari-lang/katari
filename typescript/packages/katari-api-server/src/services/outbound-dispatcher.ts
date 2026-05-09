// OutboundEventDispatcher.
//
// Translates the engine's outbound `Event` stream into DB writes (and,
// in Phase F, FFI invocations).
//
// Currently handles:
//   - delegateAck CORE→API → setState(succeeded, result=value)
//   - terminateAck CORE→API → setState(cancelled)
//   - any CORE→FFI event → log only (FFI executor lands in Phase F)
//
// Operates inside the caller's Storage transaction so the DB writes are
// atomic with the snapshot upsert that surrounds them.

import type { EngineEvent, Logger } from "katari-runtime";
import type { Storage, VersionId } from "../storage/types.js";

export class OutboundEventDispatcher {
  constructor(private readonly logger: Logger) {}

  async route(
    events: EngineEvent[],
    versionId: VersionId,
    tx: Storage,
  ): Promise<void> {
    for (const event of events) {
      const p = event.payload;
      if (p.kind === "delegateAck" && event.from.startsWith("core:")) {
        const row = await tx.agents.findByDelegationId(p.delegationId);
        if (row === null) {
          this.logger.log("warn", "delegateAck for unknown delegationId", {
            versionId,
            delegationId: p.delegationId,
          });
          continue;
        }
        const updated = await tx.agents.setState(
          row.id,
          { state: "succeeded", result: p.value },
          { expectedState: "running" },
        );
        if (!updated) {
          this.logger.log("info", "delegateAck dropped: agent no longer running", {
            versionId,
            agentId: row.id,
            wasState: row.state,
          });
        }
      } else if (p.kind === "terminateAck" && event.from.startsWith("core:")) {
        const row = await tx.agents.findByDelegationId(p.delegationId);
        if (row === null) {
          this.logger.log("warn", "terminateAck for unknown delegationId", {
            versionId,
            delegationId: p.delegationId,
          });
          continue;
        }
        const updated = await tx.agents.setState(
          row.id,
          { state: "cancelled" },
          { expectedState: "cancelling" },
        );
        if (!updated) {
          this.logger.log("info", "terminateAck dropped: agent not in cancelling state", {
            versionId,
            agentId: row.id,
            wasState: row.state,
          });
        }
      } else if (event.to.startsWith("ext:")) {
        // Phase F wires this to the FFI executor.
        this.logger.log("debug", "FFI event held pending executor", {
          versionId,
          eventKind: p.kind,
        });
      } else {
        this.logger.log("debug", "ignoring outbound event", {
          eventKind: p.kind,
          from: event.from,
          to: event.to,
        });
      }
    }
  }
}
