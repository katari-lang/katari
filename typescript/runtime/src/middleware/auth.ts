// Bearer-token authentication for the JSON API. A caller sends `Authorization: Bearer <key>`, and two kinds
// of credential are accepted:
//
//   - KATARI_API_KEY — the operator's key (the CLI, the web console). It opens every route. The comparison is
//     constant-time so the response latency does not leak how much of the key was correct.
//   - a SIDECAR token — minted per FFI sidecar process, scoped to one project and to the two blob-side-channel
//     paths (see `lib/sidecar-tokens.ts`). A sidecar runs user-authored (and possibly third-party) JavaScript,
//     so it must not hold the master key: anything it can read out of its own environment, a dependency can.
//
// Repeated failures are rate-limited per client address. The constant-time compare protects the key's
// CONTENT; nothing but this protects against simply making guesses quickly.
//
// Two kinds of request bypass auth, because neither can (or should) carry the header:
//   - `/api/v1/health` — liveness for the container healthcheck / load balancers / uptime monitors;
//   - everything that is NOT under `/api` — the admin console's own static assets (`/`, `/assets/*`,
//     the SPA shell). A browser cannot attach `Authorization` to a `<script>` / `<link>`, so the auth
//     boundary is the JSON API; the console loads publicly, then sends the bearer it holds (entered on
//     its login screen) with every `/api/v1` call.
//
// KATARI_API_KEY is required at boot (`config/env.ts`), so this middleware is mounted unconditionally on
// every request (see `app.ts`) — there is no "auth off" mode. It short-circuits only the public paths
// described above; every other request must present a credential.

import { timingSafeEqual } from "node:crypto";
import type { MiddlewareHandler } from "hono";
import { failure } from "../lib/response.js";
import { sidecarTokenAuthorizes } from "../lib/sidecar-tokens.js";
import type { AppEnv } from "../types/app-env.js";
import { clientKey, type RequestLimiter } from "./rate-limit.js";

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
export function bearerAuth(apiKey: string, limiter: RequestLimiter): MiddlewareHandler<AppEnv> {
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
    if (tokensMatch(presented, apiKey)) return next();
    // Not the operator's key. It may still be a sidecar's capability token — which authorises only its own
    // project's blob paths, so the check is of the whole request rather than of the credential alone.
    if (sidecarTokenAuthorizes(presented, c.req.method, c.req.path)) return next();
    // A wrong credential is the only path that costs anything to guess at, so it is the only one counted.
    if (!limiter.check(clientKey(c), Date.now())) {
      return c.json(failure("rate_limited", "too many failed authentication attempts"), 429);
    }
    return c.json(failure("unauthorized", "invalid API key"), 401);
  };
}
