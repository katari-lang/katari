import type { IRModule } from "../ir/types.js";
import { type DelegationId, type ScopeId, type ThreadId } from "./id.js";
import { collectGarbage, type Scope } from "./scope.js";
import type { MachineEvent } from "./events.js";
import { processQueue } from "./runner.js";
import type { QueueEvent, Thread } from "./thread/types.js";
import type { ExternalThread } from "./thread/external.js";
import {
  handleDelegateAckFromFFI,
  handleTerminateAckFromFFI,
} from "./thread/external.js";
import type { APIThread } from "./thread/api.js";
import { handleDelegateFromAPI } from "./thread/api.js";
import { finishCancelling } from "./runner.js";

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
  /** Outbound events produced during current processing. */
  outEvents: MachineEvent[];
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
    outEvents: [],
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
  state.outEvents = [];

  switch (event.kind) {
    case "delegate": {
      if (event.from === "API" && event.to === "CORE") {
        handleDelegateFromAPI(
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
        handleDelegateAckFromFFI(state, event.delegationId, event.value);
      }
      break;
    }

    case "terminate": {
      if (event.from === "API" && event.to === "CORE") {
        const apiThread = state.apiDelegations.get(event.delegationId);
        if (!apiThread || apiThread.status === "cancelling") break;
        apiThread.status = "cancelling";
        if (apiThread.children.size === 0) {
          finishCancelling(state, apiThread);
        } else {
          for (const child of apiThread.children.values()) {
            state.queue.push({ kind: "cancel", target: child });
          }
        }
      }
      break;
    }

    case "terminateAck": {
      if (event.from === "FFI" && event.to === "CORE") {
        handleTerminateAckFromFFI(state, event.delegationId);
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

  return state.outEvents;
}
