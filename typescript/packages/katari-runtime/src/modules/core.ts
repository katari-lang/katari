// CoreModule: the engine as a warm, self-contained, per-project module.
//
// Phase E makes CORE a warm per-project actor that owns its own transaction
// and persistence. The flat per-snapshot State is split into per-agent-instance
// shards (a shard IS a State scoped to one agent: its threads / scopes /
// closures + its own local routing maps). CoreModule holds, warm in memory:
//
//   - `shardCache`   — the shards it has touched (resident until they complete)
//   - `projectIndex` — the project-local routing table mapping a bus id
//                      (delegation / escalation) to the SHARD that handles it
//   - `irCache`      — snapshot → IR
//
// Entity model (docs/2026-06-01-entity-model.md): a shard IS an entity, keyed by
// a freshly minted entity id `E` (shardId = E), distinct from the summoning
// delegation `D` (which stays off the shard key and rides the bus). CORE never
// reads another module's tables: it mints `E` and writes its `entities` row from
// the inbound `delegate` event + ambient context ALONE. Ref ownership is
// value-driven — a completing shard DETACHES its escaping refs (`owner = NULL`)
// and self-deletes its entity (the rest cascade); the parent CLAIMS the result
// value's refs to its own entity on the ack. CORE deletes only entities (its
// own) + the delegations IT issued (on their acks); it never touches an entity
// or delegation owned by another module.
//
// Routing (the warm index maps bus id → shard E):
//   delegate      → a freshly minted shard E (the receiver mints it)
//   delegateAck   → index.pendingDelegateOut[delegationId]   (the issuer shard)
//   terminateAck  → index.pendingDelegateOut[delegationId]
//   escalate      → index.pendingDelegateOut[delegationId]   (the delegate issuer)
//   terminate     → index.delegations[delegationId]          (the shard running D)
//   escalateAck   → index.escalationOwners[escalationId]      (the raiser shard)

import { agentDefIdClosure, agentDefIdSnapshot } from "../agent-def-id.js";
import { applyEvent, createState } from "../engine/apply.js";
import { CORE_ENDPOINT, type Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import { createEntityId, type EntityId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import type { Scope } from "../engine/scope.js";
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
import type { RefFetcher, RefPutter } from "../engine/step-ctx.js";
import {
  type CoreStore,
  dropOwned,
  emptyStore,
  reachableFromClosures,
  reownEscaping,
  restoreOwned,
  snapshotOwned,
} from "../engine/store.js";
import {
  collectClosures,
  collectRefs,
  type RefRep,
  recordEntries,
  type Value,
} from "../engine/value.js";
import type { IRModule } from "../ir/types.js";
import type { Module } from "../module.js";
import type { PersistedClosure, PersistedScope } from "../storage/scope-store.js";
import type { ValueStore } from "../storage/value-store.js";
import {
  decryptValueTree,
  type EncryptedValue,
  encryptValueRecord,
  encryptValueTree,
} from "../value-secret-codec.js";
import { type EntityModule, type EntityStore, NULL_ENTITY_STORE } from "./entity-store.js";
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
  /**
   * The CORE-global scope + closure store: one per project actor, shared across
   * all the project's shards (docs/2026-06-08-scope-closure-entity.md). Warm in
   * memory; a closure call resolves its captured scope here without any
   * serialize. Scopes / closures are entity-owned; ascent re-owns escaping ones
   * to the parent on an ack, and the entity-release cascade drops the rest. The
   * ScopeStore (when wired) is its write-through mirror for crash recovery.
   */
  private readonly globalStore: CoreStore = emptyStore();
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
      const payload = event.payload;

      // ── Issuer side: a child we delegated has reported its result ─────────
      if (payload.kind === "delegateAck" || payload.kind === "terminateAck") {
        if (payload.kind === "delegateAck") {
          // Value-driven ascent: the result value carries the escaping closures
          // (and their captured scope chains) + ref ids; the child detached them
          // to owner=NULL on its terminal. Claim them to the issuing shard's
          // entity — closures / scopes in the warm global store, refs in the
          // value store. No child lookup, no parent id on the bus.
          const issuerEntity = this.projectIndex.pendingDelegateOut[payload.delegationId];
          if (issuerEntity !== undefined) {
            const capturedRefs = reownEscaping(
              this.globalStore,
              payload.value,
              null,
              issuerEntity as unknown as EntityId,
            );
            if (tx.values !== null) {
              const seed = [...collectRefs(payload.value), ...capturedRefs];
              if (seed.length > 0) {
                await tx.values.reownRefs(this.projectId, null, issuerEntity, seed);
              }
            }
            await this.persistOwnedScopes(tx, issuerEntity as unknown as EntityId);
          }
        }
        // Drop the request edge now the result is in. BEFORE applyEvent so a
        // sub-delegate emitted during apply can't race the delete.
        await tx.entities.deleteDelegation(payload.delegationId);
      }

      // ── Resolve the shard: mint a fresh entity for a new delegate; else the
      //    warm index resolves bus D → shard E ─────────────────────────────
      const shardId =
        payload.kind === "delegate"
          ? (createEntityId() as unknown as ShardId)
          : this.routeToShard(event);
      if (shardId === undefined) {
        // A terminate for a delegation with no live shard = it already finished.
        // Ack immediately so the canceller can settle.
        if (payload.kind === "terminate") {
          return {
            outbound: [
              {
                from: this.endpoint,
                to: event.from,
                payload: { kind: "terminateAck", delegationId: payload.delegationId },
              },
            ],
          };
        }
        this.logger.log("debug", "core: event for unknown shard, dropping", { kind: payload.kind });
        return { outbound: [] };
      }

      const delegatePayload = payload.kind === "delegate" ? payload : undefined;
      // Capture the requested agent def id before getOrLoadShard rewrites a
      // closure target — the entity row records what was asked for.
      const requestedAgentDefId = delegatePayload?.agentDefId;
      const shard = await this.getOrLoadShard(tx, shardId, delegatePayload);
      if (shard === null) {
        this.logger.log("debug", "core: no shard for event, dropping", {
          kind: payload.kind,
          shardId,
        });
        return { outbound: [] };
      }

      // ── Receiver side: a freshly summoned entity begins processing — mint its
      //    entity row from the bus event + ambient context ALONE ────────────
      if (delegatePayload !== undefined) {
        const now = new Date().toISOString();
        await tx.entities.insertEntity({
          id: shardId as unknown as EntityId,
          delegationId: delegatePayload.delegationId,
          module: "core",
          agentDefId: requestedAgentDefId ?? null,
          args: encryptValueRecord(recordEntries(delegatePayload.argument)),
          state: "running",
          createdAt: now,
          updatedAt: now,
        });
      }

      // ── Raiser side: an answered escalation — drop the raiser's own row ───
      if (payload.kind === "escalateAck") {
        await tx.entities.deleteEscalation(payload.escalationId);
      }

      // Snapshot this entity's owned scope/closure slice so a poisoned quantum
      // (an irrecoverable throw mid-apply) can be rolled back: the global store
      // is mutated in place and is NOT per-shard, so eviction alone would leave
      // its half-mutations visible to sibling shards.
      const ownedSlice = snapshotOwned(this.globalStore, shardId as unknown as EntityId);
      let result: Awaited<ReturnType<typeof applyEvent>>;
      try {
        result = await applyEvent(
          shard.state,
          this.globalStore,
          event,
          this.makeFetchRef(tx.values),
          // Refs produced inside this shard's quantum are owned by the shard's
          // entity (= shardId = E); the ascent detaches/keeps them at terminal.
          this.makePutRef(tx.values, shardId),
        );
      } catch (err) {
        // applyEvent mutates state + the global store in place; an irrecoverable
        // throw leaves both half-mutated. Restore this entity's owned slice +
        // evict the shard (the per-feed tx rolls back the DB) so the next feed
        // reloads a clean copy.
        restoreOwned(this.globalStore, shardId as unknown as EntityId, ownedSlice);
        this.shardCache.delete(shardId);
        throw err;
      }
      shard.state = result.state;
      for (const log of result.logs) {
        this.logger.log(log.level, log.message, log.context);
      }

      const outbound = result.outbound as ExternalEvent[];

      this.reconcileIndex(shardId, shard.state);
      if (shard.state.threadCount === 0) {
        // Terminal: detach the escaping closures + their captured scope chains
        // (owner→NULL in the global store) and the escaping refs (owner→NULL in
        // the value store) so they survive the entity delete + can be claimed by
        // the parent; then cascade-drop everything the entity still owns and
        // self-delete the entity (its remaining refs + raised escalations cascade
        // away). The delegation is deleted by OUR parent on its ack — not here.
        await this.detachEscaping(tx, shardId, outbound);
        dropOwned(this.globalStore, shardId as unknown as EntityId);
        await this.dropOwnedScopes(tx, shardId as unknown as EntityId);
        await tx.entities.deleteEntity(shardId as unknown as EntityId);
        if (tx.values !== null) await tx.values.reapFreedBlobs(this.projectId);
        this.shardCache.delete(shardId);
        this.purgeIndexForShard(shardId);
        await tx.shards.delete(this.projectId, shardId);
      } else {
        await this.persistShard(tx, shardId, shard.state, shard.currentSnapshot);
        await this.persistOwnedScopes(tx, shardId as unknown as EntityId);
      }
      await tx.projectIndex.upsert(this.projectId, this.projectIndex);

      for (const ev of outbound) {
        if (ev.payload.kind === "delegate") {
          // The delegate target is already in external form: the engine
          // (DelegateThread) stamped the issuing shard's snapshot onto CORE/FFI
          // targets, and an agent VALUE target carries its own snapshot. ENV is
          // snapshot-independent (left bare), a closure ref carries its snapshot
          // in its blob — both correct without any module-level fix-up.
          // Issuer: write the request edge (parent = THIS shard's entity).
          await this.writeOutboundDelegation(tx.entities, shard.state, shardId, ev, ev.payload);
        } else if (ev.payload.kind === "escalate") {
          // Raiser: write the live escalation (owner = THIS shard's entity).
          await this.writeOutboundEscalation(tx.entities, shardId, ev.payload);
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

  /** The shard an event must be handled in (non-delegate; delegate mints fresh).
   *  `undefined` = unknown id. */
  private routeToShard(event: ExternalEvent): ShardId | undefined {
    const p = event.payload;
    switch (p.kind) {
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
      const state = deserialize(ir, await decryptCheckpoint(loaded.checkpoint));
      // CORE-private fields (not in the checkpoint) — re-supply them. `selfEntity`
      // = the shard id (= E); `snapshot` = the recorded code version.
      state.snapshot = loaded.currentSnapshot;
      state.selfEntity = shardId as unknown as EntityId;
      // Cold load: pull this entity's owned scopes / closures (+ the closures its
      // values reference, transitively) into the warm global store.
      await this.loadEntityScopes(tx, shardId as unknown as EntityId);
      const entry: ShardEntry = { state, currentSnapshot: loaded.currentSnapshot };
      this.shardCache.set(shardId, entry);
      return entry;
    }
    if (delegatePayload === undefined) return null;

    // The snapshot the fresh shard runs:
    //   - closure delegate (a cross-entity callback, e.g. FFI invoking a closure
    //     it received): the snapshot rides on the closure record in the global
    //     store. Cold start may need to load the record first.
    //   - qname delegate: stamped on the target (API root / CORE / FFI child).
    const closureId = agentDefIdClosure(delegatePayload.agentDefId);
    let snapshot: string;
    if (closureId !== undefined) {
      if (this.globalStore.closures[closureId] === undefined) {
        await this.loadClosureChain(tx, closureId);
      }
      const record = this.globalStore.closures[closureId];
      if (record === undefined) {
        throw new Error(`core: closure ${closureId} not found for delegate ${shardId}`);
      }
      snapshot = record.snapshot;
    } else {
      const stamped = agentDefIdSnapshot(delegatePayload.agentDefId);
      if (stamped === undefined) {
        throw new Error(
          `core: un-stamped delegate ${shardId} — cannot resolve the snapshot to run`,
        );
      }
      snapshot = stamped;
    }
    const ir = await this.resolveIR(snapshot);
    const entry: ShardEntry = {
      state: createState(ir, {
        selfEndpoint: this.endpoint,
        snapshot,
        selfEntity: shardId as unknown as EntityId,
      }),
      currentSnapshot: snapshot,
    };
    this.shardCache.set(shardId, entry);
    return entry;
  }

  /** A blob writer (owner = this shard's entity). Tags the produced ref with the
   *  caller's `semanticKind`, owned by the producing shard's entity
   *  (`ownerEntityId = shardId = E`). */
  private makePutRef(valueStore: ValueStore | null, ownerEntityId: string): RefPutter {
    const projectId = this.projectId;
    return async (bytes, semanticKind, refsTo, contentType): Promise<RefRep> => {
      if (valueStore === null) {
        throw new Error("core: a blob needs persisting but no value store is wired");
      }
      const result = await valueStore.putComplete({
        projectId,
        owner: "core",
        bytes,
        semanticKind,
        ownerEntityId,
        refsTo,
        contentType,
      });
      return { kind: "ref", module: "core", id: result.id, hash: result.hash, size: result.size };
    };
  }

  private async persistShard(
    tx: CoreTxStores,
    shardId: ShardId,
    state: State,
    currentSnapshot: string,
  ): Promise<void> {
    // Promote large inline strings to refs BEFORE encrypting (promotion handles
    // strings, encryption handles secrets — disjoint).
    const checkpoint = serialize(state);
    const promoted =
      tx.values !== null
        ? await promoteCheckpoint(
            checkpoint,
            this.makePromoteText(tx.values, shardId),
            this.promotionThreshold,
          )
        : checkpoint;
    await tx.shards.upsert({
      projectId: this.projectId,
      shardId,
      currentSnapshot,
      status: "active",
      checkpoint: await encryptCheckpoint(promoted),
    });
  }

  /**
   * Detach a completed shard's ESCAPING resources (value-driven ascent). From
   * the outbound `delegateAck` value: the closures it carries + their captured
   * scope chains are re-owned from this shard's entity to NULL in the global
   * store (and persisted as in-transit rows), and the refs (the value's own +
   * those captured inside the escaping scopes) are re-owned to NULL in the value
   * store. The parent claims them all by the value it receives. Everything else
   * the shard owns is dropped by the entity-release cascade. A shard ending
   * without a `delegateAck` (terminate / unhandled throw) detaches nothing.
   */
  private async detachEscaping(
    tx: CoreTxStores,
    shardId: ShardId,
    outbound: ExternalEvent[],
  ): Promise<void> {
    const ack = outbound.find((ev) => ev.payload.kind === "delegateAck");
    if (ack === undefined || ack.payload.kind !== "delegateAck") return;
    const value = ack.payload.value;
    // Warm: re-own escaping closures + captured scope chains E → NULL; returns
    // the content refs captured inside those scopes.
    const capturedRefs = reownEscaping(
      this.globalStore,
      value,
      shardId as unknown as EntityId,
      null,
    );
    if (tx.values !== null) {
      const seed = [...collectRefs(value), ...capturedRefs];
      if (seed.length > 0) await tx.values.reownRefs(this.projectId, shardId, null, seed);
    }
    // Persist the now-NULL-owned (in-transit) escaping scopes / closures so the
    // parent's claim survives a crash in the (sub-second) ascent window.
    await this.persistDetached(tx, value);
  }

  // ─── Scope / closure persistence (write-through mirror of the global store) ──

  /** Persist the scopes + closures `entity` owns in the global store (the
   *  per-quantum write-through + a claim). No-op when no ScopeStore is wired. */
  private async persistOwnedScopes(tx: CoreTxStores, entity: EntityId): Promise<void> {
    if (tx.scopes == null) return;
    const scopes: PersistedScope[] = [];
    const closures: PersistedClosure[] = [];
    for (const sc of Object.values(this.globalStore.scopes)) {
      if (sc.owner === entity) scopes.push(serializePersistedScope(sc));
    }
    for (const c of Object.values(this.globalStore.closures)) {
      if (c.owner === entity) closures.push({ ...c });
    }
    if (scopes.length > 0 || closures.length > 0) {
      await tx.scopes.upsert(this.projectId, scopes, closures);
    }
  }

  /** Persist the escaping (now NULL-owned) scopes / closures `value` carries. */
  private async persistDetached(tx: CoreTxStores, value: Value): Promise<void> {
    if (tx.scopes == null) return;
    const { scopes: scopeIds, closures: closureIds } = reachableFromClosures(
      this.globalStore,
      collectClosures(value),
    );
    const scopes: PersistedScope[] = [];
    const closures: PersistedClosure[] = [];
    for (const id of scopeIds) {
      const sc = this.globalStore.scopes[id];
      if (sc !== undefined && sc.owner === null) scopes.push(serializePersistedScope(sc));
    }
    for (const id of closureIds) {
      const c = this.globalStore.closures[id];
      if (c !== undefined && c.owner === null) closures.push({ ...c });
    }
    if (scopes.length > 0 || closures.length > 0) {
      await tx.scopes.upsert(this.projectId, scopes, closures);
    }
  }

  /** Drop the scopes / closures `entity` owns from persistence (entity cascade). */
  private async dropOwnedScopes(tx: CoreTxStores, entity: EntityId): Promise<void> {
    if (tx.scopes == null) return;
    await tx.scopes.deleteOwned(this.projectId, entity);
  }

  /** Cold load: pull `entity`'s owned scopes / closures (+ the closures their
   *  values reference + the parent / captured scopes they chain to, transitively
   *  across owners) into the warm global store. */
  private async loadEntityScopes(tx: CoreTxStores, entity: EntityId): Promise<void> {
    if (tx.scopes == null) return;
    this.graftPersisted(await tx.scopes.loadOwned(this.projectId, entity));
    await this.loadTransitive(tx);
  }

  /** Cold load: pull a single closure + its captured scope chain (and nested
   *  closures) into the warm store (a closure callback after a restart). */
  private async loadClosureChain(
    tx: CoreTxStores,
    closureId: import("../engine/id.js").ClosureId,
  ): Promise<void> {
    if (tx.scopes == null) return;
    this.graftPersisted(await tx.scopes.loadByIds(this.projectId, [], [closureId]));
    await this.loadTransitive(tx);
  }

  /** Pull every still-missing scope (a loaded scope's `parentId`, a loaded
   *  closure's captured scope) + closure (referenced by a loaded scope value)
   *  into the warm store, until the reachable set is closed. */
  private async loadTransitive(tx: CoreTxStores): Promise<void> {
    if (tx.scopes == null) return;
    // Bounded: each round either loads new rows or stops. The cap guards against
    // a corrupt store that keeps reporting a missing id it can't supply.
    for (let round = 0; round < 10_000; round++) {
      const missingScopes = new Set<import("../engine/id.js").ScopeId>();
      const missingClosures = new Set<import("../engine/id.js").ClosureId>();
      for (const sc of Object.values(this.globalStore.scopes)) {
        if (sc.parentId !== null && this.globalStore.scopes[sc.parentId] === undefined) {
          missingScopes.add(sc.parentId);
        }
        for (const v of Object.values(sc.values)) {
          if (v !== undefined) {
            for (const cid of collectClosures(v)) {
              if (this.globalStore.closures[cid] === undefined) missingClosures.add(cid);
            }
          }
        }
      }
      for (const c of Object.values(this.globalStore.closures)) {
        if (this.globalStore.scopes[c.scopeId] === undefined) missingScopes.add(c.scopeId);
      }
      if (missingScopes.size === 0 && missingClosures.size === 0) return;
      const loaded = await tx.scopes.loadByIds(
        this.projectId,
        [...missingScopes],
        [...missingClosures],
      );
      if (loaded.scopes.length === 0 && loaded.closures.length === 0) return; // nothing more to resolve
      this.graftPersisted(loaded);
    }
  }

  /** Graft a loaded scope / closure set into the warm global store (decrypting
   *  captured secret values back to plaintext). Refs stay refs. */
  private graftPersisted(loaded: { scopes: PersistedScope[]; closures: PersistedClosure[] }): void {
    for (const sc of loaded.scopes) {
      this.globalStore.scopes[sc.id] = {
        id: sc.id,
        parentId: sc.parentId,
        owner: sc.owner,
        values: deserializeScopeValues(sc.values),
        ...(sc.ambientGenerics !== undefined ? { ambientGenerics: sc.ambientGenerics } : {}),
      };
    }
    for (const c of loaded.closures) {
      this.globalStore.closures[c.id] = { ...c };
    }
  }

  /** Promote one inline string to an owner=this-shard ref. */
  private makePromoteText(
    valueStore: ValueStore,
    ownerEntityId: string,
  ): (text: string) => Promise<RefRep> {
    const projectId = this.projectId;
    return async (text: string): Promise<RefRep> => {
      const result = await valueStore.putComplete({
        projectId,
        owner: "core",
        bytes: new TextEncoder().encode(text),
        semanticKind: "string",
        ownerEntityId,
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

  // ─── Execution-layer writes ────────────────────────────────────────────

  /** The module a delegate `to` endpoint targets (for the delegation's record). */
  private moduleOf(state: State, to: Endpoint): EntityModule {
    if (to === state.selfEndpoint) return "core";
    if (to === state.ffiTargetEndpoint) return "ffi";
    if (to === state.envTargetEndpoint) return "env";
    return "api";
  }

  /** Issuer: write the request edge for a delegate this shard emitted. The
   *  parent link is THIS shard's entity (`shardId = E`) — known locally; no
   *  cross-module read. */
  private async writeOutboundDelegation(
    entities: EntityStore,
    state: State,
    shardId: ShardId,
    ev: ExternalEvent,
    payload: Extract<ExternalEvent["payload"], { kind: "delegate" }>,
  ): Promise<void> {
    const now = new Date().toISOString();
    await entities.insertDelegation({
      id: payload.delegationId,
      parentEntityId: shardId as unknown as EntityId,
      targetModule: this.moduleOf(state, ev.to),
      agentDefId: payload.agentDefId,
      args: encryptValueRecord(recordEntries(payload.argument)),
      state: "running",
      createdAt: now,
      updatedAt: now,
    });
  }

  /** Raiser: write the live escalation this shard emitted (owner = its entity).
   *  Idempotent on escalationId so hop-by-hop forwarding doesn't duplicate it
   *  (the original raiser's row wins). */
  private async writeOutboundEscalation(
    entities: EntityStore,
    shardId: ShardId,
    payload: Extract<ExternalEvent["payload"], { kind: "escalate" }>,
  ): Promise<void> {
    await entities.insertEscalation({
      id: payload.escalationId,
      entityId: shardId as unknown as EntityId,
      agentDefId: payload.agentDefId,
      args: encryptValueRecord(recordEntries(payload.argument)),
      createdAt: new Date().toISOString(),
    });
  }
}

/** Encrypt a live scope into its at-rest row form (captured secrets → envelopes;
 *  refs / inline strings pass through — large strings were promoted at birth). */
function serializePersistedScope(scope: Scope): PersistedScope {
  const values: Record<number, EncryptedValue> = {};
  for (const [k, v] of Object.entries(scope.values)) {
    if (v !== undefined) values[Number(k)] = encryptValueTree(v);
  }
  return {
    id: scope.id,
    parentId: scope.parentId,
    owner: scope.owner,
    values,
    ...(scope.ambientGenerics !== undefined ? { ambientGenerics: scope.ambientGenerics } : {}),
  };
}

/** Inverse of {@link serializePersistedScope}'s value map (envelopes → secrets). */
function deserializeScopeValues(values: Record<number, EncryptedValue>): Record<number, Value> {
  const out: Record<number, Value> = {};
  for (const [k, v] of Object.entries(values)) out[Number(k)] = decryptValueTree(v);
  return out;
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

/** Backwards-compatible alias — the entity store is unused by default. */
export { NULL_ENTITY_STORE };
