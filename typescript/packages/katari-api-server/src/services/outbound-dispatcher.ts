// OutboundEventDispatcher.
//
// Extracted from AgentService — translates the engine's outbound event
// stream into DB writes (and, in the future, FFI invocations).
//
// Currently handles:
//   - delegateAck CORE→API → setState(succeeded, result=value)
//   - terminateAck CORE→API → setState(cancelled)
//   - any CORE→FFI event → log only (FFI executor lands in Phase F)
//
// Operates inside the caller's Storage transaction so the DB writes are
// atomic with the snapshot upsert that surrounds them.

import type { Logger, MachineEvent } from "katari-runtime";
import type { Storage, VersionId } from "../storage/types.js";

export class OutboundEventDispatcher {
  constructor(private readonly logger: Logger) {}

  async route(
    events: MachineEvent[],
    versionId: VersionId,
    tx: Storage,
  ): Promise<void> {
    for (const event of events) {
      if (event.kind === "delegateAck" && event.from === "CORE" && event.to === "API") {
        const row = await tx.agents.findByDelegationId(event.delegationId);
        if (row === null) {
          this.logger.log("warn", "delegateAck for unknown delegationId", {
            versionId,
            delegationId: event.delegationId,
          });
          continue;
        }
        const updated = await tx.agents.setState(
          row.id,
          { state: "succeeded", result: event.value },
          { expectedState: "running" },
        );
        if (!updated) {
          this.logger.log("info", "delegateAck dropped: agent no longer running", {
            versionId,
            agentId: row.id,
            wasState: row.state,
          });
        }
      } else if (
        event.kind === "terminateAck" &&
        event.from === "CORE" &&
        event.to === "API"
      ) {
        const row = await tx.agents.findByDelegationId(event.delegationId);
        if (row === null) {
          this.logger.log("warn", "terminateAck for unknown delegationId", {
            versionId,
            delegationId: event.delegationId,
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
      } else if (event.to === "FFI") {
        // FFI executor not yet wired (Phase F). Hold the event — the
        // ExternalThread is still in `delegations`, waiting for an
        // ack the host must inject once the executor lands.
        this.logger.log("debug", "FFI event held pending executor", {
          versionId,
          eventKind: event.kind,
        });
      } else {
        this.logger.log("debug", "ignoring outbound event", {
          eventKind: event.kind,
          from: event.from,
          to: event.to,
        });
      }
    }
  }
}
