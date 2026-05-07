// Persistence layer interfaces.
//
// `katari-api-server` always talks to storage through these interfaces. The
// production binding is Postgres (`pg.ts`), but tests use `memory-storage.ts`
// to keep them hermetic. Adding a new backend means only implementing
// `Storage` (and optionally individual repo classes); nothing else changes.

import type {
  DelegationId,
  IRModule,
  MachineSnapshot,
  SchemaBundle,
  Value,
} from "katari-runtime";

export type VersionId = string & { readonly __brand: "VersionId" };

/**
 * API-layer identifier for an agent. Distinct from `DelegationId`, which
 * is the runtime's identifier for the underlying delegation. Each agent
 * row carries both: `id` is what the REST client sees, `delegationId`
 * is what the runtime sees. Outbound runtime events identify the agent
 * by `delegationId`; we map back to the API id via `findByDelegationId`.
 */
export type AgentId = string & { readonly __brand: "AgentId" };

/** Lifecycle states an Agent can be in. Permanent rows live forever. */
export type AgentState =
  | "running"
  | "cancelling"
  | "cancelled"
  | "succeeded"
  | "error";

export type ModuleRow = {
  id: VersionId;
  name: string;
  irModule: IRModule;
  schemaBundle: SchemaBundle;
  createdAt: string;
};

export type ModuleSummary = {
  id: VersionId;
  name: string;
  createdAt: string;
};

export type AgentRow = {
  id: AgentId;
  /** Runtime's delegation identifier for this agent. Unique per row. */
  delegationId: DelegationId;
  versionId: VersionId;
  qualifiedName: string;
  args: Record<string, Value>;
  state: AgentState;
  result?: Value;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
};

/**
 * Pagination options accepted by `list` calls. `limit` is upper-bounded
 * by an internal cap (currently 500) inside the storage implementation;
 * supplying anything larger is silently clamped. `offset` is used because
 * key-set pagination would require exposing the underlying index column
 * shape; offset is enough for the small admin-style endpoints we have.
 */
export type ListOptions = {
  limit?: number;
  offset?: number;
};

export interface ModuleRepo {
  insert(input: {
    irModule: IRModule;
    schemaBundle: SchemaBundle;
    name: string;
  }): Promise<VersionId>;
  list(options?: ListOptions): Promise<ModuleSummary[]>;
  get(id: VersionId): Promise<ModuleRow | null>;
}

export interface AgentRepo {
  insert(row: AgentRow): Promise<void>;
  get(id: AgentId): Promise<AgentRow | null>;
  /**
   * Look up by the runtime's delegation id. Used to route outbound
   * `delegateAck` / `terminateAck` events back to their agent record
   * when the runtime only carries a `DelegationId`.
   */
  findByDelegationId(delegationId: DelegationId): Promise<AgentRow | null>;
  list(filter?: { versionId?: VersionId } & ListOptions): Promise<AgentRow[]>;
  /**
   * Patch state / result / errorMessage on a single agent.
   *
   * `options.expectedState` enables optimistic concurrency: when supplied,
   * the update is only applied if the row's current state matches —
   * otherwise it's a no-op. Used to prevent the
   * `cancelAgent("cancelling") + routeOutbound delegateAck("succeeded")`
   * race from clobbering each other.
   *
   * Returns `true` if a row was updated, `false` if `expectedState` was
   * supplied and didn't match (or, harmlessly, if no row exists). Callers
   * that don't care about the outcome can ignore the return.
   */
  setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
    options?: { expectedState?: AgentState },
  ): Promise<boolean>;
  /**
   * Bulk-mark every running/cancelling agent in `versionId` as `error`
   * with the given message. Used when poisoning a machine.
   */
  markAllRunningAsError(versionId: VersionId, message: string): Promise<void>;
  /** Distinct version_ids that still own at least one running/cancelling agent. */
  listRunningVersionIds(): Promise<VersionId[]>;
}

export interface SnapshotRepo {
  upsert(versionId: VersionId, snapshot: MachineSnapshot): Promise<void>;
  get(versionId: VersionId): Promise<MachineSnapshot | null>;
  delete(versionId: VersionId): Promise<void>;
}

export interface Storage {
  modules: ModuleRepo;
  agents: AgentRepo;
  snapshots: SnapshotRepo;
  /**
   * Run `fn` inside a backend-native transaction. The `tx` argument is a
   * `Storage`-shaped facade whose `modules` / `agents` / `snapshots`
   * methods participate in the same transaction; outside-of-tx access
   * (via the original `Storage`) bypasses it and is left to the caller's
   * judgement.
   *
   * - PostgreSQL: implemented via `sql.begin` (BEGIN/COMMIT/ROLLBACK).
   * - In-memory: implemented via a snapshot-and-restore-on-failure model
   *   (`structuredClone` of the underlying maps before `fn` runs; on
   *   throw, swap the cloned maps back in so the test sees a rollback).
   *
   * The api-server uses this to keep `agents.insert + snapshots.upsert +
   * setState` mutations atomic: a process crash mid-sequence will see
   * either all updates applied or none, never a half-state.
   */
  withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T>;
  /** Optional teardown for backends that hold sockets / pools. */
  close?(): Promise<void>;
}
