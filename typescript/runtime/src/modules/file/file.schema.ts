// HTTP contract for the file resource: uploaded blobs (large strings / files). Real behaviour is
// deferred (it needs the blob store and instance ownership / ascent); the contract is frozen here.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export { projectIdParamSchema };

export const fileParamSchema = projectIdParamSchema.extend({ fileId: z.uuid() });
