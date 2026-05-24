// Top-level Hono app. Composed in `bin.ts` with concrete services and
// reused by integration tests via `app.fetch(req)`.

import type { Logger } from "@katari-lang/runtime";
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { ZodError } from "zod";
import type { Storage } from "../storage/types.js";
import type { ProjectService } from "../services/project-service.js";
import type { SnapshotService } from "../services/snapshot-service.js";
import type { Orchestrator } from "../orchestrator.js";
import { buildAgentRoutes } from "./agent.js";
import { buildAgentByIdRoutes } from "./agent-by-id.js";
import { buildEnvRoutes } from "./env.js";
import { buildEscalationRoutes } from "./escalation.js";
import { buildEscalationByIdRoutes } from "./escalation-by-id.js";
import { buildProjectRoutes } from "./project.js";
import { buildSnapshotRoutes } from "./snapshot.js";
import { buildAuthMiddleware } from "./middleware/auth.js";
import { mountAdminWeb } from "./admin-web.js";
import {
  buildRateLimitMiddleware,
  type RateLimitOptions,
} from "./middleware/rate-limit.js";
import type { AppMetrics } from "../metrics.js";

export type AppDeps = {
  storage: Storage;
  projects: ProjectService;
  snapshots: SnapshotService;
  orchestrator: Orchestrator;
  logger: Logger;
  /**
   * `null` = auth disabled (`KATARI_API_KEY=disabled`, dev only).
   * Non-empty string = the bearer token to require. `undefined` or
   * empty is rejected: bin.ts is responsible for funneling those
   * cases into the fail-fast exit path.
   */
  apiKey: string | null;
  rateLimit?: RateLimitOptions | null;
  metrics?: AppMetrics;
  /**
   * Absolute or process-cwd-relative path to a built katari-admin-web
   * `dist/` directory. When set, the SPA is served from `/admin/*`. `null`
   * (= default) skips the mount entirely so deployments that don't ship
   * the UI keep working unchanged.
   */
  adminWebDistPath?: string | null;
};

const DEFAULT_RATE_LIMIT: RateLimitOptions = {
  capacity: 60,
  refillPerSecond: 1,
};

export function buildApp(deps: AppDeps): Hono {
  const app = new Hono();

  // Body-size guard. Hono's `bodyLimit` streams the request and
  // aborts as soon as the byte count exceeds the cap, so this works
  // both for Content-Length-bearing requests AND for chunked transfer
  // / missing-header clients (= the prior advisory check that we
  // documented as a known bypass is now properly closed).
  const BODY_LIMIT_BYTES = 10 * 1024 * 1024;
  app.use(
    "*",
    bodyLimit({
      maxSize: BODY_LIMIT_BYTES,
      onError: (c) =>
        c.json({ error: "request body too large (limit: 10 MB)" }, 413),
    }),
  );

  app.onError((err, c) => {
    if (err instanceof ZodError) {
      return c.json({ error: "validation failed", issues: err.issues }, 400);
    }
    if (err instanceof SyntaxError) {
      return c.json({ error: "invalid JSON in request body" }, 400);
    }
    // Any other exception bubbling up here is a real server bug — log
    // it loudly so operators can diagnose. Without this the route would
    // return `{"error":"internal server error"}` with zero trace in
    // `docker logs`, making prod issues impossible to triage.
    deps.logger.log("error", "unhandled exception in route handler", {
      method: c.req.method,
      path: c.req.path,
      error: err instanceof Error ? err.message : String(err),
      stack: err instanceof Error ? err.stack : undefined,
    });
    return c.json({ error: "internal server error" }, 500);
  });

  if (deps.rateLimit !== null) {
    const opts = deps.rateLimit ?? DEFAULT_RATE_LIMIT;
    app.use("*", buildRateLimitMiddleware({ ...opts, logger: deps.logger }));
  }

  if (deps.apiKey !== null) {
    app.use("*", buildAuthMiddleware(deps.apiKey));
  }

  // Mount the admin SPA BEFORE the JSON routes so that, after the auth
  // middleware lets `/admin/*` through, the static handler can respond
  // without needing to fall through the route chain.
  mountAdminWeb(app, deps.adminWebDistPath ?? null, deps.logger);

  app.get("/healthz", (c) => c.text("ok"));

  app.get("/readyz", async (c) => {
    try {
      await deps.storage.projects.list({ limit: 1 });
    } catch (err) {
      return c.json(
        {
          status: "not ready",
          reason: err instanceof Error ? err.message : "storage probe failed",
        },
        503,
      );
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

  // Routes reflect the data hierarchy: project owns snapshots and any
  // runtime artifact (= agents, escalations); snapshots own their
  // compiled schema (= agent-definitions). Env is runtime-global.
  app.route("/project", buildProjectRoutes(deps.projects));
  app.route(
    "/project/:projectId/snapshot",
    buildSnapshotRoutes(deps.snapshots),
  );
  app.route(
    "/project/:projectId/agent",
    buildAgentRoutes(deps.orchestrator, deps.storage),
  );
  app.route(
    "/project/:projectId/escalation",
    buildEscalationRoutes(deps.orchestrator, deps.storage),
  );
  // Flat single-entity aliases for the CLI / scripts that already hold a
  // UUID and don't need the navigation hierarchy.
  app.route("/agent", buildAgentByIdRoutes(deps.orchestrator, deps.storage));
  app.route(
    "/escalation",
    buildEscalationByIdRoutes(deps.orchestrator, deps.storage),
  );
  app.route("/env", buildEnvRoutes(deps.storage));

  return app;
}
