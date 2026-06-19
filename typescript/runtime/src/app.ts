import { Hono } from "hono";
import { cors } from "hono/cors";
import { secureHeaders } from "hono/secure-headers";
import { config } from "./config/index.js";
import { success } from "./lib/response.js";
import { errorHandler } from "./middleware/error-handler.js";
import { notFound } from "./middleware/not-found.js";
import { requestContext } from "./middleware/request-context.js";
import { apiRoutes } from "./routes.js";
import type { AppEnv } from "./types/app-env.js";

/**
 * Application factory. Builds a fully wired Hono app: global middleware, the
 * error/404 boundaries, and the versioned API. Returning the chained instance
 * preserves route types so consumers can use the typed RPC client (`hc`).
 */
export function createApp() {
  const app = new Hono<AppEnv>();

  // Global middleware (order matters: context first so logging/ids are set).
  app.use("*", requestContext);
  app.use("*", secureHeaders());
  app.use("*", cors({ origin: config.corsOrigin }));

  // Boundaries.
  app.onError(errorHandler);
  app.notFound(notFound);

  return app
    .get("/", (c) => c.json(success({ name: "katari-api-server", api: "/api/v1" })))
    .route("/api/v1", apiRoutes);
}

/** Route type for the end-to-end typed RPC client (`hc<AppType>(...)`). */
export type AppType = ReturnType<typeof createApp>;
