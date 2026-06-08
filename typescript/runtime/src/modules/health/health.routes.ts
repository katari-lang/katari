import { Hono } from "hono";
import { success } from "../../lib/response.js";
import type { AppEnv } from "../../types/app-env.js";

export const healthRoutes = new Hono<AppEnv>().get("/", (c) =>
  c.json(
    success({
      status: "healthy" as const,
      uptime: Math.round(process.uptime()),
      timestamp: new Date().toISOString(),
    }),
  ),
);
