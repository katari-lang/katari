// HTTP contract for the file resource: uploaded blobs (large strings / files). Real behaviour is
// deferred (it needs the blob store and instance ownership / ascent); the contract is frozen here.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export const fileParamSchema = projectIdParamSchema.extend({ fileId: z.uuid() });

/** File-list paging. `limit` omitted returns every file the project holds; `offset` pages it. */
export const listFilesQuerySchema = z.object({
  limit: z.coerce.number().int().positive().max(500).optional(),
  offset: z.coerce.number().int().nonnegative().optional(),
});
export type ListFilesQuery = z.infer<typeof listFilesQuerySchema>;

// The FFI blob-production route is scoped by the producing handler's delegation id, so the runtime can register
// the blob as owned by that ffi call's instance.
export const ffiBlobParamSchema = projectIdParamSchema.extend({ delegation: z.uuid() });
