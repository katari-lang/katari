// Bearer-token authentication middleware.
//
// Requires `Authorization: Bearer <key>` where <key> matches the
// non-empty `apiKey` passed in. The boot path (`bin.ts`) refuses to
// start without `KATARI_API_KEY` set (or with the explicit opt-out
// `KATARI_API_KEY=disabled`, in which case `routes/app.ts` doesn't
// register this middleware at all). The 503 "server misconfigured"
// path is therefore unreachable from a properly-configured deployment;
// we reflect that by requiring a non-empty string at the type level.
//
// Constant-time string compare prevents the obvious timing oracle (the
// practical risk on a single-tenant API key is small but the cost of
// doing it right is one helper function).

import type { Context, MiddlewareHandler } from "hono";

export type AuthOptions = {
  /**
   * Routes whose path matches one of these prefixes bypass auth — used for
   * `/healthz` / `/readyz` / `/metrics` so monitoring doesn't need
   * credentials. Match is `path.startsWith(prefix)`.
   */
  publicPathPrefixes?: string[];
};

const DEFAULT_PUBLIC_PREFIXES: string[] = [
  "/healthz",
  "/readyz",
  "/metrics",
  // Admin SPA static assets — browsers can't attach Authorization to
  // <link>/<script> requests, so the auth boundary is the JSON API
  // (which the SPA hits with the Bearer header it gets from localStorage).
  "/admin",
];

/**
 * Build the auth middleware. `apiKey` must be a non-empty string;
 * empty / undefined is rejected as a programming error since the
 * boot path is responsible for filtering those out.
 */
export function buildAuthMiddleware(
  apiKey: string,
  options: AuthOptions = {},
): MiddlewareHandler {
  if (apiKey === "") {
    throw new Error(
      "buildAuthMiddleware: apiKey must be a non-empty string; bin.ts should have rejected an unset KATARI_API_KEY before reaching this point",
    );
  }
  const publicPrefixes = options.publicPathPrefixes ?? DEFAULT_PUBLIC_PREFIXES;
  return async (c: Context, next) => {
    const path = new URL(c.req.url).pathname;
    if (publicPrefixes.some((p) => path.startsWith(p))) {
      return next();
    }
    const header = c.req.header("Authorization");
    if (header === undefined) {
      return c.json({ error: "Authorization header is required" }, 401);
    }
    const match = /^Bearer\s+(.+)$/.exec(header);
    if (match === null) {
      return c.json({ error: "Authorization must be 'Bearer <token>'" }, 401);
    }
    const provided = match[1];
    if (!constantTimeEqual(provided, apiKey)) {
      return c.json({ error: "invalid API key" }, 401);
    }
    return next();
  };
}

/**
 * Length-aware constant-time string compare. Falls back to the simple
 * length-mismatch shortcut (the time difference between "lengths differ"
 * and "lengths equal" leaks the length of the secret, but the secret is
 * a fixed-length API key — there's no information value in revealing it).
 */
function constantTimeEqual(a: string | undefined, b: string): boolean {
  if (a === undefined) return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
