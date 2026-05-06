// Thin wrapper around `MachineState` + `applyEvent` exposing only the API
// surface needed by `katari-api-server`. The point is to give the I/O layer
// a stable handle while the engine's internals (Thread classes, queue
// representation, ...) keep evolving.

import type { IRModule } from "../ir/types.js";
import type { DelegationId } from "../machine/id.js";
import {
  applyEvent,
  createMachine,
  type MachineState,
} from "../machine/machine.js";
import type { MachineEvent } from "../machine/events.js";
import type { Value } from "../machine/value.js";
import { type Logger } from "./logger.js";
import {
  deserializeMachine,
  serializeMachine,
  type MachineSnapshot,
} from "./snapshot.js";

export class MachineHandle {
  private constructor(
    private readonly state: MachineState,
    private readonly logger: Logger,
  ) {}

  /** Build a fresh handle from an IR module. */
  static create(irModule: IRModule, logger: Logger): MachineHandle {
    return new MachineHandle(createMachine(irModule), logger);
  }

  /**
   * Restore a handle from a previously emitted snapshot. Throws if the
   * snapshot was produced against a different IR module shape that the
   * engine cannot interpret (callers are expected to feed the same
   * `irModule` they uploaded with the version).
   */
  static fromSnapshot(
    irModule: IRModule,
    snap: MachineSnapshot,
    logger: Logger,
  ): MachineHandle {
    return new MachineHandle(deserializeMachine(irModule, snap), logger);
  }

  /**
   * Inject a `delegate API → CORE` event for a new agent and return the
   * outbound events the runtime emitted in response (typically a
   * `delegateAck` if the agent completed synchronously, or a `delegate
   * CORE → FFI` if it suspended on an external call).
   *
   * Exceptions thrown by `applyEvent` propagate to the caller; the
   * caller is responsible for marking the agent as `error` and treating
   * the underlying machine as poisoned (state is mutated in-place).
   */
  startAgent(
    qualifiedName: string,
    args: Record<string, Value>,
    delegationId: DelegationId,
  ): MachineEvent[] {
    this.logger.log("debug", "startAgent", { qualifiedName, delegationId });
    return applyEvent(this.state, {
      from: "API",
      to: "CORE",
      kind: "delegate",
      qualifiedName,
      args,
      delegationId,
    });
  }

  /**
   * Inject a `terminate API → CORE` event for the given delegation.
   * Idempotent at the runtime level — terminating an unknown
   * delegationId is a no-op.
   */
  cancelAgent(delegationId: DelegationId): MachineEvent[] {
    this.logger.log("debug", "cancelAgent", { delegationId });
    return applyEvent(this.state, {
      from: "API",
      to: "CORE",
      kind: "terminate",
      delegationId,
    });
  }

  /**
   * Forward an arbitrary already-formed event (e.g. a `delegateAck FFI →
   * CORE` once the future FFI executor lands). Symmetric escape hatch for
   * subsystems we have not yet built.
   */
  feedEvent(event: MachineEvent): MachineEvent[] {
    this.logger.log("debug", "feedEvent", { kind: event.kind, from: event.from, to: event.to });
    return applyEvent(this.state, event);
  }

  /** Pure JSON snapshot of the current state. */
  toSnapshot(): MachineSnapshot {
    return serializeMachine(this.state);
  }
}
