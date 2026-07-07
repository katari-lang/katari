import { config } from "../../config/index.js";
import { db } from "../../db/client.js";
import { ConflictError, NotFoundError } from "../../lib/errors.js";
import { createLogger } from "../../lib/logger.js";
import { blobStore, facade } from "../../runtime/facade.js";
import type { BlobId, ProjectId } from "../../runtime/ids.js";
import { projectRepository } from "./project.repository.js";
import type { CreateProjectInput, UpdateProjectInput } from "./project.schema.js";

const logger = createLogger({ level: config.logLevel, bindings: { module: "project" } });

/** Postgres unique-violation SQLSTATE; raised when two projects claim the same `name`. */
const isUniqueViolation = (error: unknown): boolean =>
  typeof error === "object" && error !== null && "code" in error && error.code === "23505";

export const projectService = {
  async create(input: CreateProjectInput) {
    try {
      const [project] = await projectRepository.create(db, input);
      // `returning()` always yields the inserted row, but the type is an array, so guard for narrowing.
      if (!project) throw new Error("insert returned no row");
      return project;
    } catch (error) {
      if (isUniqueViolation(error)) {
        throw new ConflictError(`A project named "${input.name}" already exists.`);
      }
      throw error;
    }
  },

  async update(projectId: string, input: UpdateProjectInput) {
    const [project] = await projectRepository.update(db, projectId, input);
    if (!project) throw new NotFoundError(`Project ${projectId} not found.`);
    return project;
  },

  list() {
    return projectRepository.list(db);
  },

  async getById(projectId: string) {
    const [project] = await projectRepository.findById(db, projectId);
    if (!project) throw new NotFoundError(`Project ${projectId} not found.`);
    return project;
  },

  /** Delete a project outright: tear down its warm engine (sidecars killed, in-flight runs die with it —
   *  the explicit delete is the user's call), drop every DB row through the project's delete cascade, then
   *  free the blob bytes those rows referenced (rows gone ⇒ bytes unreferenced; the same durable-first
   *  order as the engine's byte reclaim). */
  async delete(projectId: string) {
    facade.evictProject(projectId);
    // Read the blob ids before the cascade removes their rows. A blob minted between this read and the
    // delete would orphan its bytes, but the engine was just evicted and deletion is a deliberate admin
    // action — the window is accepted for v0.1.
    const blobRows = await projectRepository.blobIds(db, projectId);
    const [deleted] = await projectRepository.delete(db, projectId);
    if (!deleted) throw new NotFoundError(`Project ${projectId} not found.`);
    for (const { blobId } of blobRows) {
      // Best-effort: a failed byte delete only leaks storage (never correctness), so log and continue.
      await blobStore.delete(projectId as ProjectId, blobId as BlobId).catch((error: unknown) => {
        logger.warn("failed to delete a deleted project's blob bytes", {
          projectId,
          blobId,
          error: error instanceof Error ? error.message : String(error),
        });
      });
    }
  },
};
