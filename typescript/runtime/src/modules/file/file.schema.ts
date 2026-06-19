// HTTP contract for the file resource: uploaded blobs (large strings / files). Real behaviour is
// deferred (it needs the blob store and instance ownership / ascent); the contract is frozen here.

import { z } from "zod";

export const projectIdParamSchema = z.object({ projectId: z.uuid() });
export const fileParamSchema = z.object({ projectId: z.uuid(), fileId: z.uuid() });
