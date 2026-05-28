// Storage-backed `DelegationStore` implementation. Adapter between the
// runtime-side audit interface and the api-server's unified `delegations`
// table.
//
// One instance = one snapshot scope (constructed inside orchestrator.tick
// with tx + snapshotId bound). The runtime caller never touches
// snapshotId; it's implicit in the binding.

import type { DelegationId, DelegationStore, DelegationStoreRow } from "@katari-lang/runtime";
import type { SnapshotId, Storage } from "../storage/types.js";

export class StorageDelegationStore implements DelegationStore {
  constructor(
    private readonly storage: Storage,
    private readonly snapshotId: SnapshotId,
  ) {}

  async insert(row: DelegationStoreRow): Promise<void> {
    await this.storage.delegations.insert({
      id: row.id,
      rootDelegationId: row.rootDelegationId,
      parentDelegationId: row.parentDelegationId,
      snapshotId: this.snapshotId,
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
}
