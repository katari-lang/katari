// Storage-backed `FfiStore` implementation.
//
// 1 instance = 1 snapshot scope. Instantiated inside orchestrator.tick
// with tx + snapshotId bound. The underlying rows are in the
// `ffi_pending_delegations` / `ffi_pending_escalations` tables
// (`Storage.ffiDelegations` / `Storage.ffiEscalations` repo).

import type { DelegationId, Endpoint, EscalationId } from "@katari-lang/runtime";
import {
  CORE_ENDPOINT,
  FFI_ENDPOINT,
  type FfiPendingDelegation,
  type FfiPendingEscalation,
  type FfiStore,
} from "@katari-lang/runtime";
import type {
  FfiPendingDelegation as DbDelegation,
  FfiPendingEscalation as DbEscalation,
  SnapshotId,
  Storage,
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
    // Mirror ext-spawned children (= `katari.delegate(...)` from inside
    // an ext handler) into the unified `delegations` table so the tree
    // view shows them. Pure inbound ext calls (parentExtDelegationId
    // === null) are already recorded by CoreModule's audit hook when it
    // emitted the outbound `delegate(CORE → FFI)`, so we deliberately
    // skip those here to avoid PK collisions.
    if (row.parentExtDelegationId !== null) {
      const parentRoot =
        (await this.storage.delegations.get(row.parentExtDelegationId))?.rootDelegationId ??
        row.delegationId;
      await this.storage.delegations.insert({
        id: row.delegationId,
        rootDelegationId: parentRoot,
        parentDelegationId: row.parentExtDelegationId,
        snapshotId: this.snapshotId,
        callerEndpoint: FFI_ENDPOINT,
        ownerEndpoint: CORE_ENDPOINT,
        agentDefId: row.agentDefId,
        args: row.args,
        state: row.state,
        createdAt: row.createdAt,
        updatedAt: row.createdAt,
      });
    }
  }

  async getDelegation(id: DelegationId): Promise<FfiPendingDelegation | null> {
    const row = await this.storage.ffiDelegations.get(id);
    if (row === null || row.snapshotId !== this.snapshotId) return null;
    return toRuntimeDelegation(row);
  }

  async setDelegationState(id: DelegationId, state: "running" | "cancelling"): Promise<boolean> {
    // Mirror the state into the unified `delegations` row for ext-
    // spawned children (= rows we own). For inbound rows we don't own,
    // setState in the unified table is a no-op (= the row's writer is
    // CoreModule, which keeps it in sync).
    await this.storage.delegations.setState(id, state);
    return this.storage.ffiDelegations.setState(id, state);
  }

  async deleteDelegation(id: DelegationId): Promise<boolean> {
    // Drop the unified `delegations` row too. It only exists for ext-
    // spawned children (insertDelegation skipped pure-inbound ext calls)
    // so the delete is a no-op when this id was an inbound call —
    // exactly what we want, since CoreModule owns inbound deletion via
    // delegateAck / terminateAck.
    await this.storage.delegations.delete(id);
    return this.storage.ffiDelegations.delete(id);
  }

  async listDelegations(): Promise<FfiPendingDelegation[]> {
    const rows = await this.storage.ffiDelegations.listBySnapshot(this.snapshotId);
    return rows.map(toRuntimeDelegation);
  }

  async listChildrenOf(parentId: DelegationId): Promise<FfiPendingDelegation[]> {
    const rows = await this.storage.ffiDelegations.listChildrenOf(parentId);
    return rows.filter((r) => r.snapshotId === this.snapshotId).map(toRuntimeDelegation);
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
    const rows = await this.storage.ffiEscalations.listBySnapshot(this.snapshotId);
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
