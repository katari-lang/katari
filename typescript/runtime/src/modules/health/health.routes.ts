// Liveness probe. Deliberately DB-independent: postgres.js connects lazily, so the server can boot
// and report healthy while Postgres is still coming up (the Dockerfile HEALTHCHECK and orchestrators
// poll this). A readiness probe that actually pings the database can come later as a separate route.

import { Hono } from "hono";
import { success } from "../../lib/response.js";
import type { AppEnv } from "../../types/app-env.js";

// Captured once at module load; the process start time the uptime is measured from.
const startedAt = performance.now();

export const healthRoutes = new Hono<AppEnv>().get("/health", (c) =>
  c.json(
    success({
      status: "ok",
      uptimeSeconds: Math.round((performance.now() - startedAt) / 1000),
    }),
  ),
);
