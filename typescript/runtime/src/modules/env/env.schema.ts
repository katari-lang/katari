// HTTP contract for the env resource: a project-scoped key/value store. Real behaviour is deferred
// (secret values need AES-GCM encryption); the contract is frozen here.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export const setEnvSchema = z.object({
  value: z.string(),
  isSecret: z.boolean().optional(),
});
export type SetEnvBody = z.infer<typeof setEnvSchema>;

export const envKeyParamSchema = projectIdParamSchema.extend({ key: z.string().min(1) });
