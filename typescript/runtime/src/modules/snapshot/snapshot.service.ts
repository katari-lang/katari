import { isDeepStrictEqual } from "node:util";
import { db } from "../../db/client.js";
import { NotFoundError, UnprocessableEntityError } from "../../lib/errors.js";
import { type ModuleHash, toModuleHash } from "../../runtime/ids.js";
import { snapshotRepository } from "./snapshot.repository.js";
import type { DeploySnapshotInput } from "./snapshot.schema.js";

export const snapshotService = {
  /**
   * Deploy a new snapshot, atomically, in two passes so the result never depends on module key order:
   *   1. store every inlined module IR (content-addressed, idempotent);
   *   2. build the manifest, requiring every referenced hash to resolve (held or just-stored).
   * A hash that is neither held nor inlined is rejected (422) — the manifest must be fully resolvable.
   *
   * The CLI's hash is trusted as an opaque content key (the runtime does not re-hash; see
   * docs/2026-06-19-per-module-snapshot.md §5). The one integrity check available cheaply is that an
   * inlined IR for an already-held hash matches the stored bytes; a mismatch means a miscomputed hash
   * that would otherwise silently corrupt the store, so it is rejected (422) instead of dropped.
   */
  async deploy(projectId: string, input: DeploySnapshotInput) {
    return db.transaction(async (tx) => {
      // Lock the project row up front so concurrent deploys serialize and `head` advances in commit
      // order rather than last-writer-wins.
      const [project] = await snapshotRepository.findProjectForUpdate(tx, projectId);
      if (!project) throw new NotFoundError(`Project ${projectId} not found.`);

      const held = await snapshotRepository.existingModuleHashes(tx, projectId);
      const entries = Object.entries(input.modules);

      // Pass 1: store every inlined module. Order-independent — a later entry may reference a hash an
      // earlier entry inlines, and both orderings resolve identically.
      for (const [moduleName, entry] of entries) {
        if (!entry.ir) continue;
        const hash = toModuleHash(entry.hash);
        if (held.has(entry.hash)) {
          const [existing] = await snapshotRepository.findModuleIr(tx, projectId, hash);
          if (existing && !isDeepStrictEqual(existing.ir, entry.ir)) {
            throw new UnprocessableEntityError(
              `Module "${moduleName}" inlines IR for hash ${entry.hash} that differs from the stored module with the same hash; the hash does not address its content.`,
            );
          }
          continue;
        }
        await snapshotRepository.insertModule(tx, projectId, hash, entry.ir);
        held.add(entry.hash);
      }

      // Pass 2: build the manifest, now that every inlined hash is held.
      const manifest: Record<string, ModuleHash> = {};
      for (const [moduleName, entry] of entries) {
        if (!held.has(entry.hash)) {
          throw new UnprocessableEntityError(
            `Module "${moduleName}" references hash ${entry.hash}, which the runtime does not hold and was not inlined.`,
          );
        }
        manifest[moduleName] = toModuleHash(entry.hash);
      }

      const [snapshot] = await snapshotRepository.insertSnapshot(
        tx,
        projectId,
        manifest,
        input.sidecarBundle ?? null,
        input.message,
      );
      if (!snapshot) throw new Error("snapshot insert returned no row");
      await snapshotRepository.setHead(tx, projectId, snapshot.id);
      return { id: snapshot.id };
    });
  },

  /** The currently-live snapshot, or a null-`id` placeholder when nothing is deployed yet. The CLI
   *  diffs its fresh build against this `modules` manifest before uploading. */
  async head(projectId: string) {
    const [project] = await snapshotRepository.findProject(db, projectId);
    if (!project) throw new NotFoundError(`Project ${projectId} not found.`);

    const empty = { id: null, message: null, modules: {}, createdAt: null } as const;
    if (!project.headSnapshotId) return empty;

    const [snapshot] = await snapshotRepository.findSnapshot(db, projectId, project.headSnapshotId);
    return snapshot ?? empty;
  },

  async list(projectId: string) {
    const [project] = await snapshotRepository.findProject(db, projectId);
    if (!project) throw new NotFoundError(`Project ${projectId} not found.`);
    return snapshotRepository.list(db, projectId);
  },

  async getById(projectId: string, snapshotId: string) {
    const [snapshot] = await snapshotRepository.findSnapshot(db, projectId, snapshotId);
    if (!snapshot) throw new NotFoundError(`Snapshot ${snapshotId} not found.`);
    return snapshot;
  },
};
