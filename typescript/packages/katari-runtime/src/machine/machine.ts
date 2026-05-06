import type { IRModule } from "../ir/types.js";
import { type DelegationId, type ScopeId, type ThreadId } from "./id.js";
import { collectGarbage, type Scope } from "./scope.js";
import type { MachineEvent } from "./events.js";
import { processQueue } from "./runner.js";
import type { QueueEvent, Thread } from "./thread/types.js";
import { ExternalThread } from "./thread/external.js";
import { APIThread } from "./thread/api.js";

// ─── MachineState ───────────────────────────────────────────────────────────

/**
 * Complete machine state.
 * Mutated in-place during event processing.
 */
export type MachineState = {
  irModule: IRModule;
  /** All live threads (for GC root scanning). */
  threads: Map<ThreadId, Thread>;
  /** Scope storage (GC sweep target). */
  scopes: Map<ScopeId, Scope>;
  /** FFI delegation routing (ExternalThread registers here). */
  delegations: Map<DelegationId, ExternalThread>;
  /** API delegation routing (APIThread registers here). */
  apiDelegations: Map<DelegationId, APIThread>;
  /**
   * Outbound events produced during the current `applyEvent` invocation.
   *
   * Transient buffer: cleared at the start of every `applyEvent` and
   * returned at the end. Thread modules push directly into it during
   * `processQueue`. Not part of the persistent machine state — it is
   * stored on `MachineState` only because thread code needs a stable
   * place to write to without threading a context object through every
   * call site.
   */
  pendingOutEvents: MachineEvent[];
  /** Event queue for the main loop. */
  queue: QueueEvent[];
};

// ─── Initialization ─────────────────────────────────────────────────────────

/**
 * Create a fresh machine state from an IR module.
 */
export function createMachine(irModule: IRModule): MachineState {
  return {
    irModule,
    threads: new Map(),
    scopes: new Map(),
    delegations: new Map(),
    apiDelegations: new Map(),
    pendingOutEvents: [],
    queue: [],
  };
}

// ─── Event Processing ───────────────────────────────────────────────────────

/**
 * Process an inbound event and return outbound events.
 */
export function applyEvent(
  state: MachineState,
  event: MachineEvent,
): MachineEvent[] {
  state.pendingOutEvents = [];

  switch (event.kind) {
    case "delegate": {
      if (event.from === "API" && event.to === "CORE") {
        APIThread.handleDelegateFromAPI(
          state,
          event.qualifiedName,
          event.args,
          event.delegationId,
        );
      }
      break;
    }

    case "delegateAck": {
      if (event.from === "FFI" && event.to === "CORE") {
        ExternalThread.handleDelegateAckFromFFI(state, event.delegationId, event.value);
      }
      break;
    }

    case "terminate": {
      if (event.from === "API" && event.to === "CORE") {
        APIThread.handleTerminateFromAPI(state, event.delegationId);
      }
      break;
    }

    case "terminateAck": {
      if (event.from === "FFI" && event.to === "CORE") {
        ExternalThread.handleTerminateAckFromFFI(state, event.delegationId);
      }
      break;
    }

    case "escalate":
    case "escalateAck":
      // Placeholders — not implemented
      break;
  }

  // Process all queued events
  processQueue(state);

  // Run GC after processing
  collectGarbage(state);

  return state.pendingOutEvents;
}
