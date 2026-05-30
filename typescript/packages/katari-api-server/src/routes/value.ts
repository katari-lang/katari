// Katari Protocol data plane — the cross-module value consume endpoint.
//
// READ-ONLY by design (docs/2026-05-30-storage-schema-and-api.md §4.2): a
// module fetches bytes another module produced. Production is module-internal
// (FFI sidecar / in-process writes), NOT exposed here. The `bus` (6 control
// events) and this data plane are separate planes.
//
// Mounted at `/project/:projectId/value`. The path order is
// `project (= which runtime) → module → id`; `snapshot` does not appear (a
// value's owner is a module, not a code version — D24).
//
//   GET /:module/ref/:id            full bytes
//   GET /:module/ref/:id?range=N-M  partial bytes (also honours `Range:`)
//   GET /:module/ref/:id/state      metadata (state / hash / size / contentType)
//
// v0.1.0 serves complete blobs only. `subscribe` (pre-completion chunks) /
// `await` (terminal) are observable-streaming endpoints deferred to v0.2.
// Auth currently rides the app-wide bearer; per-module short-lived tokens
// (sidecar) are a Phase C refinement.

import { Hono } from "hono";
import { z } from "zod";
import type { Storage } from "../storage/types.js";

const ModuleSchema = z.enum(["core", "ffi", "api"]);
const IdSchema = z.string().min(1).max(256);
const ProjectIdSchema = z.string().min(1).max(256);

/** Parsed half-open byte range `[offset, offset+length)`. */
type ByteRange = { offset: number; length: number };

/**
 * Parse a range from the documented `?range=N-M` query or a standard
 * `Range: bytes=N-M` header (query wins). `N-` (open end) spans to EOF.
 * Returns `null` when no range is requested or the spec is unusable.
 */
function parseRange(
  query: string | undefined,
  header: string | undefined,
  size: number,
): ByteRange | null {
  let spec = query;
  if (spec === undefined && header !== undefined) {
    const match = /^bytes=(.+)$/.exec(header.trim());
    if (match !== null) spec = match[1];
  }
  if (spec === undefined || spec === "") return null;
  const match = /^(\d+)-(\d*)$/.exec(spec.trim());
  if (match === null) return null;
  const start = Number(match[1]);
  const endInclusive = match[2] === "" ? size - 1 : Number(match[2]);
  if (!Number.isFinite(start) || start < 0) return null;
  const clampedEnd = Math.min(endInclusive, size - 1);
  if (clampedEnd < start) return null;
  return { offset: start, length: clampedEnd - start + 1 };
}

/** A Uint8Array view as an exactly-sized ArrayBuffer (Hono body / Response). */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export function buildValueRoutes(storage: Storage): Hono {
  const app = new Hono();

  // Metadata only — no bytes. Lets a consumer size a fetch or detect an
  // errored producer before pulling content.
  app.get("/:module/ref/:id/state", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const module = ModuleSchema.parse(c.req.param("module"));
    const id = IdSchema.parse(c.req.param("id"));
    const state = await storage.values.getState(projectId, module, id);
    if (state === null) return c.json({ error: "value not found" }, 404);
    return c.json(state);
  });

  // Full or partial bytes.
  app.get("/:module/ref/:id", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const module = ModuleSchema.parse(c.req.param("module"));
    const id = IdSchema.parse(c.req.param("id"));

    const state = await storage.values.getState(projectId, module, id);
    if (state === null) return c.json({ error: "value not found" }, 404);
    if (state.state === "errored") {
      return c.json({ error: "value errored", message: state.errorMessage }, 409);
    }
    const contentType = state.contentType ?? "application/octet-stream";
    const size = state.size ?? 0;

    const range = parseRange(c.req.query("range"), c.req.header("Range"), size);
    if (range !== null) {
      const slice = await storage.values.fetchRange(
        projectId,
        module,
        id,
        range.offset,
        range.length,
      );
      if (slice === null) return c.json({ error: "value not found" }, 404);
      const end = range.offset + slice.length - 1;
      return c.body(toArrayBuffer(slice), 206, {
        "Content-Type": contentType,
        "Content-Length": String(slice.length),
        "Content-Range": `bytes ${range.offset}-${end}/${size}`,
        "Accept-Ranges": "bytes",
      });
    }

    const bytes = await storage.values.fetch(projectId, module, id);
    if (bytes === null) return c.json({ error: "value not found" }, 404);
    return c.body(toArrayBuffer(bytes), 200, {
      "Content-Type": contentType,
      "Content-Length": String(bytes.length),
      "Accept-Ranges": "bytes",
    });
  });

  return app;
}
