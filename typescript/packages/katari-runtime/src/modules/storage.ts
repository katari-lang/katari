// Per-module transactional storage providers.
//
// A self-contained module opens its OWN transaction (1 quantum = 1 tx) rather
// than running inside a host-owned tick tx. These provider interfaces are the
// runtime → host hand-off: the host implements `withTransaction` over its
// concrete backend (Postgres / in-memory) and hands the module a tx-scoped
// bundle of the stores it needs. The module never sees the host's `Storage`
// facade, so the runtime stays backend-agnostic.

import type { ProjectIndexStore, ShardStore } from "../engine/shard.js";
import type { ScopeStore } from "../storage/scope-store.js";
import type { ValueStore } from "../storage/value-store.js";
import type { EntityStore } from "./entity-store.js";

// ─── CORE ──────────────────────────────────────────────────────────────────

/** Tx-scoped stores CoreModule touches in one quantum. */
export interface CoreTxStores {
  /** Per-agent shard checkpoints. */
  shards: ShardStore;
  /** Project-local routing index (bus id → shard E). */
  projectIndex: ProjectIndexStore;
  /** refs + value_blobs storage for promotion / materialization / ascent. `null` disables it. */
  values: ValueStore | null;
  /** Execution-layer sink: entities (receiver) + delegations (issuer) + escalations (raiser). */
  entities: EntityStore;
  /**
   * Per-owner-entity at-rest mirror of the CORE-global scope + closure store
   * (crash recovery / cold load). `null` / absent disables persistence — the warm
   * in-memory store is then the only copy (tests / store-less harnesses).
   */
  scopes?: ScopeStore | null;
}

/** Transaction provider for CoreModule. The host opens a backend tx and
 *  yields the tx-scoped {@link CoreTxStores}. */
export interface CoreStorage {
  withTransaction<T>(fn: (tx: CoreTxStores) => Promise<T>): Promise<T>;
}
