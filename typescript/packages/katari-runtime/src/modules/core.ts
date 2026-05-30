// CoreModule: a thin adapter wrapping the engine into the Module interface.
//
// Responsibilities:
//   - feed(event):   feed one event through applyEvent and return outbound
//   - persist(tx):   persist the current State via `tx.upsert(...)`
//   - load(tx):      deserialize if a checkpoint exists, else createState
//
// CORE has 1 snapshot = 1 IRModule = 1 State. `snapshotId` is the persistence key.
//
// Self-addressed events (= CORE->CORE) are included in applyEvent's outbound,
// returned to the bus, and the bus hands them back to the same CoreModule.feed
// (self-loops do not stay inside the engine).
//
// **Audit hook**: every outbound `delegate` event CORE emits is recorded
// in the unified `delegations` table via the injected `DelegationStore`
// so the admin tree view can render CORE → X edges. Symmetrically, the
// row is deleted on the matching `delegateAck` / `terminateAck`. The
// store is optional (`NULL_DELEGATION_STORE`) so tests that don't care
// about audit can skip it.

import { applyEvent, createState } from "../engine/apply.js";
import { CORE_ENDPOINT, type Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import type { DelegationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import {
  decryptCheckpoint,
  deserialize,
  type EncryptedEngineCheckpoint,
  encryptCheckpoint,
  serialize,
} from "../engine/snapshot.js";
import type { State } from "../engine/state.js";
import type { Thread } from "../engine/thread/types.js";
import type { IRModule } from "../ir/types.js";
import type { Module } from "../module.js";
import { encryptValueRecord } from "../value-secret-codec.js";
import { type DelegationStore, NULL_DELEGATION_STORE } from "./delegation-store.js";

/**
 * Storage interface that the CoreModule depends on. The host (api-server)
 * provides a concrete implementation backed by Postgres / in-memory.
 *
 * The shape exchanged is the **encrypted** form: CoreModule wraps every
 * persist/load with 'encryptCheckpoint' / 'decryptCheckpoint' so the
 * storage layer never sees plaintext secrets. The 'EncryptedEngineCheckpoint'
 * type is structurally identical to 'EngineCheckpoint' and is JSON-safe
 * for direct JSONB persistence.
 */
export interface CoreCheckpointStore {
  get(snapshotId: string): Promise<EncryptedEngineCheckpoint | null>;
  upsert(snapshotId: string, checkpoint: EncryptedEngineCheckpoint): Promise<void>;
}

export type CoreModuleOptions = {
  endpoint: Endpoint;
  snapshotId: string;
  irModule: IRModule;
  logger: Logger;
  /**
   * Audit sink for outbound delegate events. Defaults to a no-op store
   * so tests that don't exercise the tree view don't have to provide a
   * backing table.
   */
  delegationStore?: DelegationStore;
};

/** Tx shape CoreModule.persist / load expect. */
export type CoreTx = { coreCheckpoints: CoreCheckpointStore };

export class CoreModule implements Module<CoreTx> {
  readonly endpoint: Endpoint;
  private readonly snapshotId: string;
  private readonly irModule: IRModule;
  private readonly logger: Logger;
  private readonly delegationStore: DelegationStore;
  private state: State;

  constructor(opts: CoreModuleOptions) {
    this.endpoint = opts.endpoint;
    this.snapshotId = opts.snapshotId;
    this.irModule = opts.irModule;
    this.logger = opts.logger;
    this.delegationStore = opts.delegationStore ?? NULL_DELEGATION_STORE;
    this.state = createState(opts.irModule, { selfEndpoint: opts.endpoint });
  }

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    // Inbound terminal acks resolve a delegation we previously issued;
    // delete the audit row BEFORE applyEvent so a sub-delegate emitted
    // during apply (if any) doesn't race the parent's row delete.
    if (event.payload.kind === "delegateAck" || event.payload.kind === "terminateAck") {
      await this.delegationStore.delete(event.payload.delegationId);
    }

    // No `fetchRef` wired yet: CORE state holds no refs until persist-time
    // promotion lands (Phase E1), so the default (throw-on-ref) is never hit.
    const result = await applyEvent(this.state, event);
    this.state = result.state;
    for (const log of result.logs) {
      this.logger.log(log.level, log.message, log.context);
    }

    // Outbound delegates are CORE's "I'm calling X" — record them so the
    // admin tree can show "this run did N child calls". The parent is
    // the enclosing AgentThread, found by walking from the freshly-
    // created DelegateThread up the parent chain.
    //
    // outbound is `Event[]` whose payloads are always external by
    // construction; cast once here to avoid scattering casts inline.
    const outbound = result.outbound as ExternalEvent[];
    for (const ev of outbound) {
      if (ev.payload.kind === "delegate") {
        await this.persistOutboundDelegate(ev, ev.payload);
      }
    }
    return { outbound };
  }

  async persist(tx: CoreTx): Promise<void> {
    const encrypted = encryptCheckpoint(serialize(this.state));
    await tx.coreCheckpoints.upsert(this.snapshotId, encrypted);
  }

  async load(tx: CoreTx): Promise<void> {
    const encrypted = await tx.coreCheckpoints.get(this.snapshotId);
    this.state =
      encrypted !== null
        ? deserialize(this.irModule, decryptCheckpoint(encrypted))
        : createState(this.irModule, { selfEndpoint: this.endpoint });
  }

  /** Read-only access for tests / debug. */
  get currentState(): State {
    return this.state;
  }

  // ─── Audit helpers ─────────────────────────────────────────────────────

  /**
   * Insert one `delegations` row for an outbound `delegate` event. The
   * parent is the enclosing AgentThread in the engine's thread tree;
   * the root is inherited from the parent's existing audit row (and
   * defaults to self when no parent is found — defensive, shouldn't
   * happen for well-formed delegate emissions).
   */
  private async persistOutboundDelegate(
    ev: ExternalEvent,
    payload: Extract<ExternalEvent["payload"], { kind: "delegate" }>,
  ): Promise<void> {
    const parentDelegationId = this.findEnclosingAgentDelegation(payload.delegationId);
    const rootDelegationId =
      parentDelegationId === null
        ? payload.delegationId
        : ((await this.delegationStore.getRoot(parentDelegationId)) ?? payload.delegationId);
    const now = new Date().toISOString();
    await this.delegationStore.insert({
      id: payload.delegationId,
      rootDelegationId,
      parentDelegationId,
      callerEndpoint: CORE_ENDPOINT,
      ownerEndpoint: ev.to,
      agentDefId: payload.agentDefId,
      args: encryptValueRecord(payload.args),
      state: "running",
      createdAt: now,
      updatedAt: now,
    });
  }

  /**
   * Walk the engine's thread tree from the DelegateThread that owns
   * `delegationId` upward until reaching an AgentThread (= the body of
   * the agent currently executing). Returns that AgentThread's
   * delegationId. Returns `null` if no AgentThread sits above (= we are
   * at the engine root, which shouldn't normally happen for CORE-issued
   * outbound delegates).
   */
  private findEnclosingAgentDelegation(delegationId: DelegationId): DelegationId | null {
    const senderThreadId = this.state.pendingDelegateOut[delegationId];
    if (senderThreadId === undefined) return null;
    let cursor: Thread | undefined = this.state.threads[senderThreadId];
    while (cursor !== undefined) {
      if (cursor.kind === "agent") return cursor.delegationId;
      if (cursor.parent === null) return null;
      cursor = this.state.threads[cursor.parent];
    }
    return null;
  }
}
