// EntityStore — the runtime → host hand-off for the execution layer (entities +
// delegations + escalations). See docs/2026-06-01-entity-model.md.
//
// Two records with distinct owners + nested lifetimes:
//   - delegation (the ISSUER's request edge): inserted at `delegate` emit,
//     deleted at the result ack. `parentEntityId` is the issuer's OWN entity.
//   - entity (the RECEIVER's execution node): inserted when the module begins
//     processing an inbound `delegate` (minting a fresh `E`) from the bus event
//     + ambient context ALONE, deleted by that entity on its terminal.
// Plus escalations, owned by the RAISER entity (inserted at escalate emit,
// deleted by the raiser on escalateAck).
//
// Each instance is bound to one project (the module is per-project), so method
// signatures don't carry projectId.

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId, EntityId, EscalationId } from "../engine/id.js";
import type { EncryptedValue } from "../value-secret-codec.js";

/** The module that runs an entity (the 4 katari-protocol endpoints). */
export type EntityModule = "core" | "ffi" | "api" | "env";

/** A delegation (request edge) row to insert. Issuer-managed. */
export type DelegationStoreRow = {
  id: DelegationId;
  /** The issuer's OWN entity (the parent link; known locally). */
  parentEntityId: EntityId;
  /** Which module will run the child (the delegate's `to`). */
  targetModule: EntityModule;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: "running" | "cancelling";
  createdAt: string;
  updatedAt: string;
};

/** An entity (execution node) row to insert. Receiver-managed. */
export type EntityStoreRow = {
  id: EntityId;
  /** The summoning delegation `D` (from the bus). */
  delegationId: DelegationId | null;
  module: EntityModule;
  agentDefId: AgentDefId | null;
  args: Record<string, EncryptedValue>;
  state: "running" | "cancelling";
  createdAt: string;
  updatedAt: string;
};

/** A live escalation row to insert. Owned by the raising entity. */
export type EscalationStoreRow = {
  id: EscalationId;
  entityId: EntityId;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  createdAt: string;
};

export interface EntityStore {
  /** Issuer: write the request edge at `delegate` emit. */
  insertDelegation(row: DelegationStoreRow): Promise<void>;
  /** Issuer: drop the request edge on the result ack. */
  deleteDelegation(id: DelegationId): Promise<boolean>;
  /** Receiver: mint + write the execution node at `delegate` receipt. */
  insertEntity(row: EntityStoreRow): Promise<void>;
  /** Receiver: self-delete on terminal (cascades its refs + raised escalations). */
  deleteEntity(id: EntityId): Promise<boolean>;
  /** Receiver: resolve its own entity id from the summoning `D` (for a module
   *  that minted `E` in an earlier quantum and must find it again on terminal —
   *  e.g. FFI, whose ext lifetime spans multiple sidecar messages). */
  entityIdForDelegation(delegationId: DelegationId): Promise<EntityId | null>;
  /** Raiser: write a live escalation at escalate emit. */
  insertEscalation(row: EscalationStoreRow): Promise<void>;
  /** Raiser: drop its escalation on escalateAck. */
  deleteEscalation(id: EscalationId): Promise<boolean>;
}

/** No-op store for tests that don't care about the execution layer. */
export const NULL_ENTITY_STORE: EntityStore = {
  async insertDelegation(): Promise<void> {},
  async deleteDelegation(): Promise<boolean> {
    return false;
  },
  async insertEntity(): Promise<void> {},
  async deleteEntity(): Promise<boolean> {
    return false;
  },
  async entityIdForDelegation(): Promise<EntityId | null> {
    return null;
  },
  async insertEscalation(): Promise<void> {},
  async deleteEscalation(): Promise<boolean> {
    return false;
  },
};
