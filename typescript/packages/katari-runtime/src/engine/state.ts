// State: the full machine state. Plain data; updated immutably via Immer.
//
// Design notes:
//   - `pendingOutEvents` is not on State — outbound events go on the Result.
//   - `delegations` / `delegationSenders` are unified: the engine doesn't
//     distinguish API / FFI senders. Each delegationId maps to a single
//     thread (AgentThread inbound or DelegateThread outbound) and to the
//     endpoint we owe a reply to.
//   - Logger is not on State — it is passed to `applyEvent` separately
//     and is therefore not persisted across snapshots.
//   - Internal event queue is transient: the runner builds one per
//     applyEvent call, it does not survive snapshots.
//
// `lastGcScopeCount` is kept so the GC trigger heuristic survives across
// applyEvent calls (otherwise GC would fire every event for small machines).

import type { IRModule } from "../ir/types.js";
import type { ClosureRecord } from "./closure.js";
import type { Endpoint } from "./endpoint.js";
import type { ClosureId, DelegationId, EscalationId, ScopeId, ThreadId } from "./id.js";
import type { Scope } from "./scope.js";
import type { Thread } from "./thread/types.js";

export type State = {
  /** Identity of this engine instance. Events with `to !== selfEndpoint` are outbound. */
  selfEndpoint: Endpoint;
  irModule: IRModule;
  /**
   * The snapshot (code version) this shard runs. Set by the host when the
   * shard is created / loaded. Stamped into a closure blob at make-closure so
   * the closure can later be materialized against the right IR (the block it
   * runs lives in this snapshot's IR). Not persisted in the checkpoint — the
   * host re-supplies it from `engine_shards.current_snapshot` on load.
   */
  snapshot: string;
  /** ThreadId → Thread. */
  threads: Record<ThreadId, Thread>;
  /** ScopeId → Scope. */
  scopes: Record<ScopeId, Scope>;
  /**
   * ClosureId → ClosureRecord. Allocated by `statementMakeClosure`.
   * Reachability traced through `Value { kind: "closure", closureId }` in
   * scope values; collected by GC when no live Value references the id.
   */
  closures: Record<ClosureId, ClosureRecord>;
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
  delegations: Record<DelegationId, ThreadId>;
  /**
   * Sender-side: delegationId → DelegateThread id.
   *
   * Set by `delegateOps.create` when we issue an outbound `delegate`
   * (CORE→CORE loopback, CORE→FFI, or via a runtime value target).
   *
   * Used by inbound `delegateAck` / `terminateAck` to find the sender
   * thread so we can deliver the ack to its parent. The receiver-side
   * `delegations` map and this map can both hold the same delegationId
   * simultaneously when the delegate is self→self (core→core agent call).
   */
  pendingDelegateOut: Record<DelegationId, ThreadId>;
  /**
   * delegationId → sender Endpoint. Recorded for the receiver side so the
   * engine knows where to address `delegateAck` / `terminateAck` back when
   * the corresponding AgentThread completes. For self→self delegates the
   * value is `selfEndpoint`, and the loop-back is picked up by
   * translateExternal on the next iteration.
   */
  delegationSenders: Record<DelegationId, Endpoint>;
  /**
   * EscalationId → owning AgentThread id. Index into the same data the
   * per-thread `outboundEscalations` map carries, kept here so the
   * inbound `escalateAck` routing is O(1) instead of O(threads). Owners
   * are always the AgentThread root that issued the outbound escalate
   * via `emitEscalateUpward`. Populated/cleared alongside writes to
   * `AgentThread.outboundEscalations`.
   *
   * On load, the engine rebuilds this index from existing threads if it
   * is absent (= older checkpoint that pre-dates the field), so checkpoints
   * persisted before this version remain loadable.
   */
  escalationOwners: Record<EscalationId, ThreadId>;
  /** Endpoint to send CORE→FFI delegate / terminate to. */
  ffiTargetEndpoint: Endpoint;
  /** Endpoint to send CORE→ENV delegate to (= EnvModule, host-provided). */
  envTargetEndpoint: Endpoint;
  /** Scope count at the most recent GC pass. Used by the GC trigger heuristic. */
  lastGcScopeCount: number;
  /** Tracked counter for `Object.keys(scopes).length`. Maintained by spawn / GC. */
  scopeCount: number;
  /** Tracked counter for `Object.keys(threads).length`. Maintained by spawn / deleteThread. */
  threadCount: number;
};
