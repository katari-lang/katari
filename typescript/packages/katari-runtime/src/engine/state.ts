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
import type { ScopeId, ThreadId } from "./id.js";
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
  /** Scope count at the most recent GC pass. Used by the GC trigger heuristic. */
  lastGcScopeCount: number;
};
