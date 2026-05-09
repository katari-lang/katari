// State: the full machine state. Plain data; updated immutably via Immer.
//
// Notable departures from the previous `MachineState`:
//   - No `pendingOutEvents` — outbound events go on the Result, not the state.
//   - No `delegations` / `apiDelegations` — delegation routing is the host's
//     job (DelegationRouter). The engine only knows ThreadIds.
//   - No `logger` field — Logger is supplied via Effect Context to applyEvent.
//   - No `queue` of internal events — the runner drives a fresh queue in each
//     applyEvent call (the queue is transient and doesn't survive snapshots).
//
// `lastGcScopeCount` is kept so the GC trigger heuristic survives across
// applyEvent calls (otherwise GC would fire every event for small machines).

import type { IRModule } from "../ir/types.js";
import type { Endpoint } from "./endpoint.js";
import type { Scope } from "./scope.js";
import type { Thread } from "./thread/types.js";

export type State = {
  /** Identity of this engine instance. Events with `to !== selfEndpoint` are outbound. */
  selfEndpoint: Endpoint;
  irModule: IRModule;
  /** ThreadId → Thread. Encoded as Record<string, Thread> for Immer ergonomics. */
  threads: Record<string, Thread>;
  /** ScopeId → Scope. Encoded as Record<string, Scope>. */
  scopes: Record<string, Scope>;
  /**
   * API delegationId → root thread id.
   * When an external `delegate API→CORE` arrives the engine spawns a root
   * UserThread and registers it here. When that thread completes (or is
   * cancelled) the engine emits `delegateAck` / `terminateAck` to the
   * stored sender and clears the entry.
   */
  apiDelegations: Record<string, string>;
  /**
   * Sender endpoint per API delegation, recorded so the engine knows
   * where to address `delegateAck` / `terminateAck` back to.
   */
  apiDelegationSenders: Record<string, Endpoint>;
  /**
   * FFI delegationId → ExternalThread id.
   * Set by spawnChild when an ExternalThread is created. Used to look up
   * the target of inbound `delegateAck` / `terminateAck` from FFI.
   */
  ffiDelegations: Record<string, string>;
  /** Endpoint to send CORE→FFI delegate / terminate to. Set per delegation? */
  ffiTargetEndpoint: Endpoint;
  /** Scope count at the most recent GC pass. Used by the GC trigger heuristic. */
  lastGcScopeCount: number;
};
