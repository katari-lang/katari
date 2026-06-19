// Drizzle queries for the content-addressed module store and the snapshot manifests built over it.
// Each takes an `Executor` so the deploy can run them all inside one transaction.

import type { IRModule } from "@katari-lang/types";
import { and, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { modules, projects, snapshots } from "../../db/tables/projects.js";
import type { ModuleHash } from "../../runtime/ids.js";

export const snapshotRepository = {
  findProject(executor: Executor, projectId: string) {
    return executor.select().from(projects).where(eq(projects.id, projectId));
  },

  /** The hashes this project already holds in the module store, as plain strings for diffing. */
  async existingModuleHashes(executor: Executor, projectId: string): Promise<Set<string>> {
    const rows = await executor
      .select({ hash: modules.hash })
      .from(modules)
      .where(eq(modules.projectId, projectId));
    return new Set<string>(rows.map((row) => row.hash));
  },

  /** Insert one module IR under its content hash; a no-op if an identical hash already exists. */
  insertModule(executor: Executor, projectId: string, hash: ModuleHash, ir: IRModule) {
    return executor.insert(modules).values({ projectId, hash, ir }).onConflictDoNothing();
  },

  insertSnapshot(
    executor: Executor,
    projectId: string,
    manifest: Record<string, ModuleHash>,
    sidecarBundle: unknown,
    message: string,
  ) {
    return executor
      .insert(snapshots)
      .values({ projectId, modules: manifest, sidecarBundle, message })
      .returning();
  },

  setHead(executor: Executor, projectId: string, snapshotId: string) {
    return executor
      .update(projects)
      .set({ headSnapshotId: snapshotId })
      .where(eq(projects.id, projectId));
  },

  findSnapshot(executor: Executor, projectId: string, snapshotId: string) {
    return executor
      .select()
      .from(snapshots)
      .where(and(eq(snapshots.projectId, projectId), eq(snapshots.id, snapshotId)));
  },

  list(executor: Executor, projectId: string) {
    return executor
      .select({ id: snapshots.id, message: snapshots.message, createdAt: snapshots.createdAt })
      .from(snapshots)
      .where(eq(snapshots.projectId, projectId));
  },
};
