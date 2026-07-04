// HTTP contract for the project resource: the deploy/isolation boundary (1 project = 1 app).

import { z } from "zod";

export const createProjectSchema = z.object({
  name: z.string().min(1),
  description: z.string().optional(),
  readme: z.string().optional(),
});
export type CreateProjectInput = z.infer<typeof createProjectSchema>;

// A partial update (used by `katari apply` to keep an existing project's description / README in sync
// with the source). An omitted field is left untouched; `null` clears it.
export const updateProjectSchema = z.object({
  description: z.string().nullable().optional(),
  readme: z.string().nullable().optional(),
});
export type UpdateProjectInput = z.infer<typeof updateProjectSchema>;
