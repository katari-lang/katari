// Drizzle queries for the project resource. Each takes an `Executor` so a service can run it
// standalone or inside a transaction.

import { eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { projects } from "../../db/tables/projects.js";
import type { CreateProjectInput } from "./project.schema.js";

export const projectRepository = {
  create(executor: Executor, input: CreateProjectInput) {
    return executor
      .insert(projects)
      .values({ name: input.name, description: input.description, readme: input.readme })
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
};
