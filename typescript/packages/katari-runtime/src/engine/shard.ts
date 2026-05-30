// Per-agent sharding: EngineShard storage model + project routing index.
//
// Phase E splits the flat per-snapshot `State` (which holds ALL agents of a
// snapshot) into per-agent-instance shards + a lightweight project-local index
// (docs/2026-05-30-phase-e-actor-host.md §2). A shard IS a `State` scoped to
// one agent instance; the engine's `applyEvent` runs unchanged on it. All
// cross-shard routing reduces to an index lookup (verified against the engine's
// escalate path): an inbound escalate / ack returns to the shard that ISSUED
// the corresponding delegate / escalate.
//
//   delegate      → new shard (shardId = the new delegation id)
//   delegateAck   → index.pendingDelegateOut[delegationId]
//   terminate     → index.delegations[delegationId]
//   terminateAck  → index.pendingDelegateOut[delegationId]
//   escalate      → index.pendingDelegateOut[delegationId]   (delegate issuer)
//   escalateAck   → index.escalationOwners[escalationId]
//
// A shard persists as an `EncryptedEngineCheckpoint` (its State) under
// (projectId, shardId) — the existing checkpoint codec is reused verbatim, so
// there is no separate shard serialization. The index has no secrets and
// persists as plain JSON.

import type { DelegationId, EscalationId } from "./id.js";
import type { EncryptedEngineCheckpoint } from "./snapshot.js";

/** = top-level (root) delegation id = agent instance id. */
export type ShardId = string;

/** Lifecycle of a shard. `completed` shards are deleted (no replay → no retention). */
export type ShardStatus = "active" | "terminating" | "completed";

/**
 * Project-local routing index. Always loaded (lightweight); shard bodies load
 * on demand. Maps an id to the shard that must be loaded to handle an event.
 * Each id is owned by exactly one shard.
 */
export type ProjectIndex = {
  /** Inbound-delegate receiver: delegationId → the shard the delegate created. */
  delegations: Record<DelegationId, ShardId>;
  /** Delegate issuer: delegationId → issuing shard (delegateAck / terminateAck / escalate). */
  pendingDelegateOut: Record<DelegationId, ShardId>;
  /** Escalate issuer: escalationId → issuing shard (escalateAck). */
  escalationOwners: Record<EscalationId, ShardId>;
};

export function emptyProjectIndex(): ProjectIndex {
  return { delegations: {}, pendingDelegateOut: {}, escalationOwners: {} };
}

/** Active shard metadata (without loading its body) — recovery / listing. */
export type ActiveShard = { shardId: ShardId; currentSnapshot: string };

/**
 * Per-shard checkpoint store. Replaces `CoreCheckpointStore` (one flat
 * checkpoint per snapshot). The exchanged payload is the **encrypted** shard
 * state; storage never sees plaintext secrets. Keyed by (projectId, shardId).
 */
/** A loaded shard: its encrypted state + which code version it runs. */
export type LoadedShard = { checkpoint: EncryptedEngineCheckpoint; currentSnapshot: string };

export interface ShardStore {
  get(projectId: string, shardId: ShardId): Promise<LoadedShard | null>;
  upsert(input: {
    projectId: string;
    shardId: ShardId;
    currentSnapshot: string;
    status: ShardStatus;
    checkpoint: EncryptedEngineCheckpoint;
  }): Promise<void>;
  /** Drop a completed shard. */
  delete(projectId: string, shardId: ShardId): Promise<void>;
  /** Active shards in a project (bodies not loaded). */
  listActive(projectId: string): Promise<ActiveShard[]>;
}

/** Project-local index store. One row per project. */
export interface ProjectIndexStore {
  get(projectId: string): Promise<ProjectIndex | null>;
  upsert(projectId: string, index: ProjectIndex): Promise<void>;
}
