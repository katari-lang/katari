// A fixed-window request limiter for the surfaces that carry no bearer token, and for failed authentication.
//
// What this is and is not for. The capability tokens minted for `/inbound` and `/mcp` are 192-bit CSPRNG
// values, so this is NOT what makes them unguessable — nothing needs to. It is about the COST of an attempt:
// every request to those paths, valid token or not, costs a database round trip against a ten-connection
// pool, so an unauthenticated flood can starve not just the API but the actor substrate's own commits. The
// same reasoning covers failed `Authorization` attempts, which are otherwise free to make at network speed.
//
// The window is per client address and in memory, which is the honest scope: it bounds one runtime process,
// and behind a load balancer the address it sees may be the balancer's rather than the caller's. That makes
// it a backstop against accidental floods and casual abuse, not a substitute for a WAF in front. It is
// deliberately not stored in the database — a limiter that itself hits the pool would defeat its own purpose.

import { getConnInfo } from "@hono/node-server/conninfo";
import type { MiddlewareHandler } from "hono";
import { failure } from "../lib/response.js";
import type { AppEnv } from "../types/app-env.js";

const WINDOW_MS = 60_000;

/** One client's counter for the window it started. */
interface Window {
  count: number;
  startedAt: number;
}

/** A counter keyed by client, reset once a window elapses. Entries for idle clients are swept lazily on
 *  write so the map cannot grow without bound under a flood of distinct addresses. */
export class RequestLimiter {
  private readonly windows = new Map<string, Window>();

  constructor(private readonly limitPerMinute: number) {}

  /** Count one request from `key` and report whether it is within the limit. */
  check(key: string, now: number): boolean {
    this.sweep(now);
    const window = this.windows.get(key);
    if (window === undefined || now - window.startedAt >= WINDOW_MS) {
      this.windows.set(key, { count: 1, startedAt: now });
      return true;
    }
    window.count += 1;
    return window.count <= this.limitPerMinute;
  }

  /** Drop windows that have elapsed. Cheap because it only runs on a write and only walks expired entries. */
  private sweep(now: number): void {
    for (const [key, window] of this.windows) {
      if (now - window.startedAt >= WINDOW_MS) this.windows.delete(key);
    }
  }
}

/** The client address a window is keyed by, falling back to a single shared bucket when the platform cannot
 *  report one — degrading to "limit everyone together" is safer than degrading to "limit no one". */
export function clientKey(context: Parameters<MiddlewareHandler<AppEnv>>[0]): string {
  try {
    return getConnInfo(context).remote.address ?? "unknown";
  } catch {
    return "unknown";
  }
}

/** Rate-limit the unauthenticated capability surfaces. Mounted on `/inbound` and `/mcp` in `app.ts`. */
export function rateLimit(limiter: RequestLimiter): MiddlewareHandler<AppEnv> {
  return async (context, next) => {
    if (!limiter.check(clientKey(context), Date.now())) {
      return context.json(failure("rate_limited", "too many requests"), 429);
    }
    return next();
  };
}
