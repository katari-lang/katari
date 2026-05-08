// MachineHandle: an owner ref over a State + applyEvent. The host's
// favourite API surface — keeps the State pointer fresh on every event
// without requiring callers to thread it manually.
//
// Use the static constructors `create` / `fromSnapshot` to obtain a
// handle, then call `feedEvent` to drive it. `toSnapshot` returns the
// current state in a JSON-serializable form.

import type { IRModule } from "./ir/types.js";
import { applyEvent, createState } from "./engine/apply.js";
import type { Endpoint } from "./engine/endpoint.js";
import type { Event } from "./engine/event.js";
import type { Result } from "./engine/result.js";
import type { State } from "./engine/state.js";
import {
  deserialize as deserializeSnapshot,
  serialize as serializeSnapshot,
  type Snapshot,
} from "./engine/snapshot.js";

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
   */
  feedEvent(event: Event): Omit<Result, "state"> {
    const result = applyEvent(this.state, event);
    this.state = result.state;
    return {
      outbound: result.outbound,
      errors: result.errors,
      logs: result.logs,
      diffs: result.diffs,
    };
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
