// Read queries over the `blobs` table for the file API. A file IS an api-root-owned blob; its row holds the
// download metadata (hash / size / content type), while the bytes live in the BlobStore. Reads go straight
// to the committed row (the durable snapshot), like the run / escalation read paths.

import { and, desc, eq, sql } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { blobs } from "../../db/tables/engine.js";
import { apiRootIdOf, type ProjectId } from "../../runtime/ids.js";

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

  /** The api-root-owned blobs a project holds (the file listing), newest first, plus the `total` for the
   *  pager. Filtered to the api root's ownership so a transient FFI-call-owned blob — a handler's mid-call
   *  upload, owned by that call's instance and gone when it tears down — never surfaces (and never flickers
   *  in and out) in the user's file list. `limit` omitted returns every file; `offset` pages it. */
  async list(
    executor: Executor,
    projectId: string,
    filter: { limit?: number; offset?: number } = {},
  ) {
    const where = and(
      eq(blobs.projectId, projectId),
      eq(blobs.ownerInstanceId, apiRootIdOf(projectId as ProjectId)),
    );
    const page = executor
      .select(columns)
      .from(blobs)
      .where(where)
      // Newest first; `blob_id` breaks ties deterministically for stable offset paging.
      .orderBy(desc(blobs.createdAt), desc(blobs.blobId));
    const limited = filter.limit === undefined ? page : page.limit(filter.limit);
    const rows = await (filter.offset === undefined ? limited : limited.offset(filter.offset));

    const total = await executor
      .select({ value: sql<number>`count(*)::int` })
      .from(blobs)
      .where(where)
      .then(([row]) => row?.value ?? 0);

    return { rows, total };
  },
};
