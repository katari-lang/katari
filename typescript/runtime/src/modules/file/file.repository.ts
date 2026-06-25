// Read queries over the `blobs` table for the file API. A file IS an api-root-owned blob; its row holds the
// download metadata (hash / size / content type), while the bytes live in the BlobStore. Reads go straight
// to the committed row (the durable snapshot), like the run / escalation read paths.

import { and, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { blobs } from "../../db/tables/engine.js";

const columns = {
  id: blobs.blobId,
  hash: blobs.hash,
  size: blobs.size,
  contentType: blobs.contentType,
  semanticKind: blobs.semanticKind,
} as const;

export const fileRepository = {
  /** One blob's download metadata, or `undefined` when the project holds no such blob. */
  async get(executor: Executor, projectId: string, blobId: string) {
    const [row] = await executor
      .select(columns)
      .from(blobs)
      .where(and(eq(blobs.projectId, projectId), eq(blobs.blobId, blobId)))
      .limit(1);
    return row;
  },

  /** Every blob a project holds (the file listing). */
  list(executor: Executor, projectId: string) {
    return executor.select(columns).from(blobs).where(eq(blobs.projectId, projectId));
  },
};
