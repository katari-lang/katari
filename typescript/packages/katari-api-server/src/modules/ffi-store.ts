// Storage-backed `FfiStore` implementation.
//
// 1 instance = 1 snapshot scope. Instantiated inside orchestrator.tick
// with tx + snapshotId bound. The underlying rows are in the
// `ffi_pending_delegations` / `ffi_pending_escalations` tables
// (`Storage.ffiDelegations` / `Storage.ffiEscalations` repo).

import type {
  FfiPendingDelegation,
  FfiPendingEscalation,
  FfiStore,
} from "@katari-lang/runtime";
import type { DelegationId, EscalationId, Endpoint } from "@katari-lang/runtime";
import type {
  Storage,
  SnapshotId,
  FfiPendingDelegation as DbDelegation,
  FfiPendingEscalation as DbEscalation,
} from "../storage/types.js";

export class StorageFfiStore implements FfiStore {
  constructor(
    private readonly storage: Storage,
    private readonly snapshotId: SnapshotId,
  ) {}

  // ─── Delegations ────────────────────────────────────────────────────────

  async insertDelegation(row: FfiPendingDelegation): Promise<void> {
    await this.storage.ffiDelegations.insert({
      delegationId: row.delegationId,
      snapshotId: this.snapshotId,
      peerEndpoint: row.peerEndpoint,
      agentDefId: row.agentDefId,
      args: row.args,
      state: row.state,
      createdAt: row.createdAt,
      parentExtDelegationId: row.parentExtDelegationId,
    });
  }

  async getDelegation(id: DelegationId): Promise<FfiPendingDelegation | null> {
    const row = await this.storage.ffiDelegations.get(id);
    if (row === null || row.snapshotId !== this.snapshotId) return null;
    return toRuntimeDelegation(row);
  }

  async setDelegationState(
    id: DelegationId,
    state: "running" | "cancelling",
  ): Promise<boolean> {
    return this.storage.ffiDelegations.setState(id, state);
  }

  async deleteDelegation(id: DelegationId): Promise<boolean> {
    return this.storage.ffiDelegations.delete(id);
  }

  async listDelegations(): Promise<FfiPendingDelegation[]> {
    const rows = await this.storage.ffiDelegations.listBySnapshot(
      this.snapshotId,
    );
    return rows.map(toRuntimeDelegation);
  }

  async listChildrenOf(
    parentId: DelegationId,
  ): Promise<FfiPendingDelegation[]> {
    const rows = await this.storage.ffiDelegations.listChildrenOf(parentId);
    return rows
      .filter((r) => r.snapshotId === this.snapshotId)
      .map(toRuntimeDelegation);
  }

  // ─── Escalations ────────────────────────────────────────────────────────

  async insertEscalation(row: FfiPendingEscalation): Promise<void> {
    await this.storage.ffiEscalations.insert({
      escalationId: row.escalationId,
      delegationId: row.delegationId,
      snapshotId: this.snapshotId,
      peerEndpoint: row.peerEndpoint,
      agentDefId: row.agentDefId,
      args: row.args,
      createdAt: row.createdAt,
    });
  }

  async getEscalation(id: EscalationId): Promise<FfiPendingEscalation | null> {
    const row = await this.storage.ffiEscalations.get(id);
    if (row === null || row.snapshotId !== this.snapshotId) return null;
    return toRuntimeEscalation(row);
  }

  async deleteEscalation(id: EscalationId): Promise<boolean> {
    return this.storage.ffiEscalations.delete(id);
  }

  async listEscalations(): Promise<FfiPendingEscalation[]> {
    const rows = await this.storage.ffiEscalations.listBySnapshot(
      this.snapshotId,
    );
    return rows.map(toRuntimeEscalation);
  }
}

function toRuntimeDelegation(row: DbDelegation): FfiPendingDelegation {
  return {
    delegationId: row.delegationId,
    peerEndpoint: row.peerEndpoint as Endpoint,
    agentDefId: row.agentDefId,
    args: row.args,
    state: row.state,
    createdAt: row.createdAt,
    parentExtDelegationId: row.parentExtDelegationId,
  };
}

function toRuntimeEscalation(row: DbEscalation): FfiPendingEscalation {
  return {
    escalationId: row.escalationId,
    delegationId: row.delegationId,
    peerEndpoint: row.peerEndpoint as Endpoint,
    agentDefId: row.agentDefId,
    args: row.args,
    createdAt: row.createdAt,
  };
}
