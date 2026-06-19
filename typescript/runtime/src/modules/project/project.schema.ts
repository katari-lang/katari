// HTTP contract for the project resource: the deploy/isolation boundary (1 project = 1 app).

import { z } from "zod";

export const createProjectSchema = z.object({
  name: z.string().min(1),
  description: z.string().optional(),
  readme: z.string().optional(),
});
export type CreateProjectInput = z.infer<typeof createProjectSchema>;

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
