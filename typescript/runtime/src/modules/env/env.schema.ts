// HTTP contract for the env resource: a project-scoped key/value store. Real behaviour is deferred
// (secret values need AES-GCM encryption); the contract is frozen here.

import { z } from "zod";

export const setEnvSchema = z.object({
  value: z.string(),
  isSecret: z.boolean().optional(),
});
export type SetEnvBody = z.infer<typeof setEnvSchema>;

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
export const envKeyParamSchema = z.object({ projectId: z.uuid(), key: z.string().min(1) });
