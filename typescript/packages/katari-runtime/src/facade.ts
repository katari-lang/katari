// MachineHandle: an owner ref over a State + applyEvent. The host's
// favourite API surface — keeps the State pointer fresh on every event
// without requiring callers to thread it manually.
//
// Use the static constructors `create` / `fromSnapshot` to obtain a
// handle, then call `feedEvent` to drive it. `toSnapshot` returns the
// current state in a JSON-serializable form.

import type { IRModule, QualifiedName } from "./ir/types.js";
import { applyEvent, createState } from "./engine/apply.js";
import { CORE_ENDPOINT, endpoint, type Endpoint } from "./engine/endpoint.js";
import type { DelegationId } from "./engine/id.js";
import type { Event } from "./engine/event.js";
import type { Result } from "./engine/result.js";
import type { State } from "./engine/state.js";
import {
  deserialize as deserializeSnapshot,
  serialize as serializeSnapshot,
  type Snapshot,
} from "./engine/snapshot.js";
import type { Value } from "./engine/value.js";

/** Conventional sender endpoint for events injected via `startAgent`. */
const API_ENDPOINT: Endpoint = endpoint("api://default");

export class MachineHandle {
  private state: State;

  private constructor(state: State) {
    this.state = state;
  }

  static create(
    irModule: IRModule,
    options: { selfEndpoint?: Endpoint } = {},
  ): MachineHandle {
    return new MachineHandle(createState(irModule, options));
  }

  static fromSnapshot(irModule: IRModule, snapshot: Snapshot): MachineHandle {
    return new MachineHandle(deserializeSnapshot(irModule, snapshot));
  }

  /**
   * Feed an event through `applyEvent`. Returns the side-effect bag
   * (outbound events / errors / logs / diffs); the new state is held
   * internally on the handle for the next call.
   *
   * If any error in `result.errors` is "irrecoverable" (anything that's
   * not a `RecoverableEngineError`), this method throws the first such
   * error so callers can branch on the host's poison vs rollback paths.
   * Recoverable errors are returned in the result; the host decides
   * whether to flip a single agent to error.
   */
  feedEvent(event: Event): Omit<Result, "state"> {
    const result = applyEvent(this.state, event);
    this.state = result.state;
    // Surface the first non-Recoverable error as a throw; the host
    // expects this to drive the poison path.
    for (const err of result.errors) {
      if (err.name !== "RecoverableEngineError" && err.name !== "EntryNotFoundError") {
        throw err;
      }
    }
    return {
      outbound: result.outbound,
      errors: result.errors,
      logs: result.logs,
      diffs: result.diffs,
    };
  }

  /**
   * Convenience: start a new agent by qualifiedName.
   *
   * Wraps `feedEvent` with an external `delegate` event. `sender`
   * controls the endpoint the engine addresses the eventual
   * `delegateAck` / `terminateAck` back to (defaults to `api://default`,
   * which the host can match on when forwarding).
   *
   * Throws `EntryNotFoundError` (Recoverable, also returned in
   * `result.errors`) when the qualifiedName isn't in the IR.
   */
  startAgent(
    qualifiedName: string,
    args: Record<string, Value>,
    delegationId: DelegationId,
    sender: Endpoint = API_ENDPOINT,
  ): Omit<Result, "state"> {
    const targetBlock = parseQualifiedName(qualifiedName);
    return this.feedEvent({
      from: sender,
      to: this.state.selfEndpoint,
      payload: { kind: "delegate", targetBlock, args, delegationId },
    });
  }

  /**
   * Convenience: terminate a previously-started agent.
   * Idempotent — terminating an unknown delegationId is a no-op.
   */
  cancelAgent(
    delegationId: DelegationId,
    sender: Endpoint = API_ENDPOINT,
  ): Omit<Result, "state"> {
    return this.feedEvent({
      from: sender,
      to: this.state.selfEndpoint,
      payload: { kind: "terminate", delegationId },
    });
  }

  /** Pure JSON snapshot of the current state. */
  toSnapshot(): Snapshot {
    return serializeSnapshot(this.state);
  }

  /**
   * Read-only access to the underlying state. Test/diagnostic use only —
   * mutations made through this reference will be lost on the next
   * `feedEvent` call (Immer treats incoming state as immutable).
   */
  get currentState(): Readonly<State> {
    return this.state;
  }
}

/** Parse a `module.name` (or bare `name`) string into a QualifiedName object. */
function parseQualifiedName(s: string): QualifiedName {
  const idx = s.lastIndexOf(".");
  if (idx === -1) return { module_: "", name: s };
  return { module_: s.substring(0, idx), name: s.substring(idx + 1) };
}

// Avoid unused-import diagnostics for symbols only referenced through
// the type system above.
void CORE_ENDPOINT;

