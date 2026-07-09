import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { pagedList, success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { ffiBlobParamSchema, fileParamSchema, listFilesQuerySchema } from "./file.schema.js";
import { fileService } from "./file.service.js";

export const fileRoutes = new Hono<AppEnv>()
  // Upload: the raw request body is the file's bytes; its Content-Type is recorded with the blob. Returns the
  // blob handle (`id`) used to download / reference it.
  .post("/projects/:projectId/files", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    const bytes = new Uint8Array(await c.req.arrayBuffer());
    const contentType = c.req.header("content-type");
    return c.json(success(await fileService.upload(projectId, bytes, contentType)), 201);
  })
  // FFI blob production: a sidecar handler uploads bytes mid-call over this side channel (out of band from the
  // one-shot stdio reply). The blob is registered as owned by the producing `:delegation`'s ffi call instance,
  // so it ascends to the core caller on return. Returns the blob handle the sidecar lifts into a `File`.
  .post(
    "/projects/:projectId/ffi/:delegation/blobs",
    zValidator("param", ffiBlobParamSchema),
    async (c) => {
      const { projectId, delegation } = c.req.valid("param");
      const bytes = new Uint8Array(await c.req.arrayBuffer());
      const contentType = c.req.header("content-type");
      return c.json(
        success(await fileService.produceFfiBlob(projectId, delegation, bytes, contentType)),
        201,
      );
    },
  )
  .get(
    "/projects/:projectId/files",
    zValidator("param", projectIdParamSchema),
    zValidator("query", listFilesQuerySchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      return c.json(pagedList(c, await fileService.list(projectId, c.req.valid("query"))));
    },
  )
  // Download: stream the blob's bytes with its stored content type (bytes are not JSON, so this is the one
  // endpoint that does not use the `{ ok, data }` envelope). A row that records no content type sends no
  // Content-Type header — absence travels as absence, so the sidecar's blob client can report "nothing
  // recorded" honestly (a browser treats the missing header as octet-stream anyway).
  .get("/projects/:projectId/files/:fileId", zValidator("param", fileParamSchema), async (c) => {
    const { projectId, fileId } = c.req.valid("param");
    const file = await fileService.download(projectId, fileId);
    return new Response(file.bytes, {
      headers: {
        ...(file.contentType === null ? {} : { "Content-Type": file.contentType }),
        "Content-Length": String(file.size),
      },
    });
  })
  // Delete: drop the file's blob row (its bytes follow strictly after the commit). A file a live run still
  // references reads as gone afterwards — the explicit delete is the user's call.
  .delete("/projects/:projectId/files/:fileId", zValidator("param", fileParamSchema), async (c) => {
    const { projectId, fileId } = c.req.valid("param");
    await fileService.delete(projectId, fileId);
    return c.json(success({ id: fileId }));
  });
