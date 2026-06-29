import { Hono } from "hono";
import { NotImplementedError } from "../../lib/errors.js";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { ffiBlobParamSchema, fileParamSchema } from "./file.schema.js";
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
  .get("/projects/:projectId/files", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await fileService.list(projectId)));
  })
  // Download: stream the blob's bytes with its stored content type (bytes are not JSON, so this is the one
  // endpoint that does not use the `{ ok, data }` envelope).
  .get("/projects/:projectId/files/:fileId", zValidator("param", fileParamSchema), async (c) => {
    const { projectId, fileId } = c.req.valid("param");
    const file = await fileService.download(projectId, fileId);
    return new Response(file.bytes, {
      headers: {
        "Content-Type": file.contentType ?? "application/octet-stream",
        "Content-Length": String(file.size),
      },
    });
  })
  .delete("/projects/:projectId/files/:fileId", zValidator("param", fileParamSchema), async (c) => {
    // An api-root blob is retained until an explicit-delete feature lands (intentionally deferred).
    c.req.valid("param");
    throw new NotImplementedError("Deleting a file is not implemented yet.");
  });
