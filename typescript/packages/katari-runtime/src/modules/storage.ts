// Per-module transactional storage providers.
//
// A self-contained module opens its OWN transaction (1 quantum = 1 tx) rather
// than running inside a host-owned tick tx. These provider interfaces are the
// runtime → host hand-off: the host implements `withTransaction` over its
// concrete backend (Postgres / in-memory) and hands the module a tx-scoped
// bundle of the stores it needs. The module never sees the host's `Storage`
// facade, so the runtime stays backend-agnostic.

import type { ProjectIndexStore, ShardStore } from "../engine/shard.js";
import type { EnvStore } from "../sidecar/env-store.js";
import type { ValueStore } from "../storage/value-store.js";
import type { DelegationStore } from "./delegation-store.js";

// ─── CORE ──────────────────────────────────────────────────────────────────

/** Tx-scoped stores CoreModule touches in one quantum. */
export interface CoreTxStores {
  /** Per-agent shard checkpoints. */
  shards: ShardStore;
  /** Project-local routing index (delegation / escalation id → shard). */
  projectIndex: ProjectIndexStore;
  /** 3-layer byte storage for persist-time promotion + ref materialization. `null` disables it. */
  values: ValueStore | null;
  /** Audit sink for outbound delegate rows (the run tree). */
  delegations: DelegationStore;
}

/** Transaction provider for CoreModule. The host opens a backend tx and
 *  yields the tx-scoped {@link CoreTxStores}. */
export interface CoreStorage {
  withTransaction<T>(fn: (tx: CoreTxStores) => Promise<T>): Promise<T>;
}

// ─── ENV ─────────────────────────────────────────────────────────────────

/** Transaction provider for EnvModule. Each env operation runs in its own
 *  short tx (env feeds are single-op), so the impl may also be a thin
 *  per-op wrapper rather than a real multi-op tx. */
export interface EnvStorage {
  withTransaction<T>(fn: (env: EnvStore) => Promise<T>): Promise<T>;
}
