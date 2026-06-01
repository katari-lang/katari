// FFI / CORE module-internal produce endpoint.
//
// NOT part of the generic read-only data plane (`value.ts`, §4.2). Production
// is each module's own business (docs §4.3): the FFI sidecar POSTs the bytes
// it produced to its module's produce endpoint, which writes an owner-tagged
// ephemeral ref via the value store. Kept separate from the consume plane so
// the read-only contract there stays clean.
//
// Mounted at `/project/:projectId/value`:
//   POST /:owner/produce            bytes → new ephemeral ref {module,id,hash,size}
//   POST /:owner/ref/:id/persist    promote ephemeral ref → persistent api file
//
// `owner` ∈ {core, ffi}. Auth rides the app-wide bearer for now; per-module
// sidecar tokens are the follow-up. The single-POST body is bounded by the
// app body limit (10 MB); larger payloads await the chunked open/push/close
// streaming path. The host buffers the whole body and re-chunks at the store.

import { Hono } from "hono";
import { z } from "zod";
import type { Storage } from "../storage/types.js";

const OwnerSchema = z.enum(["core", "ffi"]);
const IdSchema = z.string().min(1).max(256);
const ProjectIdSchema = z.string().min(1).max(256);
const SemanticKindSchema = z.enum(["string", "file", "secret"]);

const PersistBodySchema = z.object({ displayName: z.string().min(1).max(512).optional() }).strict();

export function buildValueProduceRoutes(storage: Storage): Hono {
  const app = new Hono();

  // Produce a complete ephemeral ref from a single POST body.
  app.post("/:owner/produce", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const owner = OwnerSchema.parse(c.req.param("owner"));
    const semanticKind = SemanticKindSchema.parse(
      c.req.header("X-Katari-Semantic-Kind") ?? "string",
    );
    const headerContentType = c.req.header("Content-Type");
    // Hono/undici default a bodyless POST's content-type; only keep a
    // meaningful one (the producer sets it to the value's own type).
    const contentType =
      headerContentType !== undefined && headerContentType !== "text/plain;charset=UTF-8"
        ? headerContentType
        : undefined;
    // The sidecar stamps the delegation `D` it is handling; the ref-authority
    // resolves `D → owning entity` on its OWN tables (Option 2 ascent) so the
    // ref is entity-owned (in-flight protection + value-driven ascent), no
    // entity id on the wire. Prefer the receiver's own entity if one exists
    // (a CORE shard, or a future FFI ext entity); otherwise own it by the
    // ISSUER of `D` (`delegations.parent_entity_id`) — for an ext call that is
    // the summoning CORE shard, so the ext's produced refs belong to the caller
    // and ascend / cascade with it (no separate FFI entity needed in v0.1.0).
    const ownerDelegation = c.req.header("X-Katari-Owner-Delegation");
    const ownerEntityId =
      ownerDelegation !== undefined
        ? ((await storage.entities.getByDelegation(projectId as never, ownerDelegation as never))
            ?.id ??
          (await storage.delegations.get(ownerDelegation as never))?.parentEntityId ??
          undefined)
        : undefined;

    // Optional human file name for a produced `file` (e.g. katari.makeFile's
    // `name`); meaningful only for `as: file`, harmless otherwise.
    const displayNameHeader = c.req.header("X-Katari-Display-Name");
    const displayName =
      displayNameHeader !== undefined && displayNameHeader !== "" ? displayNameHeader : undefined;

    const bytes = new Uint8Array(await c.req.arrayBuffer());
    const result = await storage.values.putComplete({
      projectId,
      owner,
      bytes,
      semanticKind,
      contentType,
      displayName,
      ownerEntityId,
    });
    return c.json(
      { module: owner, id: result.id, hash: result.hash, size: result.size, contentType },
      201,
    );
  });

  // Promote an ephemeral ref to a persistent project file (value.persist).
  app.post("/:owner/ref/:id/persist", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const owner = OwnerSchema.parse(c.req.param("owner"));
    const id = IdSchema.parse(c.req.param("id"));
    const raw = await c.req.text();
    const body = raw.length > 0 ? PersistBodySchema.parse(JSON.parse(raw)) : {};

    // A persisted value outlives the run: own it by the project-root entity
    // (id = projectId), which the API keeps for the project's life.
    const file = await storage.values.persistRef({
      projectId,
      module: owner,
      id,
      ownerEntityId: projectId,
      displayName: body.displayName,
    });
    if (file === null) {
      return c.json({ error: "ref not found or not complete" }, 404);
    }
    return c.json(
      {
        module: "api",
        id: file.id,
        hash: file.hash,
        size: file.size,
        contentType: file.contentType,
        displayName: file.displayName,
      },
      201,
    );
  });

  return app;
}
