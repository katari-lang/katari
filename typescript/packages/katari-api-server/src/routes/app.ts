// Top-level Hono app. Composed in `bin.ts` with concrete services and
// reused by integration tests via `app.fetch(req)`.

import { Hono } from "hono";
import { ZodError } from "zod";
import type { AgentService } from "../services/agent-service.js";
import type { ModuleService } from "../services/module-service.js";
import type { Storage } from "../storage/types.js";
import { buildAgentRoutes } from "./agent.js";
import { buildAgentDefinitionRoutes } from "./agent-definition.js";
import { buildModuleRoutes } from "./module.js";
import { buildAuthMiddleware } from "./middleware/auth.js";
import {
  buildRateLimitMiddleware,
  type RateLimitOptions,
} from "./middleware/rate-limit.js";
import type { AppMetrics } from "../metrics.js";

export type AppDeps = {
  agents: AgentService;
  modules: ModuleService;
  /**
   * Storage used by `/readyz` to verify DB connectivity. Optional for
   * tests that don't care about the readiness probe.
   */
  storage?: Storage;
  /**
   * API key for Bearer authentication. If `null`, auth is disabled
   * entirely (used by tests). If `undefined`, the auth middleware fails
   * closed (503) — matching the bin entry's expectation that
   * `KATARI_API_KEY` must be set in production.
   */
  apiKey?: string | null;
  /**
   * Rate-limit configuration. If `null`, no rate limiting (used by tests
   * to avoid burst trips). If omitted, sensible defaults are applied.
   */
  rateLimit?: RateLimitOptions | null;
  /**
   * Optional metrics registry. When supplied, `/metrics` returns the
   * Prometheus-format text rendering of all registered metrics.
   */
  metrics?: AppMetrics;
};

const DEFAULT_RATE_LIMIT: RateLimitOptions = {
  capacity: 60,
  refillPerSecond: 1,
};

export function buildApp(deps: AppDeps): Hono {
  const app = new Hono();

  // Body-size limit applies before route matching: we cap at 10 MB so a
  // malicious upload can't exhaust memory before validation runs.
  app.use("*", async (c, next) => {
    const lengthHeader = c.req.header("content-length");
    if (lengthHeader !== undefined) {
      const length = Number.parseInt(lengthHeader, 10);
      if (Number.isFinite(length) && length > 10 * 1024 * 1024) {
        return c.json({ error: "request body too large (limit: 10 MB)" }, 413);
      }
    }
    return next();
  });

  // Top-level error handler: turn JSON parse failures and Zod validation
  // errors into 400, leave everything else as 500. Without this, malformed
  // JSON throws inside `c.req.json()` and surfaces as an opaque 500.
  app.onError((err, c) => {
    if (err instanceof ZodError) {
      return c.json(
        { error: "validation failed", issues: err.issues },
        400,
      );
    }
    if (err instanceof SyntaxError) {
      return c.json({ error: "invalid JSON in request body" }, 400);
    }
    // Unknown / runtime error — log via stderr (the framework default) and
    // surface a generic 500 so we don't leak internals.
    return c.json({ error: "internal server error" }, 500);
  });

  // Rate limit: applied before auth so an unauthenticated flooder also
  // gets throttled. `rateLimit: null` opts out (tests).
  if (deps.rateLimit !== null) {
    app.use("*", buildRateLimitMiddleware(deps.rateLimit ?? DEFAULT_RATE_LIMIT));
  }

  // Auth: skipped entirely when apiKey === null (tests). Otherwise the
  // middleware enforces Bearer auth and the `publicPathPrefixes` default
  // exempts /healthz, /readyz, /metrics.
  if (deps.apiKey !== null) {
    app.use("*", buildAuthMiddleware(deps.apiKey));
  }

  // Liveness: process is alive (always 200).
  app.get("/healthz", (c) => c.text("ok"));

  // Readiness: process can serve traffic. Probes DB connectivity if
  // storage was supplied. Failure → 503 so load balancers route around us.
  app.get("/readyz", async (c) => {
    if (deps.storage !== undefined) {
      try {
        await deps.storage.modules.list();
      } catch (err) {
        return c.json(
          {
            status: "not ready",
            reason: err instanceof Error ? err.message : "storage probe failed",
          },
          503,
        );
      }
    }
    return c.text("ok");
  });

  if (deps.metrics !== undefined) {
    app.get("/metrics", (c) => {
      return c.text(deps.metrics!.registry.render(), 200, {
        "content-type": "text/plain; version=0.0.4",
      });
    });
  }

  app.route("/module", buildModuleRoutes(deps.modules));
  app.route("/agent", buildAgentRoutes(deps.agents));
  app.route("/agent-definition", buildAgentDefinitionRoutes(deps.modules));
  return app;
}
