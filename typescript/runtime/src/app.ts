import { Hono } from "hono";
import { cors } from "hono/cors";
import { secureHeaders } from "hono/secure-headers";
import { config } from "./config/index.js";
import { success } from "./lib/response.js";
import { mountAdminWeb } from "./middleware/admin-web.js";
import { bearerAuth } from "./middleware/auth.js";
import { errorHandler } from "./middleware/error-handler.js";
import { notFound } from "./middleware/not-found.js";
import { requestContext } from "./middleware/request-context.js";
import { inboundRoutes } from "./modules/webhook/webhook.routes.js";
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
  // `X-Total-Count` (the paged-list total) must be exposed, or a cross-origin console cannot read it off
  // the response — same-origin (the baked-in console) can already, but a separately-hosted one needs this.
  app.use("*", cors({ origin: config.corsOrigin, exposeHeaders: ["X-Total-Count"] }));

  // Bearer auth on every request (KATARI_API_KEY is required at boot). It exempts /api/v1/health and the
  // console's static assets — see `auth.ts`.
  app.use("*", bearerAuth(config.apiKey));

  // Boundaries.
  app.onError(errorHandler);
  app.notFound(notFound);

  // The public inbound-webhook endpoints (`webhook.inbound`'s minted URLs). Outside `/api`, so
  // `bearerAuth` passes them through — the unguessable token is the capability (see `webhook.routes.ts`).
  app.route("/inbound", inboundRoutes);

  const api = app.route("/api/v1", apiRoutes);

  // The image bakes the console in and serves it at the root; a source checkout has no built dist, so the
  // root falls back to the JSON info (the console runs from its own vite dev server there). Either way the
  // API stays under `/api/v1`, so the returned type — what the RPC client binds to — is the same.
  if (!mountAdminWeb(api)) {
    api.get("/", (c) => c.json(success({ name: "katari-api-server", api: "/api/v1" })));
  }
  return api;
}

/** Route type for the end-to-end typed RPC client (`hc<AppType>(...)`). */
export type AppType = ReturnType<typeof createApp>;
