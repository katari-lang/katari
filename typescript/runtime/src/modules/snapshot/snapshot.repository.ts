// Drizzle queries for the content-addressed module store and the snapshot manifests built over it.
// Each takes an `Executor` so the deploy can run them all inside one transaction.

import type { IRModule, SidecarBundle } from "@katari-lang/types";
import { and, desc, eq, ilike, inArray, type SQL } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { modules, projects, snapshots } from "../../db/tables/projects.js";
import { escapeLike, listPageWithTotal } from "../../lib/paging.js";
import type { ModuleHash } from "../../runtime/ids.js";

export const snapshotRepository = {
  findProject(executor: Executor, projectId: string) {
    return executor.select().from(projects).where(eq(projects.id, projectId));
  },

  /** Like `findProject`, but takes a row lock so concurrent deploys to the same project serialize on
   *  it — without this the final `setHead` is an unordered last-writer-wins and head can flap. */
  findProjectForUpdate(executor: Executor, projectId: string) {
    return executor.select().from(projects).where(eq(projects.id, projectId)).for("update");
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

  /** The stored IR of every given hash, for materialising a snapshot manifest's modules in one read
   *  (the agent-schema reader resolves a manifest's hashes through this). */
  findModulesByHashes(executor: Executor, projectId: string, hashes: ModuleHash[]) {
    return executor
      .select({ hash: modules.hash, ir: modules.ir })
      .from(modules)
      .where(and(eq(modules.projectId, projectId), inArray(modules.hash, hashes)));
  },

  /** The IR already stored under a held hash. Used to verify an inlined upload of an already-held
   *  hash matches the stored bytes (the hash must address its content). */
  findModuleIr(executor: Executor, projectId: string, hash: ModuleHash) {
    return executor
      .select({ ir: modules.ir })
      .from(modules)
      .where(and(eq(modules.projectId, projectId), eq(modules.hash, hash)));
  },

  insertSnapshot(
    executor: Executor,
    projectId: string,
    manifest: Record<string, ModuleHash>,
    sidecarBundle: SidecarBundle | null,
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

  // Projects only the columns the read endpoints expose: the (potentially large) `sidecarBundle` and
  // the redundant `projectId` are deliberately left out so a metadata fetch stays small.
  findSnapshot(executor: Executor, projectId: string, snapshotId: string) {
    return executor
      .select({
        id: snapshots.id,
        message: snapshots.message,
        modules: snapshots.modules,
        createdAt: snapshots.createdAt,
      })
      .from(snapshots)
      .where(and(eq(snapshots.projectId, projectId), eq(snapshots.id, snapshotId)));
  },

  /** A project's deploy history, newest first, plus the `total` matching the filter (for the pager).
   *  `limit` omitted returns the whole history (the agents-page snapshot selector needs every version);
   *  `offset` pages it, and `search` narrows by deploy message. */
  async list(
    executor: Executor,
    projectId: string,
    filter: { search?: string; limit?: number; offset?: number } = {},
  ): Promise<{
    rows: Array<{ id: string; message: string; createdAt: Date }>;
    total: number;
  }> {
    const conditions: SQL[] = [eq(snapshots.projectId, projectId)];
    if (filter.search !== undefined) {
      conditions.push(ilike(snapshots.message, `%${escapeLike(filter.search)}%`));
    }
    const where = and(...conditions);
    const page = executor
      .select({ id: snapshots.id, message: snapshots.message, createdAt: snapshots.createdAt })
      .from(snapshots)
      .where(where)
      // Newest deploy first; `id` breaks ties deterministically when two land in the same instant.
      .orderBy(desc(snapshots.createdAt), desc(snapshots.id));
    return listPageWithTotal({ executor, query: page, window: filter, table: snapshots, where });
  },
};
