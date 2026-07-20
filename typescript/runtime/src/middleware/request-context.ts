import { randomUUID } from "node:crypto";
import { createMiddleware } from "hono/factory";
import { config } from "../config/index.js";
import { createLogger } from "../lib/logger.js";
import type { AppEnv } from "../types/app-env.js";

const rootLogger = createLogger({ level: config.logLevel });

/** The public capability surfaces whose URL carries an unguessable token as a path segment: the token IS
 *  the secret (these routes are outside bearer auth), so it must never reach the logs in plaintext. One
 *  rule — a prefix map — covers both surfaces; a new capability surface adds one entry here, not a second
 *  special case. */
const CAPABILITY_ROUTE_PREFIXES = ["/mcp/", "/inbound/"] as const;

/** The request path with any capability token segment redacted, so a `/mcp/<token>` or `/inbound/<token>`
 *  URL logs as `/mcp/<redacted>` — the route shape kept, the secret withheld. Any other path logs verbatim. */
function loggablePath(path: string): string {
  for (const prefix of CAPABILITY_ROUTE_PREFIXES) {
    if (path.startsWith(prefix)) {
      const rest = path.slice(prefix.length);
      const nextSlash = rest.indexOf("/");
      const tail = nextSlash === -1 ? "" : rest.slice(nextSlash);
      return `${prefix}<redacted>${tail}`;
    }
  }
  return path;
}

/**
 * Assigns a request id and a request-scoped child logger, exposes the id back
 * to the client via `x-request-id`, and logs a completion line with latency.
 */
export const requestContext = createMiddleware<AppEnv>(async (c, next) => {
  const requestId = c.req.header("x-request-id") ?? randomUUID();
  const logger = rootLogger.child({
    requestId,
    method: c.req.method,
    // Redact a capability token in the path (see `loggablePath`) so it never lands in the logs plaintext.
    path: loggablePath(c.req.path),
  });

  c.set("requestId", requestId);
  c.set("logger", logger);
  c.header("x-request-id", requestId);

  const startedAt = performance.now();
  await next();
  const durationMs = Math.round((performance.now() - startedAt) * 100) / 100;
  logger.info("request completed", { status: c.res.status, durationMs });
});
