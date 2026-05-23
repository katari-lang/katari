// FfiStore — persistence layer interface for the FFI Module.
//
// The FFI Module keeps "delegation / escalation that has been sent to the
// sidecar and is still pending" in its own DB (independent of CORE-side
// state). The host (api-server / cli / tests) provides the concrete impl.
//
// Each instance must be **bound to a specific "key" (= normally snapshotId)**.
// By not taking a key in method arguments, misuse (= touching records of
// another snapshot) is structurally prevented.

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId, EscalationId } from "../engine/id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { EncryptedValue } from "../value-secret-codec.js";

/**
 * Record of "FFI Module has sent this to the sidecar and is awaiting a reply".
 *
 *   - `peerEndpoint`: who to ack to (= ext call caller, normally CORE)
 *   - `agentDefId`:   encoding received on the wire (= FFI-side namespace)
 *   - `parentExtDelegationId`: non-null only for ext-delegated child agents.
 *     For a child agent spawned by an ext handler via `katari.delegate(...)`,
 *     this holds "the delegationId of the ext call itself". Using it we can
 *     look up the parent ext delegation's peer for escalate relaying + on
 *     restart we can terminate orphan children.
 *
 * **Wire form**: `args` carries 'EncryptedValue' (= `secret` variants
 * replaced by the storage envelope). FfiModule encrypts on the way
 * in and decrypts on the way out so the store implementation (=
 * api-server side) is unaware of secret semantics.
 */
export type FfiPendingDelegation = {
  delegationId: DelegationId;
  peerEndpoint: Endpoint;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  state: "running" | "cancelling";
  createdAt: string;
  parentExtDelegationId: DelegationId | null;
};

/**
 * Record of "an escalate that the sidecar emitted and is being forwarded
 * to CORE". If the sidecar process is lost on restart, these are cleaned
 * up (= dropped) on startup. `args` is the encrypted form (see
 * 'FfiPendingDelegation' note).
 */
export type FfiPendingEscalation = {
  escalationId: EscalationId;
  delegationId: DelegationId;
  peerEndpoint: Endpoint;
  agentDefId: AgentDefId;
  args: Record<string, EncryptedValue>;
  createdAt: string;
};

export interface FfiStore {
  // ─── Pending delegations ──────────────────────────────────────────────
  insertDelegation(row: FfiPendingDelegation): Promise<void>;
  getDelegation(id: DelegationId): Promise<FfiPendingDelegation | null>;
  setDelegationState(
    id: DelegationId,
    state: "running" | "cancelling",
  ): Promise<boolean>;
  deleteDelegation(id: DelegationId): Promise<boolean>;
  /** Return all rows in scope, for `ipcDelegateRestarted` send + child terminate fire on startup. */
  listDelegations(): Promise<FfiPendingDelegation[]>;
  /** Return child delegations whose `parentExtDelegationId` is the given parent ext delegation. */
  listChildrenOf(parentId: DelegationId): Promise<FfiPendingDelegation[]>;

  // ─── Pending escalations ──────────────────────────────────────────────
  insertEscalation(row: FfiPendingEscalation): Promise<void>;
  getEscalation(id: EscalationId): Promise<FfiPendingEscalation | null>;
  deleteEscalation(id: EscalationId): Promise<boolean>;
  /** Return all rows in scope, for startup cleanup. */
  listEscalations(): Promise<FfiPendingEscalation[]>;
}
