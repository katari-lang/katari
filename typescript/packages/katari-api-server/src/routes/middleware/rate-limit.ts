// Per-IP token-bucket rate limiter.
//
// Self-contained — we don't pull in `hono-rate-limiter` because it's a
// thin wrapper over the same idea and the dependency adds little. The
// bucket is a small object stored in an LRU cache keyed by client IP.
// When the bucket fills (`tokens === 0` and the refill clock hasn't
// granted enough new tokens), the request is rejected with 429.

import type { Logger } from "@katari-lang/runtime";
import type { MiddlewareHandler } from "hono";
import { LRUCache } from "lru-cache";

export type RateLimitOptions = {
  /** Maximum tokens (= burst capacity) per IP. */
  capacity: number;
  /** Tokens refilled per second. */
  refillPerSecond: number;
  /** Max number of distinct IPs to track. Older entries fall out of the LRU. */
  maxClients?: number;
  /**
   * Path prefixes exempt from rate limiting. Health/metrics endpoints get
   * scraped frequently and shouldn't be throttled — a 429 to a load
   * balancer probe will mark the pod unhealthy and bin a perfectly fine
   * process.
   */
  publicPathPrefixes?: string[];
  /**
   * Optional logger. When provided, the limiter emits a one-time warning
   * the first time it falls back to the "__direct__" key (= no
   * x-forwarded-for header on a rate-limited request). That signals the
   * deployment is exposing the api-server directly rather than behind a
   * trusted reverse proxy, which makes the limiter a global cap.
   */
  logger?: Logger;
};

const DEFAULT_PUBLIC_PREFIXES: string[] = ["/healthz", "/readyz", "/metrics"];

type Bucket = {
  tokens: number;
  lastRefillMs: number;
};

/**
 * Build a Hono middleware that limits each client IP to `capacity` requests
 * per burst, refilling at `refillPerSecond`. The default capacity (10) /
 * refill (1/s) is conservative enough that legitimate clients won't notice
 * but pathological loops get rejected promptly.
 *
 * Client identification: we read the request URL and inspect the `x-forwarded-for`
 * header (first hop), falling back to a stable opaque "unknown" key. In a
 * deployment behind a trusted reverse proxy, that header is the actual
 * client; for direct exposure, every request shares the fallback key and
 * the limiter degenerates to a global cap. That's acceptable for the
 * single-tenant use cases this repo targets.
 */
export function buildRateLimitMiddleware(options: RateLimitOptions): MiddlewareHandler {
  const buckets = new LRUCache<string, Bucket>({
    max: options.maxClients ?? 10_000,
  });
  const publicPrefixes = options.publicPathPrefixes ?? DEFAULT_PUBLIC_PREFIXES;
  let warnedDirect = false;

  return async (c, next) => {
    const path = new URL(c.req.url).pathname;
    if (publicPrefixes.some((p) => path.startsWith(p))) {
      return next();
    }
    const key = clientKey(c.req.header("x-forwarded-for"));
    if (key === "__direct__" && !warnedDirect) {
      warnedDirect = true;
      options.logger?.log(
        "warn",
        "rate-limit: request without x-forwarded-for; the limiter is now a global cap. " +
          "Put api-server behind a reverse proxy that injects x-forwarded-for to get per-client limits.",
      );
    }
    const now = Date.now();
    const bucket = buckets.get(key) ?? {
      tokens: options.capacity,
      lastRefillMs: now,
    };

    // Refill: add tokens proportional to elapsed time, capped at capacity.
    const elapsedSec = (now - bucket.lastRefillMs) / 1000;
    bucket.tokens = Math.min(
      options.capacity,
      bucket.tokens + elapsedSec * options.refillPerSecond,
    );
    bucket.lastRefillMs = now;

    if (bucket.tokens < 1) {
      const retryAfterSec = Math.ceil((1 - bucket.tokens) / options.refillPerSecond);
      c.header("Retry-After", retryAfterSec.toString());
      return c.json({ error: "rate limit exceeded" }, 429);
    }
    bucket.tokens -= 1;
    buckets.set(key, bucket);
    return next();
  };
}

function clientKey(xForwardedFor: string | undefined): string {
  if (xForwardedFor === undefined) return "__direct__";
  // Take only the leftmost hop — the rest of the chain is added by intermediate proxies.
  const first = xForwardedFor.split(",")[0]?.trim();
  return first === undefined || first === "" ? "__direct__" : first;
}
