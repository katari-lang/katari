// Storage-backed `EntityStore` adapter — CoreModule's execution-layer sink.
//
// Constructed inside CoreModule's per-quantum transaction (the `storage` handle
// is that tx), bound to the project. Maps the runtime's EntityStore (entities +
// delegations + escalations) onto the api-server's repos. The runtime never
// sees the Storage facade, so it stays backend-agnostic.

import type {
  DelegationId,
  DelegationStoreRow,
  EntityId,
  EntityStore,
  EntityStoreRow,
  EscalationId,
  EscalationStoreRow,
} from "@katari-lang/runtime";
import type { ProjectId, Storage } from "../storage/types.js";

export class StorageEntityStore implements EntityStore {
  constructor(
    private readonly storage: Storage,
    private readonly projectId: ProjectId,
  ) {}

  async insertDelegation(row: DelegationStoreRow): Promise<void> {
    await this.storage.delegations.insert({
      id: row.id,
      projectId: this.projectId,
      parentEntityId: row.parentEntityId,
      targetModule: row.targetModule,
      agentDefId: row.agentDefId,
      args: row.args,
      state: row.state,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    });
  }

  async deleteDelegation(id: DelegationId): Promise<boolean> {
    return this.storage.delegations.delete(id);
  }

  async insertEntity(row: EntityStoreRow): Promise<void> {
    await this.storage.entities.insert({
      id: row.id,
      delegationId: row.delegationId,
      projectId: this.projectId,
      module: row.module,
      state: row.state,
      agentDefId: row.agentDefId,
      args: row.args,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    });
  }

  async deleteEntity(id: EntityId): Promise<boolean> {
    return this.storage.entities.delete(id);
  }

  async entityIdForDelegation(delegationId: DelegationId): Promise<EntityId | null> {
    return (await this.storage.entities.getByDelegation(this.projectId, delegationId))?.id ?? null;
  }

  async insertEscalation(row: EscalationStoreRow): Promise<void> {
    await this.storage.escalations.insert({
      id: row.id,
      entityId: row.entityId,
      projectId: this.projectId,
      agentDefId: row.agentDefId,
      args: row.args,
      createdAt: row.createdAt,
    });
  }

  async deleteEscalation(id: EscalationId): Promise<boolean> {
    return this.storage.escalations.delete(id);
  }
}
