// The file resource: a file is an api-root-owned blob. Upload goes through the engine command edge (the
// facade → the actor → the ResourcePool, so the blob's ownership has one SoT); download / list are reads
// straight from the committed `blobs` row + the BlobStore bytes. There is no explicit delete (api-root
// blobs are retained until a future explicit-delete feature).

import { db } from "../../db/client.js";
import { NotFoundError } from "../../lib/errors.js";
import { blobStore, facade } from "../../runtime/facade.js";
import type { BlobId, ProjectId } from "../../runtime/ids.js";
import { fileRepository } from "./file.repository.js";

export interface DownloadedFile {
  bytes: Uint8Array;
  contentType: string | null;
  size: number;
}

export const fileService = {
  /** Store the bytes and register the file as an api-root-owned blob; returns its handle. */
  upload(projectId: string, bytes: Uint8Array, contentType?: string) {
    return facade.uploadFile({ projectId, bytes, contentType });
  },

  /** Store the bytes an FFI handler produced mid-call and register the blob as owned by that call's instance
   *  (it ascends to the core caller on the call's return); returns its handle. */
  produceFfiBlob(projectId: string, delegation: string, bytes: Uint8Array, contentType?: string) {
    return facade.produceFfiBlob({ projectId, delegation, bytes, contentType });
  },

  /** Every file (blob) the project holds. */
  list(projectId: string) {
    return fileRepository.list(db, projectId);
  },

  /** A file's bytes + content type, or a 404 when it does not exist. */
  async download(projectId: string, fileId: string): Promise<DownloadedFile> {
    const row = await fileRepository.get(db, projectId, fileId);
    if (row === undefined) throw new NotFoundError(`file ${fileId} not found`);
    let bytes: Uint8Array;
    try {
      bytes = await blobStore.get(projectId as ProjectId, fileId as BlobId);
    } catch {
      // The row existed at the read above but the bytes are gone: the owning instance's teardown raced this
      // download and reclaimed them (the post-commit byte delete). The file no longer exists — a 404, not the
      // 500 a bare BlobStore "not found" would otherwise become.
      throw new NotFoundError(`file ${fileId} not found`);
    }
    return { bytes, contentType: row.contentType, size: row.size };
  },
};
