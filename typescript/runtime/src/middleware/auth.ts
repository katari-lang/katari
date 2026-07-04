// Bearer-token authentication for the JSON API. A caller must send `Authorization: Bearer <key>` where
// `<key>` matches KATARI_API_KEY (the auth token — distinct from KATARI_SECRET_KEY, which only encrypts
// secrets at rest). The comparison is constant-time so the response latency does not leak how much of the
// key was correct.
//
// Two kinds of request bypass auth, because neither can (or should) carry the header:
//   - `/api/v1/health` — liveness for the container healthcheck / load balancers / uptime monitors;
//   - everything that is NOT under `/api` — the admin console's own static assets (`/`, `/assets/*`,
//     the SPA shell). A browser cannot attach `Authorization` to a `<script>` / `<link>`, so the auth
//     boundary is the JSON API; the console loads publicly, then sends the bearer it holds (entered on
//     its login screen) with every `/api/v1` call.
//
// This middleware is only mounted when auth is enforced (a real KATARI_API_KEY); when auth is off the
// app never registers it (see `app.ts` / `bin.ts`).

import { timingSafeEqual } from "node:crypto";
import type { MiddlewareHandler } from "hono";
import { failure } from "../lib/response.js";
import type { AppEnv } from "../types/app-env.js";

const bearer = /^Bearer\s+(.+)$/;

/** Whether a request bypasses auth: the public health probe, or any non-API (console static) path. */
function isPublicPath(path: string): boolean {
  return path === "/api/v1/health" || !(path === "/api" || path.startsWith("/api/"));
}

/** A length-safe constant-time compare of the presented token against the key. */
function tokensMatch(presented: string, key: string): boolean {
  const presentedBytes = Buffer.from(presented);
  const keyBytes = Buffer.from(key);
  // `timingSafeEqual` throws on a length mismatch, which itself would be a timing oracle on the length;
  // compare against a same-length buffer so the taken path does not depend on the presented length.
  if (presentedBytes.length !== keyBytes.length) {
    timingSafeEqual(keyBytes, keyBytes);
    return false;
  }
  return timingSafeEqual(presentedBytes, keyBytes);
}

/** Build the auth middleware for a non-empty API key. */
export function bearerAuth(apiKey: string): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    if (isPublicPath(c.req.path)) return next();
    const header = c.req.header("Authorization");
    const presented = header === undefined ? undefined : bearer.exec(header)?.[1];
    if (presented === undefined) {
      return c.json(
        failure("unauthorized", "missing or malformed Authorization: Bearer header"),
        401,
      );
    }
    if (!tokensMatch(presented, apiKey)) {
      return c.json(failure("unauthorized", "invalid API key"), 401);
    }
    return next();
  };
}
