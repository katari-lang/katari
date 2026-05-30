// FfiMux — the per-project FFI module: a thin multiplexer over per-snapshot
// FfiModule "lanes".
//
// A sidecar is fundamentally per-snapshot (each snapshot bundles its own ext
// handler JS), but the project actor is per-project, so the FFI endpoint a
// project exposes must fan an inbound event out to the right snapshot's lane.
// Each lane is an ordinary {@link FfiModule} bound to one snapshot's sidecar +
// store; the mux just decides which lane an event belongs to and creates lanes
// lazily (kept warm thereafter).
//
// Which snapshot owns an event:
//   - `delegate`     → the snapshot stamped on the agent def id (CORE stamped it)
//   - everything else → looked up by delegation / escalation id in the FFI
//     store (FFI-private state: `ffi_pending_*.snapshot_id`)
//
// A run tree is mono-snapshot (the root's snapshot stamps every descendant), so
// a lane's delegations all share its snapshot — the lookup is unambiguous.

import { agentDefIdSnapshot } from "../agent-def-id.js";
import type { ExternalEvent } from "../engine/event.js";
import type { DelegationId, EscalationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import type { Module } from "../module.js";
import type { Sidecar } from "../sidecar/sidecar.js";
import type { FfiStore } from "../sidecar/store.js";
import type { ChildToParent } from "../sidecar/types.js";
import { FFI_ENDPOINT } from "./endpoints.js";
import { FfiModule } from "./ffi.js";

/**
 * Host-provided backing for the mux's lanes. The host knows how to reach a
 * snapshot's sidecar + store and how to resolve an id back to its snapshot.
 */
export interface FfiLaneBackend {
  /**
   * Ensure the sidecar subprocess for `snapshot` is running. Returns `false`
   * when the snapshot declares no sidecar (no ext agents) — the event is then
   * dropped (it shouldn't have been addressed to FFI in the first place).
   */
  ensureSidecar(snapshot: string): Promise<boolean>;
  /** Parent→child handle for `snapshot`'s sidecar (sends route to the manager). */
  sidecar(snapshot: string): Sidecar;
  /** Per-snapshot FFI store (opens its own tx per op). */
  store(snapshot: string): FfiStore;
  /** delegationId → owning snapshot (FFI-private routing for non-delegate events). */
  delegationSnapshot(delegationId: DelegationId): Promise<string | null>;
  /** escalationId → owning snapshot (for escalateAck). */
  escalationSnapshot(escalationId: EscalationId): Promise<string | null>;
}

export class FfiMux implements Module {
  readonly endpoint = FFI_ENDPOINT;
  private readonly lanes = new Map<string, FfiModule>();

  constructor(
    private readonly backend: FfiLaneBackend,
    private readonly onBusResponse: (event: ExternalEvent) => void,
    private readonly logger: Logger,
  ) {}

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    const snapshot = await this.snapshotForEvent(event);
    if (snapshot === null) {
      // A terminate / terminateAck for a delegation the FFI store no longer
      // knows (it completed first) must still close the caller's DelegateThread
      // — ack immediately rather than dropping.
      if (event.payload.kind === "terminate") {
        this.onBusResponse({
          from: this.endpoint,
          to: event.from,
          payload: { kind: "terminateAck", delegationId: event.payload.delegationId },
        });
      } else {
        this.logger.log("debug", "ffi-mux: no snapshot for event, dropping", {
          kind: event.payload.kind,
        });
      }
      return { outbound: [] };
    }
    const lane = await this.lane(snapshot);
    if (lane === null) return { outbound: [] };
    return lane.feed(event);
  }

  /** Route a sidecar message (the manager knows its snapshot key) into the lane. */
  async dispatchSidecarMessage(snapshot: string, msg: ChildToParent): Promise<void> {
    const lane = await this.lane(snapshot);
    if (lane === null) return;
    await lane.dispatchSidecarMessage(msg);
  }

  /** Boot recovery for one snapshot's in-flight ext delegations. */
  async recoverLane(snapshot: string): Promise<void> {
    const lane = await this.lane(snapshot);
    if (lane !== null) await lane.recoverInflight();
  }

  private async snapshotForEvent(event: ExternalEvent): Promise<string | null> {
    const p = event.payload;
    switch (p.kind) {
      case "delegate":
        return agentDefIdSnapshot(p.agentDefId) ?? null;
      case "delegateAck":
      case "terminate":
      case "terminateAck":
      case "escalate":
        return this.backend.delegationSnapshot(p.delegationId);
      case "escalateAck":
        return this.backend.escalationSnapshot(p.escalationId);
      default:
        return null;
    }
  }

  private async lane(snapshot: string): Promise<FfiModule | null> {
    const cached = this.lanes.get(snapshot);
    if (cached !== undefined) return cached;
    const started = await this.backend.ensureSidecar(snapshot);
    if (!started) {
      this.logger.log("debug", "ffi-mux: snapshot has no sidecar, dropping", { snapshot });
      return null;
    }
    const lane = new FfiModule({
      endpoint: FFI_ENDPOINT,
      snapshotId: snapshot,
      sidecar: this.backend.sidecar(snapshot),
      store: this.backend.store(snapshot),
      logger: this.logger,
      onSidecarResponse: this.onBusResponse,
    });
    // Rebuild the lane's in-memory escalation relay map from its store.
    await lane.load();
    this.lanes.set(snapshot, lane);
    return lane;
  }
}
