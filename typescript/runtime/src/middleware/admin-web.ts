// Serve the built admin console at the server root, coexisting with the JSON API under `/api`. Only wired
// when a dist directory is configured: the runtime image bakes the console in and points
// `KATARI_ADMIN_WEB_DIST` at it, so one container serves both the UI and the API on one origin (the
// console's `/api/v1` fetches are same-origin, no proxy). A source checkout leaves it unset and runs the
// console from its own vite dev server instead.
//
// Two layers, both skipping `/api/*` so the API's own 404s stay JSON:
//   - static assets straight from the dist (hashed `/assets/*`, favicon, ...);
//   - an `index.html` history fallback for every other path, so client-side routes (`/runs/:id`, ...)
//     survive a deep-link / refresh.

import { serveStatic } from "@hono/node-server/serve-static";
import type { Hono } from "hono";
import type { AppEnv } from "../types/app-env.js";

const isApiPath = (path: string): boolean => path === "/api" || path.startsWith("/api/");

export function mountAdminWeb(app: Hono<AppEnv>, distPath: string | undefined): void {
  if (distPath === undefined) return;
  const asset = serveStatic({ root: distPath });
  const indexHtml = serveStatic({ path: "index.html", root: distPath });
  // A real file in the dist (serveStatic falls through to `next` when there is none).
  app.use("*", (c, next) => (isApiPath(c.req.path) ? next() : asset(c, next)));
  // Anything else that is a GET (not the API) is a client-side route → the SPA shell.
  app.get("*", (c, next) => (isApiPath(c.req.path) ? next() : indexHtml(c, next)));
}
