// Bearer-token authentication middleware.
//
// Reads `KATARI_API_KEY` from env at startup. If unset, the middleware
// rejects every non-health request with 503 (misconfigured) — we do *not*
// allow a "no auth" mode to silently slip into production.
//
// Requests must carry `Authorization: Bearer <key>`. Constant-time string
// compare prevents the obvious timing oracle (the practical risk on a
// single-tenant API key is small but the cost of doing it right is one
// helper function).

import type { Context, MiddlewareHandler } from "hono";

export type AuthOptions = {
  /**
   * Routes whose path matches one of these prefixes bypass auth — used for
   * `/healthz` / `/readyz` / `/metrics` so monitoring doesn't need
   * credentials. Match is `path.startsWith(prefix)`.
   */
  publicPathPrefixes?: string[];
};

const DEFAULT_PUBLIC_PREFIXES: string[] = ["/healthz", "/readyz", "/metrics"];

/**
 * Build the auth middleware.
 *
 * `apiKey` is read from the caller (typically `process.env.KATARI_API_KEY`)
 * so tests can inject a known value without touching environment variables.
 * If `apiKey` is `undefined` *or* empty string, the middleware fails closed:
 * every gated request gets 503. This matches the bin entry's expectation
 * that the operator sets the env var before launch.
 */
export function buildAuthMiddleware(
  apiKey: string | undefined,
  options: AuthOptions = {},
): MiddlewareHandler {
  const publicPrefixes = options.publicPathPrefixes ?? DEFAULT_PUBLIC_PREFIXES;
  return async (c: Context, next) => {
    const path = new URL(c.req.url).pathname;
    if (publicPrefixes.some((p) => path.startsWith(p))) {
      return next();
    }
    if (apiKey === undefined || apiKey === "") {
      return c.json(
        { error: "server misconfigured: KATARI_API_KEY is not set" },
        503,
      );
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
