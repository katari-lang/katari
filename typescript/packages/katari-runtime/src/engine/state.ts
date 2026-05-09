// State: the full machine state. Plain data; updated immutably via Immer.
//
// Design notes:
//   - `pendingOutEvents` is not on State — outbound events go on the Result.
//   - `delegations` / `delegationSenders` are unified: the engine doesn't
//     distinguish API / FFI senders. Each delegationId maps to a single
//     thread (AgentThread inbound or ExternalThread outbound) and to the
//     endpoint we owe a reply to.
//   - Logger is not on State — it is supplied via Effect Context to applyEvent.
//   - Internal event queue is transient: the runner builds one per
//     applyEvent call, it does not survive snapshots.
//
// `lastGcScopeCount` is kept so the GC trigger heuristic survives across
// applyEvent calls (otherwise GC would fire every event for small machines).

import type { IRModule } from "../ir/types.js";
import type { ClosureRecord } from "./closure.js";
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
   * ClosureId → ClosureRecord. Allocated by `statementMakeClosure`.
   * Reachability traced through `Value { kind: "closure", closureId }` in
   * scope values; collected by GC when no live Value references the id.
   */
  closures: Record<number, ClosureRecord>;
  /** Per-machine ClosureId allocator. Increments every makeClosure. */
  nextClosureId: number;
  /**
   * Receiver-side: delegationId → AgentThread root id.
   *
   * Set when an inbound `delegate` lands: translateExternal spawns an
   * AgentThread for the entry block and registers it here. Cleared by
   * `emitAgentRootCompletion` when the agent completes.
   *
   * Used by inbound `terminate` / `escalate` to find the receiver thread.
   */
  delegations: Record<string, string>;
  /**
   * Sender-side: delegationId → ExternalThread id.
   *
   * Set when we issue an outbound `delegate`:
   *   - real external (FFI): registered by `externalOps.create`
   *   - core→core agent call: registered by `spawnExternalForAgentDelegate`
   *
   * Used by inbound `delegateAck` / `terminateAck` to find the sender
   * thread so we can deliver the ack to its parent. The receiver-side
   * `delegations` map and this map can both hold the same delegationId
   * simultaneously when the delegate is self→self (core→core agent call).
   */
  pendingDelegateOut: Record<string, string>;
  /**
   * delegationId → sender Endpoint. Recorded for the receiver side so the
   * engine knows where to address `delegateAck` / `terminateAck` back when
   * the corresponding AgentThread completes. For self→self delegates the
   * value is `selfEndpoint`, and the loop-back is picked up by
   * translateExternal on the next iteration.
   */
  delegationSenders: Record<string, Endpoint>;
  /** Endpoint to send CORE→FFI delegate / terminate to. */
  ffiTargetEndpoint: Endpoint;
  /** Scope count at the most recent GC pass. Used by the GC trigger heuristic. */
  lastGcScopeCount: number;
};
