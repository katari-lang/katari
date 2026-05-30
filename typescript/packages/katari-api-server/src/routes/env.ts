// Per-project env-entry CRUD routes. Operators / web-UI use these to manage
// the key/value store backing EnvModule's stdlib builtins
// ('get_env' / 'get_secret_env' / 'set_env'). Mounted at
// `/project/:projectId/env`: each project owns its own env space, matching
// the per-project EnvModule the actor-host wires.
//
// Security surface: this endpoint is the **only** way for an
// outside-the-runtime caller to view env metadata. Secret values are
// never returned in plaintext over HTTP; list / get responses replace
// the secret value with the sentinel "<redacted>" string. Storing a
// secret value requires the encryption key ('KATARI_SECRET_KEY')
// because EnvModule wraps the plaintext in AES-GCM before persistence
// — this happens inside the tick that processes set_env, so the
// host-side process must have the key configured.

import { encryptSecret } from "@katari-lang/runtime";
import { Hono } from "hono";
import { z } from "zod";
import type { Storage } from "../storage/types.js";
import { ProjectIdSchema } from "./middleware/validation.js";

const KEY_PATTERN = /^[A-Za-z0-9_.-]+$/;

const KeyParamSchema = z.string().min(1).max(256).regex(KEY_PATTERN, {
  message: "key may only contain [A-Za-z0-9_.-]",
});

const UpsertBodySchema = z.object({
  key: KeyParamSchema,
  value: z
    .string()
    .min(0)
    .max(64 * 1024),
  isSecret: z.boolean(),
});

const REDACTED_PLACEHOLDER = "<redacted>";

export function buildEnvRoutes(storage: Storage): Hono {
  const app = new Hono();

  // List every entry. Secret values are replaced with the redaction
  // placeholder; the row's `isSecret` flag tells the caller whether
  // the original value would have been encrypted.
  app.get("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const rows = await storage.envEntries.list(projectId);
    return c.json({
      entries: rows.map((r) => ({
        key: r.key,
        value: r.isSecret ? REDACTED_PLACEHOLDER : r.value,
        isSecret: r.isSecret,
        updatedAt: r.updatedAt,
      })),
    });
  });

  // Read one entry. Secret entries again return the redaction
  // placeholder rather than the plaintext (or ciphertext, which would
  // be useless to clients).
  app.get("/:key", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const key = KeyParamSchema.parse(c.req.param("key"));
    const row = await storage.envEntries.get(projectId, key);
    if (row === null) {
      return c.json({ error: "env entry not found" }, 404);
    }
    return c.json({
      key: row.key,
      value: row.isSecret ? REDACTED_PLACEHOLDER : row.value,
      isSecret: row.isSecret,
      updatedAt: row.updatedAt,
    });
  });

  // Create or overwrite an entry. The HTTP body carries the plaintext
  // for both secret and non-secret entries; on the wire we encrypt
  // secret values before they reach storage, matching the EnvModule's
  // own encryption boundary for `set_env`.
  app.put("/", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const body = UpsertBodySchema.parse(await c.req.json());
    const storedValue = body.isSecret ? encryptSecret(body.value) : body.value;
    await storage.envEntries.upsert({
      projectId,
      key: body.key,
      value: storedValue,
      isSecret: body.isSecret,
    });
    return c.json({ ok: true });
  });

  // Delete an entry by key. 404 when the key was already absent so
  // callers can distinguish "removed" from "no-op".
  app.delete("/:key", async (c) => {
    const projectId = ProjectIdSchema.parse(c.req.param("projectId"));
    const key = KeyParamSchema.parse(c.req.param("key"));
    const ok = await storage.envEntries.delete(projectId, key);
    if (!ok) {
      return c.json({ error: "env entry not found" }, 404);
    }
    return c.json({ ok: true });
  });

  return app;
}
