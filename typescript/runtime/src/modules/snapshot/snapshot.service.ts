import { db } from "../../db/client.js";
import { NotFoundError, UnprocessableEntityError } from "../../lib/errors.js";
import { type ModuleHash, toModuleHash } from "../../runtime/ids.js";
import { snapshotRepository } from "./snapshot.repository.js";
import type { DeploySnapshotInput } from "./snapshot.schema.js";

export const snapshotService = {
  /**
   * Deploy a new snapshot. Atomically: store every inlined module IR (content-addressed, idempotent),
   * build the manifest from the request's complete module set, create the immutable snapshot, and
   * advance the project head. A module that references a hash the runtime neither holds nor inlines
   * is rejected (422) — the manifest must be fully resolvable.
   */
  async deploy(projectId: string, input: DeploySnapshotInput) {
    return db.transaction(async (tx) => {
      const [project] = await snapshotRepository.findProject(tx, projectId);
      if (!project) throw new NotFoundError(`Project ${projectId} not found.`);

      const held = await snapshotRepository.existingModuleHashes(tx, projectId);
      const manifest: Record<string, ModuleHash> = {};

      for (const [moduleName, entry] of Object.entries(input.modules)) {
        if (!held.has(entry.hash)) {
          if (!entry.ir) {
            throw new UnprocessableEntityError(
              `Module "${moduleName}" references hash ${entry.hash}, which the runtime does not hold and was not inlined.`,
            );
          }
          await snapshotRepository.insertModule(tx, projectId, toModuleHash(entry.hash), entry.ir);
          // A later module in this same deploy may reference the just-stored hash.
          held.add(entry.hash);
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
      return { snapshotId: snapshot.id };
    });
  },

  /** The currently-live snapshot's manifest, or a null head when nothing is deployed yet. The CLI
   *  diffs its fresh build against this before uploading. */
  async head(projectId: string) {
    const [project] = await snapshotRepository.findProject(db, projectId);
    if (!project) throw new NotFoundError(`Project ${projectId} not found.`);

    const empty = { snapshotId: null, message: null, modules: {}, createdAt: null } as const;
    if (!project.headSnapshotId) return empty;

    const [snapshot] = await snapshotRepository.findSnapshot(db, projectId, project.headSnapshotId);
    if (!snapshot) return empty;
    return {
      snapshotId: snapshot.id,
      message: snapshot.message,
      modules: snapshot.modules,
      createdAt: snapshot.createdAt,
    };
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
