// CoreModule: the engine as a warm, self-contained, per-project module.
//
// Phase E makes CORE a warm per-project actor that owns its own transaction
// and persistence — no host-driven load/persist tick anymore. The flat
// per-snapshot State is split into per-agent-instance shards (a shard IS a
// State scoped to one agent: its threads / scopes / closures + its own local
// routing maps). CoreModule holds, warm in memory across quanta:
//
//   - `shardCache`   — the shards it has touched (a shard stays resident until
//                      it completes; the DB is a write-through mirror)
//   - `projectIndex` — the project-local routing table mapping a delegation /
//                      escalation id to the shard that must handle an event
//   - `irCache`      — snapshot → IR (a shard runs the version in its
//                      `currentSnapshot`; getIR resolves it once, memoized)
//
// All cross-shard routing reduces to an index lookup (docs/2026-05-30-phase-e-
// actor-host.md §2/§3, verified against the engine's escalate path):
//
//   delegate      → new shard (shardId = the new delegation id)
//   delegateAck   → index.pendingDelegateOut[delegationId]
//   terminate     → index.delegations[delegationId]
//   terminateAck  → index.pendingDelegateOut[delegationId]
//   escalate      → index.pendingDelegateOut[delegationId]   (the delegate issuer)
//   escalateAck   → index.escalationOwners[escalationId]
//
// One `feed` is one quantum: open a tx, route, load-on-miss (cache otherwise),
// apply, persist the touched shard (with persist-time string promotion) or
// delete it if it completed, write back the index — then commit. The project
// actor serializes feeds per project, so the warm caches need no internal
// locking; per-shard concurrency is a later mutex-granularity change.
//
// The snapshot a shard runs is CORE-private state: it lives in the shard's
// `currentSnapshot` (and `engine_shards.current_snapshot`), NOT on the
// protocol `delegations` table. An inbound delegate carries the version to run
// on inside its (bus-opaque) agent def id; CORE reads it to pick the new
// shard's IR and stamps it back onto outbound CORE/FFI delegate targets.

import {
  agentDefIdClosureRef,
  agentDefIdSnapshot,
  decodeCoreAgentDefId,
  encodeCoreAgentDefId,
  stampAgentDefIdSnapshot,
} from "../agent-def-id.js";
import { applyEvent, createState } from "../engine/apply.js";
import {
  decodeClosureBlob,
  materializeClosure,
  type PutClosureBytes,
  serializeClosure,
  serializeClosuresInValue,
} from "../engine/closure-codec.js";
import { CORE_ENDPOINT, type Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import type { DelegationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import { emptyProjectIndex, type ProjectIndex, type ShardId } from "../engine/shard.js";
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
import type { CoreStorage, CoreTxStores } from "./storage.js";

export type CoreModuleOptions = {
  /** Self endpoint (default {@link CORE_ENDPOINT}). New shards adopt it. */
  endpoint?: Endpoint;
  /** Project the shards belong to (value refs + shard storage are project-scoped). */
  projectId: string;
  /** Transaction provider — CoreModule opens one tx per quantum. */
  storage: CoreStorage;
  /**
   * Resolve a snapshot id to its IR. A shard runs the version recorded in its
   * `currentSnapshot`; the host backs this with the snapshots table so one
   * CoreModule runs agents across snapshots. Memoized internally.
   */
  getIR: (snapshot: string) => Promise<IRModule>;
  logger: Logger;
  /** Byte threshold above which an inline string is promoted to a ref. */
  promotionThreshold?: number;
};

type ShardEntry = { state: State; currentSnapshot: string };
type DelegatePayload = Extract<ExternalEvent["payload"], { kind: "delegate" }>;

export class CoreModule implements Module {
  readonly endpoint: Endpoint;
  private readonly projectId: string;
  private readonly storage: CoreStorage;
  private readonly getIRFn: (snapshot: string) => Promise<IRModule>;
  private readonly logger: Logger;
  private readonly promotionThreshold: number;

  /** Shards resident in memory (warm across quanta; DB is a write-through mirror). */
  private readonly shardCache = new Map<ShardId, ShardEntry>();
  /** Project routing index (warm; lazily loaded, written through every quantum). */
  private projectIndex: ProjectIndex = emptyProjectIndex();
  private indexLoaded = false;
  /** snapshot → IR memo. */
  private readonly irCache = new Map<string, IRModule>();

  constructor(opts: CoreModuleOptions) {
    this.endpoint = opts.endpoint ?? CORE_ENDPOINT;
    this.projectId = opts.projectId;
    this.storage = opts.storage;
    this.getIRFn = opts.getIR;
    this.logger = opts.logger;
    this.promotionThreshold = opts.promotionThreshold ?? DEFAULT_PROMOTE_THRESHOLD_BYTES;
  }

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    return this.storage.withTransaction(async (tx) => {
      await this.ensureIndex(tx);

      if (event.payload.kind === "delegateAck" || event.payload.kind === "terminateAck") {
        // Drop the audit row BEFORE applyEvent so a sub-delegate emitted during
        // apply doesn't race the parent's row delete.
        await tx.delegations.delete(event.payload.delegationId);
      }

      const shardId = this.routeToShard(event);
      if (shardId === undefined) {
        // A terminate for a delegation with no live shard = it already
        // finished (e.g. a root whose entry was missing errored before
        // spawning). Ack immediately so the canceller (a DelegateThread, or
        // the API run via terminateAck → terminal `error`) can settle, rather
        // than waiting forever for a shard that will never reply.
        if (event.payload.kind === "terminate") {
          return {
            outbound: [
              {
                from: this.endpoint,
                to: event.from,
                payload: { kind: "terminateAck", delegationId: event.payload.delegationId },
              },
            ],
          };
        }
        this.logger.log("debug", "core: event for unknown shard, dropping", {
          kind: event.payload.kind,
        });
        return { outbound: [] };
      }
      // An inbound CORE delegate carries the version to run on in its agent def
      // id; a new shard adopts it. A closure-ref target instead materializes its
      // captured env from the value store (the snapshot rides in the blob).
      // (Un-stamped qname delegates are an invariant violation in production —
      // every such target is stamped by API / CORE / FFI — so getOrLoadShard
      // rejects them loudly.)
      const delegatePayload = event.payload.kind === "delegate" ? event.payload : undefined;
      const shard = await this.getOrLoadShard(tx, shardId, delegatePayload);
      if (shard === null) {
        this.logger.log("debug", "core: no shard for event, dropping", {
          kind: event.payload.kind,
          shardId,
        });
        return { outbound: [] };
      }

      let result: Awaited<ReturnType<typeof applyEvent>>;
      try {
        result = await applyEvent(shard.state, event, this.makeFetchRef(tx.values));
      } catch (err) {
        // applyEvent mutates state in place, so an irrecoverable throw leaves
        // this warm shard half-mutated. Evict it (the per-feed tx will roll
        // back) so the next feed reloads a clean copy from the DB rather than
        // reusing the poisoned in-memory state.
        this.shardCache.delete(shardId);
        throw err;
      }
      shard.state = result.state;
      for (const log of result.logs) {
        this.logger.log(log.level, log.message, log.context);
      }

      this.reconcileIndex(shardId, shard.state);
      // A shard with no live threads has finished — delete it (no replay → no
      // retention) and purge its index entries.
      if (shard.state.threadCount === 0) {
        this.shardCache.delete(shardId);
        this.purgeIndexForShard(shardId);
        await tx.shards.delete(this.projectId, shardId);
      } else {
        await this.persistShard(tx, shardId, shard.state, shard.currentSnapshot);
      }
      await tx.projectIndex.upsert(this.projectId, this.projectIndex);

      const outbound = result.outbound as ExternalEvent[];
      for (const ev of outbound) {
        if (ev.payload.kind === "delegate") {
          // Freeze any escaping machine-local closure (the target or an arg)
          // into a content ref BEFORE it crosses the bus — the receiving shard
          // cannot resolve the issuer's local closure id space. Done first so
          // the snapshot stamp below sees the final (closure-ref) target.
          await this.serializeOutboundClosures(
            tx.values,
            ev.payload,
            shard.state,
            shard.currentSnapshot,
          );
          // The agent def id is the only identifier that loads versioned code
          // on the receiver, so it carries the issuing shard's snapshot — but
          // ONLY for snapshot-dependent modules (CORE agents run versioned IR,
          // FFI picks the per-snapshot sidecar). ENV / API are snapshot-
          // independent (common builtins / run management) → left bare. A
          // closure ref carries its snapshot in its blob (stamp is a no-op).
          const toSnapshotDependent =
            ev.to === shard.state.selfEndpoint || ev.to === shard.state.ffiTargetEndpoint;
          if (toSnapshotDependent) {
            ev.payload.agentDefId = stampAgentDefIdSnapshot(
              ev.payload.agentDefId,
              shard.currentSnapshot,
            );
          }
          await this.persistOutboundDelegate(tx.delegations, shard.state, ev, ev.payload);
        }
      }
      return { outbound };
    });
  }

  // ─── Warm-state helpers ─────────────────────────────────────────────────

  private async ensureIndex(tx: CoreTxStores): Promise<void> {
    if (this.indexLoaded) return;
    this.projectIndex = (await tx.projectIndex.get(this.projectId)) ?? emptyProjectIndex();
    this.indexLoaded = true;
  }

  private async resolveIR(snapshot: string): Promise<IRModule> {
    const cached = this.irCache.get(snapshot);
    if (cached !== undefined) return cached;
    const ir = await this.getIRFn(snapshot);
    this.irCache.set(snapshot, ir);
    return ir;
  }

  /** Fetch a ref's bytes — threaded into applyEvent so concat / format / etc.
   *  can materialize ref operands. `undefined` when no value store is wired. */
  private makeFetchRef(valueStore: ValueStore | null): RefFetcher | undefined {
    if (valueStore === null) return undefined;
    const projectId = this.projectId;
    return async (rep: RefRep): Promise<Uint8Array> => {
      const bytes = await valueStore.fetch(projectId, rep.module, rep.id);
      if (bytes === null) {
        throw new Error(`core.materialize: ref ${rep.module}/${rep.id} not found in value store`);
      }
      return bytes;
    };
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
    tx: CoreTxStores,
    shardId: ShardId,
    delegatePayload: DelegatePayload | undefined,
  ): Promise<ShardEntry | null> {
    const cached = this.shardCache.get(shardId);
    if (cached !== undefined) return cached;
    const loaded = await tx.shards.get(this.projectId, shardId);
    if (loaded !== null) {
      const ir = await this.resolveIR(loaded.currentSnapshot);
      const entry: ShardEntry = {
        state: deserialize(ir, decryptCheckpoint(loaded.checkpoint)),
        currentSnapshot: loaded.currentSnapshot,
      };
      this.shardCache.set(shardId, entry);
      return entry;
    }
    if (delegatePayload === undefined) return null;

    // A closure that escaped its home shard: materialize its frozen captured
    // env into a fresh shard, then rewrite the target to the new (local)
    // closure id so the standard closure:N dispatch runs the body
    // (runner.resolveDelegateTarget). The snapshot rides inside the blob.
    const closureRef = agentDefIdClosureRef(delegatePayload.agentDefId);
    if (closureRef !== undefined) {
      if (tx.values === null) {
        throw new Error("core: closure-ref delegate but no value store wired to materialize it");
      }
      const content = decodeClosureBlob(await this.fetchClosureBytes(tx.values, closureRef));
      const ir = await this.resolveIR(content.snapshot);
      const state = createState(ir, { selfEndpoint: this.endpoint });
      const newClosureId = materializeClosure(content, state);
      delegatePayload.agentDefId = encodeCoreAgentDefId({ kind: "closure", value: newClosureId });
      const entry: ShardEntry = { state, currentSnapshot: content.snapshot };
      this.shardCache.set(shardId, entry);
      return entry;
    }

    // A qname target: every one is stamped (API root / CORE child / FFI child).
    // An un-stamped one is an invariant violation — fail loudly, don't guess.
    const delegateSnapshot = agentDefIdSnapshot(delegatePayload.agentDefId);
    if (delegateSnapshot === undefined) {
      throw new Error(`core: un-stamped delegate ${shardId} — cannot resolve the snapshot to run`);
    }
    const ir = await this.resolveIR(delegateSnapshot);
    const entry: ShardEntry = {
      state: createState(ir, { selfEndpoint: this.endpoint }),
      currentSnapshot: delegateSnapshot,
    };
    this.shardCache.set(shardId, entry);
    return entry;
  }

  /** Freeze every escaping machine-local closure in an outbound delegate (its
   *  target id and every arg) into a content ref. The receiver cannot resolve
   *  the issuer's local closure id space, so a closure crosses as a blob ref. */
  private async serializeOutboundClosures(
    valueStore: ValueStore | null,
    payload: DelegatePayload,
    state: State,
    snapshot: string,
  ): Promise<void> {
    const putBytes = this.makePutClosureBytes(valueStore);
    const decoded = decodeCoreAgentDefId(payload.agentDefId);
    if (decoded.kind === "closure") {
      const ref = await serializeClosure(state, decoded.value, snapshot, putBytes);
      payload.agentDefId = encodeCoreAgentDefId({ kind: "closureRef", ref });
    }
    for (const [label, value] of Object.entries(payload.args)) {
      payload.args[label] = await serializeClosuresInValue(value, state, snapshot, putBytes);
    }
  }

  /** A closure-blob writer (owner = core, semanticKind = closure). Throws if no
   *  value store is wired AND a closure actually needs freezing. */
  private makePutClosureBytes(valueStore: ValueStore | null): PutClosureBytes {
    const projectId = this.projectId;
    return async (bytes: Uint8Array): Promise<RefRep> => {
      if (valueStore === null) {
        throw new Error("core: a closure is crossing a shard boundary but no value store is wired");
      }
      const result = await valueStore.putComplete({
        projectId,
        owner: "core",
        bytes,
        semanticKind: "closure",
      });
      return { kind: "ref", module: "core", id: result.id, hash: result.hash, size: result.size };
    };
  }

  /** Fetch a closure blob's bytes; throws if the ref is missing. */
  private async fetchClosureBytes(valueStore: ValueStore, ref: RefRep): Promise<Uint8Array> {
    const bytes = await valueStore.fetch(this.projectId, ref.module, ref.id);
    if (bytes === null) {
      throw new Error(`core: closure blob ${ref.module}/${ref.id} not found in value store`);
    }
    return bytes;
  }

  private async persistShard(
    tx: CoreTxStores,
    shardId: ShardId,
    state: State,
    currentSnapshot: string,
  ): Promise<void> {
    // Promote large inline strings to refs BEFORE encrypting (promotion handles
    // strings, encryption handles secrets — disjoint). Keeps a heavy AI
    // conversation out of the shard checkpoint.
    const checkpoint = serialize(state);
    const promoted =
      tx.values !== null
        ? await promoteCheckpoint(
            checkpoint,
            this.makePromoteText(tx.values),
            this.promotionThreshold,
          )
        : checkpoint;
    await tx.shards.upsert({
      projectId: this.projectId,
      shardId,
      currentSnapshot,
      status: "active",
      checkpoint: encryptCheckpoint(promoted),
    });
  }

  /** Promote one inline string to an owner=core ref by writing its bytes. */
  private makePromoteText(valueStore: ValueStore): (text: string) => Promise<RefRep> {
    const projectId = this.projectId;
    return async (text: string): Promise<RefRep> => {
      const result = await valueStore.putComplete({
        projectId,
        owner: "core",
        bytes: new TextEncoder().encode(text),
        semanticKind: "string",
      });
      return { kind: "ref", module: "core", id: result.id, hash: result.hash, size: result.size };
    };
  }

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

  /** Shard state for tests / debug. `undefined` if not resident. */
  shardState(shardId: ShardId): State | undefined {
    return this.shardCache.get(shardId)?.state;
  }

  /** Routing index for tests / debug. Empty once every shard has completed. */
  get currentProjectIndex(): ProjectIndex {
    return this.projectIndex;
  }

  // ─── Audit helpers ─────────────────────────────────────────────────────

  private async persistOutboundDelegate(
    delegations: DelegationStore,
    state: State,
    ev: ExternalEvent,
    payload: Extract<ExternalEvent["payload"], { kind: "delegate" }>,
  ): Promise<void> {
    const parentDelegationId = findEnclosingAgentDelegation(state, payload.delegationId);
    const rootDelegationId =
      parentDelegationId === null
        ? payload.delegationId
        : ((await delegations.getRoot(parentDelegationId)) ?? payload.delegationId);
    const now = new Date().toISOString();
    await delegations.insert({
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

/** Backwards-compatible alias — the audit store is unused by default. */
export { NULL_DELEGATION_STORE };
