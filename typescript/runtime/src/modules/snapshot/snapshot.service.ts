import { isDeepStrictEqual } from "node:util";
import { type IRModule, SUPPORTED_IR_SCHEMA_VERSION } from "@katari-lang/types";
import { db } from "../../db/client.js";
import { BadRequestError, NotFoundError, UnprocessableEntityError } from "../../lib/errors.js";
import { type ModuleHash, toModuleHash } from "../../runtime/ids.js";
import { snapshotRepository } from "./snapshot.repository.js";
import type { DeploySnapshotInput, ListSnapshotsQuery } from "./snapshot.schema.js";

/**
 * Read `metadata.schemaVersion` off an uploaded module without trusting its shape — the deploy schema
 * only guarantees the IR is a non-array object, so its `metadata` may be missing or malformed. A version
 * that is not a plain number reads as `undefined`, which the gate then rejects like any other mismatch.
 */
function moduleSchemaVersion(ir: IRModule): number | undefined {
  const metadata: unknown = ir.metadata;
  if (typeof metadata !== "object" || metadata === null || !("schemaVersion" in metadata)) {
    return undefined;
  }
  const version: unknown = metadata.schemaVersion;
  return typeof version === "number" ? version : undefined;
}

/**
 * Gate a deploy on the IR schema version. The compiler stamps `metadata.schemaVersion` on every module
 * (the version the wire shape was frozen at), and the runtime refuses to store IR built for a different
 * version than it speaks: a skew otherwise surfaces not as an error but as a silent "zero callables
 * resolved" failure at run time, because the older side cannot execute the newer side's IR shape. Only
 * INLINED IR is checked — a module the deploy references by hash alone was already gated when its bytes
 * were first uploaded. The message names both versions so the operator knows to align the CLI and the
 * runtime to the same toolchain build.
 */
export function assertDeploySchemaVersions(input: DeploySnapshotInput): void {
  for (const [moduleName, entry] of Object.entries(input.modules)) {
    if (!entry.ir) continue;
    const version = moduleSchemaVersion(entry.ir);
    if (version !== SUPPORTED_IR_SCHEMA_VERSION) {
      throw new BadRequestError(
        `Module "${moduleName}" was compiled for IR schema version ${version ?? "unknown"}, but this runtime speaks IR schema version ${SUPPORTED_IR_SCHEMA_VERSION}. Align the Katari CLI and runtime to the same toolchain version, then re-deploy.`,
      );
    }
  }
}

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
    // Reject a version-skewed bundle up front (before any DB work) so stale IR never reaches the store.
    assertDeploySchemaVersions(input);
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

  /** Move the project's live head to an existing snapshot — the rollback (or roll-forward; snapshots are
   *  immutable, so the head is just a pointer). Only NEW runs follow the moved head: a run pins the
   *  snapshot it started on, so nothing in flight is touched. Locks the project row like `deploy`, so a
   *  concurrent deploy and a head move serialize in commit order. */
  async setHead(projectId: string, snapshotId: string) {
    return db.transaction(async (tx) => {
      const [project] = await snapshotRepository.findProjectForUpdate(tx, projectId);
      if (!project) throw new NotFoundError(`Project ${projectId} not found.`);
      const [snapshot] = await snapshotRepository.findSnapshot(tx, projectId, snapshotId);
      if (!snapshot) throw new NotFoundError(`Snapshot ${snapshotId} not found.`);
      await snapshotRepository.setHead(tx, projectId, snapshotId);
      return { id: snapshotId };
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

  /** The deploy history page plus its filtered `total` (surfaced by the route as `X-Total-Count`). */
  async list(projectId: string, query: ListSnapshotsQuery = {}) {
    const [project] = await snapshotRepository.findProject(db, projectId);
    if (!project) throw new NotFoundError(`Project ${projectId} not found.`);
    const { rows, total } = await snapshotRepository.list(db, projectId, query);
    return { items: rows, total };
  },

  async getById(projectId: string, snapshotId: string) {
    const [snapshot] = await snapshotRepository.findSnapshot(db, projectId, snapshotId);
    if (!snapshot) throw new NotFoundError(`Snapshot ${snapshotId} not found.`);
    return snapshot;
  },
};
