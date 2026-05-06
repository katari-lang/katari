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

export interface ModuleRepo {
  insert(input: {
    irModule: IRModule;
    schemaBundle: SchemaBundle;
    name: string;
  }): Promise<VersionId>;
  list(): Promise<ModuleSummary[]>;
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
  list(filter?: { versionId?: VersionId }): Promise<AgentRow[]>;
  /**
   * Patch state / result / errorMessage on a single agent. Caller is
   * responsible for legal state transitions.
   */
  setState(
    id: AgentId,
    patch: Partial<Pick<AgentRow, "state" | "result" | "errorMessage">>,
  ): Promise<void>;
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
  /** Optional teardown for backends that hold sockets / pools. */
  close?(): Promise<void>;
}
