import { db } from "../../db/client.js";
import { ConflictError, NotFoundError } from "../../lib/errors.js";
import { projectRepository } from "./project.repository.js";
import type { CreateProjectInput, UpdateProjectInput } from "./project.schema.js";

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

  async delete(projectId: string) {
    const [deleted] = await projectRepository.delete(db, projectId);
    if (!deleted) throw new NotFoundError(`Project ${projectId} not found.`);
  },
};
