import { randomUUID } from "node:crypto";
import { createMiddleware } from "hono/factory";
import { config } from "../config/index.js";
import { createLogger } from "../lib/logger.js";
import type { AppEnv } from "../types/app-env.js";

const rootLogger = createLogger({ level: config.logLevel });

/**
 * Assigns a request id and a request-scoped child logger, exposes the id back
 * to the client via `x-request-id`, and logs a completion line with latency.
 */
export const requestContext = createMiddleware<AppEnv>(async (c, next) => {
  const requestId = c.req.header("x-request-id") ?? randomUUID();
  const logger = rootLogger.child({
    requestId,
    method: c.req.method,
    path: c.req.path,
  });

  c.set("requestId", requestId);
  c.set("logger", logger);
  c.header("x-request-id", requestId);

  const startedAt = performance.now();
  await next();
  const durationMs = Math.round((performance.now() - startedAt) * 100) / 100;
  logger.info("request completed", { status: c.res.status, durationMs });
});
