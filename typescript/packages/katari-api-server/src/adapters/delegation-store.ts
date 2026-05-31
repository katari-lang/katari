// Storage-backed `DelegationStore` adapter — CoreModule's audit sink for the
// unified `delegations` table.
//
// Constructed inside CoreModule's per-quantum transaction (the `storage` handle
// is that tx), bound to the project. The delegation is a katari-protocol entity
// scoped to a project; which snapshot the issuing shard runs is CORE-private
// state (engine_shards.current_snapshot) and is deliberately NOT written here.

import type { DelegationId, DelegationStore, DelegationStoreRow } from "@katari-lang/runtime";
import type { ProjectId, Storage } from "../storage/types.js";

export class StorageDelegationStore implements DelegationStore {
  constructor(
    private readonly storage: Storage,
    private readonly projectId: ProjectId,
  ) {}

  async insert(row: DelegationStoreRow): Promise<void> {
    await this.storage.delegations.insert({
      id: row.id,
      rootDelegationId: row.rootDelegationId,
      parentDelegationId: row.parentDelegationId,
      projectId: this.projectId,
      callerEndpoint: row.callerEndpoint,
      ownerEndpoint: row.ownerEndpoint,
      agentDefId: row.agentDefId,
      args: row.args,
      state: row.state,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    });
  }

  async delete(id: DelegationId): Promise<boolean> {
    return this.storage.delegations.delete(id);
  }

  async getRoot(id: DelegationId): Promise<DelegationId | null> {
    const row = await this.storage.delegations.get(id);
    return row?.rootDelegationId ?? null;
  }

  async getParent(id: DelegationId): Promise<DelegationId | null> {
    const row = await this.storage.delegations.get(id);
    return row?.parentDelegationId ?? null;
  }
}
