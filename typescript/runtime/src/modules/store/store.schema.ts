// HTTP contract for the store resource: the project's durable key-value store (`prelude.store`).
// A key is a /-separated path; it rides as one URI-encoded path segment (the client encodes, Hono
// decodes the param), so the route stays a plain `:key`.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export const setStoreEntrySchema = z.object({
  /** The value as wire JSON (the same shape `store.get`'s admin read returns, minus redaction). */
  value: z.unknown(),
});
export type SetStoreEntryBody = z.infer<typeof setStoreEntrySchema>;

export const storeKeyParamSchema = projectIdParamSchema.extend({ key: z.string().min(1) });
