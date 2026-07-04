// Serve the built admin console at the server root, coexisting with the JSON API under `/api`, so one
// container serves both the UI and the API on one origin (the console's `/api/v1` fetches are
// same-origin, no proxy). The dist lives at a fixed path next to the runtime (`admin-web/dist`, relative
// to the working directory): the image bakes the built console there, so the console appears with no
// configuration; a source checkout has no such directory, so `mountAdminWeb` no-ops and the console runs
// from its own vite dev server instead.
//
// Two layers, both skipping `/api/*` so the API's own 404s stay JSON:
//   - static assets straight from the dist (hashed `/assets/*`, favicon, ...);
//   - an `index.html` history fallback for every other path, so client-side routes (`/runs/:id`, ...)
//     survive a deep-link / refresh.

import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { serveStatic } from "@hono/node-server/serve-static";
import type { Hono } from "hono";
import type { AppEnv } from "../types/app-env.js";

/** Where the image bakes the console, relative to the runtime's working directory (`/app` there). */
const ADMIN_WEB_DIST = resolve("admin-web/dist");

const isApiPath = (path: string): boolean => path === "/api" || path.startsWith("/api/");

/** Mount the console at the root when its built dist is present (the image), and report whether it was.
 *  When absent (a source checkout) this is a no-op and the caller keeps the JSON info root. */
export function mountAdminWeb(app: Hono<AppEnv>): boolean {
  if (!existsSync(join(ADMIN_WEB_DIST, "index.html"))) return false;
  const asset = serveStatic({ root: ADMIN_WEB_DIST });
  const indexHtml = serveStatic({ path: "index.html", root: ADMIN_WEB_DIST });
  // A real file in the dist (serveStatic falls through to `next` when there is none).
  app.use("*", (c, next) => (isApiPath(c.req.path) ? next() : asset(c, next)));
  // Anything else that is a GET (not the API) is a client-side route → the SPA shell.
  app.get("*", (c, next) => (isApiPath(c.req.path) ? next() : indexHtml(c, next)));
  return true;
}
