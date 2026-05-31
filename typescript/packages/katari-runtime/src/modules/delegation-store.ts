// DelegationStore — persistence interface for the unified `delegations`
// audit table.
//
// The runtime owns the protocol-level act of issuing / completing
// delegations; the host (api-server) owns the audit table. This
// interface is the runtime → host hand-off: every Module writes a row
// for delegations it issued (= "caller writes"), and deletes the row
// on the terminal ack. The tree view in admin / future LSP-side
// debugger reads via the same table.
//
// **Scope**: each instance is bound to one snapshot. The Module
// constructor receives a store already scoped to its snapshot; method
// signatures don't carry snapshotId for that reason.

import type { AgentDefId } from "../agent-def-id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { DelegationId } from "../engine/id.js";
import type { EncryptedValue } from "../value-secret-codec.js";

/**
 * One row to insert into the unified `delegations` table. The caller
 * Module is the row's owner — it INSERTs at delegate-emit time, and
 * DELETEs at delegateAck / terminateAck arrival.
 */
export type DelegationStoreRow = {
  id: DelegationId;
  /** Tree root for `id`. Derived from parent (= inherit) or self when parent is null. */
  rootDelegationId: DelegationId;
  /** Immediate caller frame. `null` when this delegation is the run's root. */
  parentDelegationId: DelegationId | null;
  /** Module that emitted the `delegate` event (= self, by convention). */
  callerEndpoint: Endpoint;
  /** Module that runs the delegation (= the `to` of the delegate event). */
  ownerEndpoint: Endpoint;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  /** Always `running` at insert; transitions to `cancelling` are via setState. */
  state: "running" | "cancelling";
  createdAt: string;
  updatedAt: string;
};

export interface DelegationStore {
  insert(row: DelegationStoreRow): Promise<void>;
  delete(id: DelegationId): Promise<boolean>;
  /** Look up `rootDelegationId` for `id`. Used to inherit root on child insert. */
  getRoot(id: DelegationId): Promise<DelegationId | null>;
  /** Immediate parent of `id` (`null` for a run root, or if the row is gone).
   *  Used by GC ownership to hand a completing shard's escaping refs one level
   *  up. */
  getParent(id: DelegationId): Promise<DelegationId | null>;
}

/** No-op store for tests that don't care about audit. */
export const NULL_DELEGATION_STORE: DelegationStore = {
  async insert(): Promise<void> {},
  async delete(): Promise<boolean> {
    return false;
  },
  async getRoot(): Promise<DelegationId | null> {
    return null;
  },
  async getParent(): Promise<DelegationId | null> {
    return null;
  },
};
