// Persistent project files (`api_files`) — the operator-facing upload /
// browse surface backing `file`-typed agent arguments.
//
// A `file` value crosses the wire as a value reference
// (`{$ref:{module,id}, as:"file", hash, size}`); the AI / operator cannot
// produce one inline (Schema.hs `fileRefCore`). This route is where those
// refs come from: upload bytes → an `api_files` record (a persistent,
// not-GC'd value owned by the API module), then hand its ref to `startRun`.
//
// Mounted at `/project/:projectId/file`:
//   GET    /            list files (each carries its ready-to-use ref)
//   POST   /            upload bytes → new file (raw body; `?name=` label)
//   GET    /:id         one file (with ref)
//   DELETE /:id         drop a file (blob refcount −1)
//
// "file id → ref" lives here, not at invoke time: the list / get / upload
// responses embed the `$ref as:file` envelope (`fileRef`) so the caller
// drops it straight into an argument. The invoke route stays a thin
// `valueFromRaw` shim — it never resolves file ids.
//
// Single-POST upload is bounded by the app body limit (10 MB). Larger
// payloads are the chunked streaming path (v0.2); within v0.1.0 this is the
// whole story, so there is no partial-upload state to reconcile.

import type { FileRecord } from "@katari-lang/runtime";
import { Hono } from "hono";
import { z } from "zod";
import { ensureProjectRootEntity } from "../entity-roots.js";
import type { Storage } from "../storage/types.js";
import { ProjectIdSchema } from "./middleware/validation.js";

const IdSchema = z.string().min(1).max(256);
const DisplayNameSchema = z
  .string()
  .min(1)
  .max(512)
  .transform((s) => s.trim())
  .pipe(z.string().min(1));

/** The `$ref as:file` envelope (a `RawValue`) for an `api_files` record.
 *  This IS the value an operator passes for a `file` argument. Built
 *  server-side so the client never has to know a file's storage module. */
function fileRef(file: FileRecord): Record<string, unknown> {
  const ref: Record<string, unknown> = {
    $ref: { module: "api", id: file.id },
    as: "file",
    hash: file.hash,
    size: file.size,
  };
  if (file.contentType !== undefined) ref.contentType = file.contentType;
  return ref;
}

/** Wire shape: the storage record plus its ready-to-use ref envelope. */
function fileToWire(file: FileRecord) {
  return {
    id: file.id,
    hash: file.hash,
    size: file.size,
    contentType: file.contentType,
    displayName: file.displayName,
    createdAt: file.createdAt,
    ref: fileRef(file),
  };
}

export function buildFileRoutes(storage: Storage): Hono {
  const app = new Hono();

  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const files = await storage.values.listFiles(projectId);
    return c.json({ files: files.map(fileToWire) });
  });

  // Upload: the raw request body is the file's bytes. `Content-Type`
  // carries the file's own media type; `?name=` carries the display label
  // (browsers don't send a filename for a fetch body, so it is explicit).
  app.post("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const rawName = c.req.query("name");
    const displayName =
      rawName !== undefined && rawName !== "" ? DisplayNameSchema.parse(rawName) : undefined;
    const headerContentType = c.req.header("Content-Type");
    const contentType =
      headerContentType !== undefined && headerContentType !== "text/plain;charset=UTF-8"
        ? headerContentType
        : undefined;

    const bytes = new Uint8Array(await c.req.arrayBuffer());
    if (bytes.length === 0) {
      return c.json({ error: "upload body is empty" }, 400);
    }
    // The upload is owned by the project-root entity (kept for the project's
    // life). Ensure it exists, then create the file, in one tx.
    const file = await storage.withTransaction(async (tx) => {
      const ownerEntityId = await ensureProjectRootEntity(tx, projectId);
      return tx.values.createFile({ projectId, ownerEntityId, bytes, contentType, displayName });
    });
    return c.json({ file: fileToWire(file) }, 201);
  });

  app.get("/:id", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const id = IdSchema.parse(c.req.param("id"));
    const file = await storage.values.getFile(projectId, id);
    if (file === null) return c.json({ error: "file not found" }, 404);
    return c.json({ file: fileToWire(file) });
  });

  app.delete("/:id", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const id = IdSchema.parse(c.req.param("id"));
    const ok = await storage.values.deleteFile(projectId, id);
    if (!ok) return c.json({ error: "file not found" }, 404);
    return c.json({ ok: true });
  });

  return app;
}
