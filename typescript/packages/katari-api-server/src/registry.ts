// In-memory registry of `MachineHandle`s, keyed by version.
//
// Concurrency model:
//   - Each version has a per-version `Mutex` ensuring that the load-from-storage
//     race (two concurrent acquires building two handles and stomping on each
//     other) cannot happen, and that `applyEvent` + `snapshots.upsert` runs
//     serialized for that version (see `runExclusive`).
//   - The handle cache is an LRU bounded by `maxLoaded` (env-configurable).
//     When eviction happens we DON'T just drop — the version's mutex is held
//     while the engine is in the middle of an `applyEvent`, so the LRU entry
//     can only be reaped when that mutex is free. That's enforced via
//     `disposeAfter`, which is called *after* `delete` returns.
//
// The registry intentionally does not snapshot before evicting: the api-server's
// `applyEvent`-wrapping path always upserts the snapshot inside the mutex
// before releasing it, so the storage row is already up to date when we drop
// the in-memory state.

import { Mutex } from "async-mutex";
import { LRUCache } from "lru-cache";
import { MachineHandle, type Logger } from "katari-runtime";
import type { Storage, VersionId } from "./storage/types.js";

export class MachineNotFound extends Error {
  constructor(public readonly versionId: VersionId) {
    super(`module version ${versionId} does not exist`);
  }
}

const DEFAULT_MAX_LOADED = 64;

export class MachineRegistry {
  private readonly cache: LRUCache<VersionId, MachineHandle>;
  private readonly mutexes = new Map<VersionId, Mutex>();
  private readonly inFlight = new Map<VersionId, Promise<MachineHandle>>();

  constructor(
    private readonly storage: Storage,
    private readonly logger: Logger,
    options: { maxLoaded?: number } = {},
  ) {
    const max = options.maxLoaded ?? DEFAULT_MAX_LOADED;
    this.cache = new LRUCache<VersionId, MachineHandle>({
      max,
      // We don't run a custom dispose: the snapshot is already persisted at
      // the time `applyEvent` finishes (the api-server upserts it inside the
      // version mutex), so dropping the in-memory state is safe. The mutex
      // map entry is left alone too — a re-acquire will refind it and either
      // reuse the still-allocated mutex or get a fresh one from
      // `getOrCreateMutex`.
    });
  }

  /**
   * Return (or create) the `Mutex` guarding all engine work on `versionId`.
   * Callers hold this mutex around `applyEvent + snapshots.upsert + state
   * updates` to avoid interleaved partial mutations.
   */
  getMutex(versionId: VersionId): Mutex {
    let mu = this.mutexes.get(versionId);
    if (mu === undefined) {
      mu = new Mutex();
      this.mutexes.set(versionId, mu);
    }
    return mu;
  }

  /**
   * Return the live `MachineHandle` for `versionId`, loading it from
   * storage on the first call. Throws `MachineNotFound` if the version
   * does not exist.
   *
   * Concurrency: the `inFlight` map collapses simultaneous acquires for
   * the same version to a single load Promise — the previous registry
   * had a documented race where N concurrent first-acquires built N
   * handles and stomped on each other.
   */
  async acquire(versionId: VersionId): Promise<MachineHandle> {
    const cached = this.cache.get(versionId);
    if (cached !== undefined) return cached;

    const inFlight = this.inFlight.get(versionId);
    if (inFlight !== undefined) return inFlight;

    const promise = this.loadHandle(versionId);
    this.inFlight.set(versionId, promise);
    try {
      const handle = await promise;
      this.cache.set(versionId, handle);
      return handle;
    } finally {
      this.inFlight.delete(versionId);
    }
  }

  private async loadHandle(versionId: VersionId): Promise<MachineHandle> {
    const moduleRow = await this.storage.modules.get(versionId);
    if (moduleRow === null) throw new MachineNotFound(versionId);

    const snap = await this.storage.snapshots.get(versionId);
    const handle =
      snap !== null
        ? MachineHandle.fromSnapshot(moduleRow.irModule, snap, this.logger)
        : MachineHandle.create(moduleRow.irModule, this.logger);
    this.logger.log("info", "machine loaded", {
      versionId,
      fromSnapshot: snap !== null,
    });
    return handle;
  }

  /**
   * Drop the in-memory machine for `versionId`. Used after a poison event
   * or when the api-server wants to free memory; the next `acquire` will
   * re-load (or rebuild) it.
   *
   * Safe to call while the version's mutex is held by the calling
   * code path — the LRU `delete` is synchronous and only drops the
   * cache entry; the mutex itself is preserved (a future re-acquire
   * keeps using the same mutex instance, which is fine because the
   * underlying engine is rebuilt fresh).
   */
  evict(versionId: VersionId): void {
    if (this.cache.delete(versionId)) {
      this.logger.log("info", "machine evicted", { versionId });
    }
  }

  /**
   * Replace the cached handle for `versionId` with a freshly-rebuilt one.
   * Used by AgentService.versionedRollback to swap the live in-memory state
   * for a snapshot-restored copy after a RecoverableEngineError leaves the
   * old engine state inconsistent. Caller MUST hold the version's mutex
   * around this — otherwise concurrent reads can briefly see the old
   * (poisoned) handle.
   */
  replaceHandle(versionId: VersionId, handle: MachineHandle): void {
    this.cache.set(versionId, handle);
    this.logger.log("debug", "machine handle replaced", { versionId });
  }

  /** For tests / debugging. */
  isLoaded(versionId: VersionId): boolean {
    return this.cache.has(versionId);
  }
}
