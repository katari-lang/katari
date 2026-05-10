// Top-level Hono app. Composed in `bin.ts` with concrete services and
// reused by integration tests via `app.fetch(req)`.

import { Hono } from "hono";
import { ZodError } from "zod";
import type { Storage } from "../storage/types.js";
import type { ProjectService } from "../services/project-service.js";
import type { SnapshotService } from "../services/snapshot-service.js";
import type { Orchestrator } from "../orchestrator.js";
import { buildAgentRoutes } from "./agent.js";
import { buildAgentDefinitionRoutes } from "./agent-definition.js";
import { buildEscalationRoutes } from "./escalation.js";
import { buildProjectRoutes } from "./project.js";
import { buildSnapshotRoutes } from "./snapshot.js";
import { buildAuthMiddleware } from "./middleware/auth.js";
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
  apiKey?: string | null;
  rateLimit?: RateLimitOptions | null;
  metrics?: AppMetrics;
};

const DEFAULT_RATE_LIMIT: RateLimitOptions = {
  capacity: 60,
  refillPerSecond: 1,
};

export function buildApp(deps: AppDeps): Hono {
  const app = new Hono();

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

  app.onError((err, c) => {
    if (err instanceof ZodError) {
      return c.json({ error: "validation failed", issues: err.issues }, 400);
    }
    if (err instanceof SyntaxError) {
      return c.json({ error: "invalid JSON in request body" }, 400);
    }
    return c.json({ error: "internal server error" }, 500);
  });

  if (deps.rateLimit !== null) {
    app.use("*", buildRateLimitMiddleware(deps.rateLimit ?? DEFAULT_RATE_LIMIT));
  }

  if (deps.apiKey !== null) {
    app.use("*", buildAuthMiddleware(deps.apiKey));
  }

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

  app.route("/project", buildProjectRoutes(deps.projects));
  app.route(
    "/project/:projectId/snapshot",
    buildSnapshotRoutes(deps.snapshots),
  );
  app.route(
    "/agent",
    buildAgentRoutes(deps.orchestrator, deps.snapshots, deps.storage),
  );
  app.route("/agent-definition", buildAgentDefinitionRoutes(deps.snapshots));
  app.route("/escalation", buildEscalationRoutes(deps.orchestrator, deps.storage));

  return app;
}
