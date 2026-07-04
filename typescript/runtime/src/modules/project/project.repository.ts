// Drizzle queries for the project resource. Each takes an `Executor` so a service can run it
// standalone or inside a transaction.

import { eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { blobs } from "../../db/tables/engine.js";
import { projects } from "../../db/tables/projects.js";
import type { CreateProjectInput, UpdateProjectInput } from "./project.schema.js";

export const projectRepository = {
  create(executor: Executor, input: CreateProjectInput) {
    return executor
      .insert(projects)
      .values({ name: input.name, description: input.description, readme: input.readme })
      .returning();
  },

  update(executor: Executor, projectId: string, input: UpdateProjectInput) {
    // Only touch the fields the caller actually sent, so a partial update never clobbers the rest.
    return executor
      .update(projects)
      .set({
        ...(input.description !== undefined ? { description: input.description } : {}),
        ...(input.readme !== undefined ? { readme: input.readme } : {}),
      })
      .where(eq(projects.id, projectId))
      .returning();
  },

  list(executor: Executor) {
    return executor.select().from(projects);
  },

  findById(executor: Executor, projectId: string) {
    return executor.select().from(projects).where(eq(projects.id, projectId));
  },

  delete(executor: Executor, projectId: string) {
    return executor
      .delete(projects)
      .where(eq(projects.id, projectId))
      .returning({ id: projects.id });
  },

  /** Every blob id the project holds — read before the project row's delete cascade removes the rows, so
   *  the service can free the bytes afterwards (rows gone ⇒ bytes unreferenced; durable-first). */
  blobIds(executor: Executor, projectId: string) {
    return executor
      .select({ blobId: blobs.blobId })
      .from(blobs)
      .where(eq(blobs.projectId, projectId));
  },
};
