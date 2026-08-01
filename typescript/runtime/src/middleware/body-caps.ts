import { bodyLimit } from "hono/body-limit";
import { createMiddleware } from "hono/factory";
import type { AppEnv } from "../types/app-env.js";

/** The two endpoints whose body is a file rather than a document, and so carry the upload cap. */
const UPLOAD_PATHS = /^\/api\/v1\/projects\/[^/]+\/(files|ffi\/[^/]+\/blobs)$/;

/**
 * The body-size cap for everything under `/api`, choosing per path: a file upload is measured against
 * `maxUploadBytes`, every other request against `maxRequestBytes`.
 *
 * It is one middleware because every middleware whose path matches runs. Mounting the upload cap on the
 * upload paths and the general cap over all of `/api` would leave both in force there, and the smaller of
 * the two would be the one that decided — making a generous upload cap inert the moment the general one
 * was tuned below it.
 */
export const requestBodyLimit = (limits: { maxRequestBytes: number; maxUploadBytes: number }) => {
  const upload = bodyLimit({
    maxSize: limits.maxUploadBytes,
    onError: (c) => c.json({ error: "the uploaded file is too large" }, 413),
  });
  const ordinary = bodyLimit({
    maxSize: limits.maxRequestBytes,
    onError: (c) => c.json({ error: "the request body is too large" }, 413),
  });
  return createMiddleware<AppEnv>((c, next) =>
    (UPLOAD_PATHS.test(c.req.path) ? upload : ordinary)(c, next),
  );
};
