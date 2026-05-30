// CoreModule: adapts the engine into the Module interface, sharded per agent.
//
// Phase E splits the flat per-snapshot State into per-agent-instance shards: a
// shard IS a State scoped to one agent (its threads / scopes / closures + its
// own local routing maps). CoreModule holds the shards it touches this tick
// (loaded on demand) plus the project-local index that maps a delegation /
// escalation id to the shard that must handle an event. All cross-shard
// routing reduces to an index lookup (docs/2026-05-30-phase-e-actor-host.md
// §2/§3, verified against the engine's escalate path):
//
//   delegate      → new shard (shardId = the new delegation id)
//   delegateAck   → index.pendingDelegateOut[delegationId]
//   terminate     → index.delegations[delegationId]
//   terminateAck  → index.pendingDelegateOut[delegationId]
//   escalate      → index.pendingDelegateOut[delegationId]   (the delegate issuer)
//   escalateAck   → index.escalationOwners[escalationId]
//
// load() restores the lightweight project index; shard bodies load on demand
// in feed(); persist() writes back dirty shards (with persist-time string
// promotion), deletes completed ones (no replay → no retention), and saves the
// index. The store handles are the tick's tx-scoped ones, injected at
// construction, so feed() — which the Module interface gives no tx — can still
// load shards within the tick's transaction.

import { type AgentDefId, decodeCoreAgentDefId, encodeCoreAgentDefId } from "../agent-def-id.js";
import { applyEvent, createState } from "../engine/apply.js";
import { CORE_ENDPOINT, type Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import type { DelegationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import {
  emptyProjectIndex,
  type ProjectIndex,
  type ProjectIndexStore,
  type ShardId,
  type ShardStore,
} from "../engine/shard.js";
import {
  DEFAULT_PROMOTE_THRESHOLD_BYTES,
  decryptCheckpoint,
  deserialize,
  encryptCheckpoint,
  promoteCheckpoint,
  serialize,
} from "../engine/snapshot.js";
import type { State } from "../engine/state.js";
import type { RefFetcher } from "../engine/step-ctx.js";
import type { Thread } from "../engine/thread/types.js";
import type { RefRep } from "../engine/value.js";
import type { IRModule } from "../ir/types.js";
import type { Module } from "../module.js";
import type { ValueStore } from "../storage/value-store.js";
import { encryptValueRecord } from "../value-secret-codec.js";
import { type DelegationStore, NULL_DELEGATION_STORE } from "./delegation-store.js";

export type CoreModuleOptions = {
  endpoint: Endpoint;
  /** Which snapshot's IR this module runs. Shards it creates record this as their currentSnapshot. */
  snapshotId: string;
  irModule: IRModule;
  logger: Logger;
  /** Project the shards belong to (value refs + shard storage are project-scoped). */
  projectId: string;
  /** Per-agent shard checkpoints. Tick-tx-scoped (injected so feed can load on demand). */
  shardStore: ShardStore;
  /** Project-local routing index store. Tick-tx-scoped. */
  projectIndexStore: ProjectIndexStore;
  /**
   * Audit sink for outbound delegate events. Defaults to a no-op store
   * so tests that don't exercise the tree view don't have to provide a
   * backing table.
   */
  delegationStore?: DelegationStore;
  /**
   * Value store for persist-time promotion (inline string → ref) and for
   * materializing ref bytes during a quantum. Omitted → no promotion,
   * inline only (refs never appear, so the materialize path is dormant).
   */
  valueStore?: ValueStore;
  /** Byte threshold above which an inline string is promoted to a ref. */
  promotionThreshold?: number;
  /**
   * Resolve a snapshot id to its IR. A shard runs the version recorded in its
   * `currentSnapshot`; the host provides this so one CoreModule can run agents
   * across snapshots (per-project module). Defaults to the single `irModule`.
   */
  getIR?: (snapshot: string) => IRModule;
};

/** Tx shape CoreModule.persist / load expect — empty: the stores are held. */
export type CoreTx = Record<string, never>;

type ShardEntry = { state: State; dirty: boolean; currentSnapshot: string };

export class CoreModule implements Module<CoreTx> {
  readonly endpoint: Endpoint;
  private readonly snapshotId: string;
  private readonly irModule: IRModule;
  private readonly logger: Logger;
  private readonly projectId: string;
  private readonly shardStore: ShardStore;
  private readonly projectIndexStore: ProjectIndexStore;
  private readonly delegationStore: DelegationStore;
  private readonly valueStore: ValueStore | null;
  private readonly promotionThreshold: number;
  private readonly getIR: (snapshot: string) => IRModule;

  /** Shards touched this tick (loaded on demand, persisted at tick end). */
  private shardCache = new Map<ShardId, ShardEntry>();
  /** Shards whose root completed this tick — deleted on persist. */
  private completedShards = new Set<ShardId>();
  /** Project routing index (loaded in load, written in persist). */
  private projectIndex: ProjectIndex = emptyProjectIndex();

  constructor(opts: CoreModuleOptions) {
    this.endpoint = opts.endpoint;
    this.snapshotId = opts.snapshotId;
    this.irModule = opts.irModule;
    this.logger = opts.logger;
    this.projectId = opts.projectId;
    this.shardStore = opts.shardStore;
    this.projectIndexStore = opts.projectIndexStore;
    this.delegationStore = opts.delegationStore ?? NULL_DELEGATION_STORE;
    this.valueStore = opts.valueStore ?? null;
    this.promotionThreshold = opts.promotionThreshold ?? DEFAULT_PROMOTE_THRESHOLD_BYTES;
    this.getIR = opts.getIR ?? (() => opts.irModule);
  }

  /** Fetch a ref's bytes — threaded into applyEvent so concat / format / etc.
   *  can materialize ref operands. Null when no value store is wired. */
  private get fetchRef(): RefFetcher | undefined {
    const valueStore = this.valueStore;
    const projectId = this.projectId;
    if (valueStore === null) return undefined;
    return async (rep: RefRep): Promise<Uint8Array> => {
      const bytes = await valueStore.fetch(projectId, rep.module, rep.id);
      if (bytes === null) {
        throw new Error(`core.materialize: ref ${rep.module}/${rep.id} not found in value store`);
      }
      return bytes;
    };
  }

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    if (event.payload.kind === "delegateAck" || event.payload.kind === "terminateAck") {
      // Drop the audit row BEFORE applyEvent so a sub-delegate emitted during
      // apply doesn't race the parent's row delete.
      await this.delegationStore.delete(event.payload.delegationId);
    }

    const shardId = this.routeToShard(event);
    if (shardId === undefined) {
      this.logger.log("debug", "core: event for unknown shard, dropping", {
        kind: event.payload.kind,
      });
      return { outbound: [] };
    }
    // An inbound CORE delegate carries the version to run on in its agent def
    // id (a closure / un-stamped one falls back to this module's snapshot).
    const delegateSnapshot =
      event.payload.kind === "delegate"
        ? decodeDelegateSnapshot(event.payload.agentDefId)
        : undefined;
    const shard = await this.getOrLoadShard(
      shardId,
      event.payload.kind === "delegate",
      delegateSnapshot,
    );
    if (shard === null) {
      this.logger.log("debug", "core: no shard for event, dropping", {
        kind: event.payload.kind,
        shardId,
      });
      return { outbound: [] };
    }

    const result = await applyEvent(shard.state, event, this.fetchRef);
    shard.state = result.state;
    shard.dirty = true;
    for (const log of result.logs) {
      this.logger.log(log.level, log.message, log.context);
    }

    this.reconcileIndex(shardId, shard.state);
    // A shard with no live threads has finished — delete it on persist and
    // purge its index entries (no replay → no retention).
    if (shard.state.threadCount === 0) {
      this.completedShards.add(shardId);
      this.shardCache.delete(shardId);
      this.purgeIndexForShard(shardId);
    }

    const outbound = result.outbound as ExternalEvent[];
    for (const ev of outbound) {
      if (ev.payload.kind === "delegate") {
        // The agent def id is the only identifier that loads versioned code on
        // the receiver, so it carries the issuing shard's snapshot — but ONLY
        // for snapshot-dependent modules (CORE agents run versioned IR, FFI
        // picks the per-snapshot sidecar). ENV / API are snapshot-independent
        // (common builtins / run management) → left bare. Closures inherit.
        const toSnapshotDependent =
          ev.to === shard.state.selfEndpoint || ev.to === shard.state.ffiTargetEndpoint;
        if (toSnapshotDependent) {
          ev.payload.agentDefId = stampDelegateSnapshot(
            ev.payload.agentDefId,
            shard.currentSnapshot,
          );
        }
        await this.persistOutboundDelegate(shard.state, ev, ev.payload);
      }
    }
    return { outbound };
  }

  async load(_tx: CoreTx): Promise<void> {
    this.shardCache = new Map();
    this.completedShards = new Set();
    this.projectIndex = (await this.projectIndexStore.get(this.projectId)) ?? emptyProjectIndex();
  }

  async persist(_tx: CoreTx): Promise<void> {
    for (const [shardId, entry] of this.shardCache) {
      if (!entry.dirty) continue;
      await this.persistShard(shardId, entry.state, entry.currentSnapshot);
    }
    for (const shardId of this.completedShards) {
      await this.shardStore.delete(this.projectId, shardId);
    }
    await this.projectIndexStore.upsert(this.projectId, this.projectIndex);
  }

  // ─── Shard load / route / persist ──────────────────────────────────────

  /** The shard an event must be handled in. `undefined` = unknown id. */
  private routeToShard(event: ExternalEvent): ShardId | undefined {
    const p = event.payload;
    switch (p.kind) {
      case "delegate":
        return p.delegationId; // new shard, keyed by the new delegation id
      case "delegateAck":
      case "terminateAck":
      case "escalate":
        return this.projectIndex.pendingDelegateOut[p.delegationId];
      case "terminate":
        return this.projectIndex.delegations[p.delegationId];
      case "escalateAck":
        return this.projectIndex.escalationOwners[p.escalationId];
      default:
        return undefined;
    }
  }

  private async getOrLoadShard(
    shardId: ShardId,
    isDelegate: boolean,
    delegateSnapshot: string | undefined,
  ): Promise<ShardEntry | null> {
    const cached = this.shardCache.get(shardId);
    if (cached !== undefined) return cached;
    const loaded = await this.shardStore.get(this.projectId, shardId);
    if (loaded !== null) {
      const entry: ShardEntry = {
        state: deserialize(
          this.getIR(loaded.currentSnapshot),
          decryptCheckpoint(loaded.checkpoint),
        ),
        dirty: false,
        currentSnapshot: loaded.currentSnapshot,
      };
      this.shardCache.set(shardId, entry);
      return entry;
    }
    if (isDelegate) {
      // New agent instance: the version comes from the delegate's agentDefId
      // (a closure / un-stamped delegate falls back to this module's snapshot).
      const snapshot = delegateSnapshot ?? this.snapshotId;
      const entry: ShardEntry = {
        state: createState(this.getIR(snapshot), { selfEndpoint: this.endpoint }),
        dirty: false,
        currentSnapshot: snapshot,
      };
      this.shardCache.set(shardId, entry);
      return entry;
    }
    return null;
  }

  private async persistShard(
    shardId: ShardId,
    state: State,
    currentSnapshot: string,
  ): Promise<void> {
    // Promote large inline strings to refs BEFORE encrypting (promotion handles
    // strings, encryption handles secrets — disjoint). Keeps a heavy AI
    // conversation out of the shard checkpoint.
    const checkpoint = serialize(state);
    const promoted =
      this.valueStore !== null
        ? await promoteCheckpoint(checkpoint, this.promoteText, this.promotionThreshold)
        : checkpoint;
    await this.shardStore.upsert({
      projectId: this.projectId,
      shardId,
      currentSnapshot,
      status: "active",
      checkpoint: encryptCheckpoint(promoted),
    });
  }

  /** Promote one inline string to an owner=core ref by writing its bytes. */
  private promoteText = async (text: string): Promise<RefRep> => {
    const valueStore = this.valueStore as ValueStore;
    const result = await valueStore.putComplete({
      projectId: this.projectId,
      owner: "core",
      bytes: new TextEncoder().encode(text),
      semanticKind: "string",
    });
    return { kind: "ref", module: "core", id: result.id, hash: result.hash, size: result.size };
  };

  // ─── Project index reconciliation ──────────────────────────────────────

  /** Sync the index entries owned by `shardId` to the shard's local maps. */
  private reconcileIndex(shardId: ShardId, state: State): void {
    syncIndexMap(this.projectIndex.delegations, state.delegations, shardId);
    syncIndexMap(this.projectIndex.pendingDelegateOut, state.pendingDelegateOut, shardId);
    syncIndexMap(this.projectIndex.escalationOwners, state.escalationOwners, shardId);
  }

  /** Remove every index entry pointing at a now-completed shard. */
  private purgeIndexForShard(shardId: ShardId): void {
    for (const map of [
      this.projectIndex.delegations,
      this.projectIndex.pendingDelegateOut,
      this.projectIndex.escalationOwners,
    ] as Record<string, ShardId>[]) {
      for (const key of Object.keys(map)) {
        if (map[key] === shardId) delete map[key];
      }
    }
  }

  /** Shard state for tests / debug. `undefined` if not loaded this tick. */
  shardState(shardId: ShardId): State | undefined {
    return this.shardCache.get(shardId)?.state;
  }

  /** Routing index for tests / debug. Empty once every shard has completed. */
  get currentProjectIndex(): ProjectIndex {
    return this.projectIndex;
  }

  // ─── Audit helpers ─────────────────────────────────────────────────────

  private async persistOutboundDelegate(
    state: State,
    ev: ExternalEvent,
    payload: Extract<ExternalEvent["payload"], { kind: "delegate" }>,
  ): Promise<void> {
    const parentDelegationId = findEnclosingAgentDelegation(state, payload.delegationId);
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
}

/** Sync `indexMap` so every key in `stateMap` points at `shardId`, and any
 *  stale key that used to point at `shardId` is removed. */
function syncIndexMap(
  indexMap: Record<string, ShardId>,
  stateMap: Record<string, unknown>,
  shardId: ShardId,
): void {
  for (const key of Object.keys(stateMap)) indexMap[key] = shardId;
  for (const key of Object.keys(indexMap)) {
    if (indexMap[key] === shardId && !(key in stateMap)) delete indexMap[key];
  }
}

/**
 * Decode the version an inbound CORE delegate's target runs on. The agent def
 * id is the one identifier that loads versioned code on the receiver, so a
 * CORE/FFI agent (qname-form) carries the snapshot; a closure / un-stamped
 * delegate has none (the caller falls back to the module's snapshot).
 */
function decodeDelegateSnapshot(agentDefId: AgentDefId): string | undefined {
  const decoded = decodeCoreAgentDefId(agentDefId);
  return decoded.kind === "qname" ? decoded.snapshot : undefined;
}

/**
 * Stamp the issuing shard's version on a snapshot-dependent (CORE / FFI)
 * delegate target's agent def id. qname-form (an agent) carries it; closures
 * inherit (left bare). CORE and FFI qname encodings are identical, so the CORE
 * path serves both.
 */
function stampDelegateSnapshot(agentDefId: AgentDefId, snapshot: string): AgentDefId {
  const decoded = decodeCoreAgentDefId(agentDefId);
  if (decoded.kind === "closure") return agentDefId;
  return encodeCoreAgentDefId({ ...decoded, snapshot });
}

/** Walk from the DelegateThread that owns `delegationId` up to the enclosing
 *  AgentThread, returning its delegationId (= the parent in the run tree). */
function findEnclosingAgentDelegation(
  state: State,
  delegationId: DelegationId,
): DelegationId | null {
  const senderThreadId = state.pendingDelegateOut[delegationId];
  if (senderThreadId === undefined) return null;
  let cursor: Thread | undefined = state.threads[senderThreadId];
  while (cursor !== undefined) {
    if (cursor.kind === "agent") return cursor.delegationId;
    if (cursor.parent === null) return null;
    cursor = state.threads[cursor.parent];
  }
  return null;
}
