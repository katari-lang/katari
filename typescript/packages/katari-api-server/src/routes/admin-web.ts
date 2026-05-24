// Static file middleware for the katari-admin-web SPA build output.
//
// Mounting strategy: when `KATARI_ADMIN_WEB_DIST` points at a built
// `dist/` directory, serve everything under `/admin/*` from it. Unknown
// paths fall back to `index.html` so client-side routing (= history
// mode) works on page reload.
//
// Auth: the static assets themselves are public — browsers can't attach
// an Authorization header to <link>/<script> fetches. The SPA itself
// loads the user's API key from localStorage and adds the Bearer header
// to every API request, so the auth boundary stays where it belongs
// (= the JSON endpoints).

import { existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { extname, resolve } from "node:path";
import type { Hono, MiddlewareHandler } from "hono";
import type { Logger } from "@katari-lang/runtime";

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".map": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
};

function contentType(filePath: string): string {
  return CONTENT_TYPES[extname(filePath).toLowerCase()] ?? "application/octet-stream";
}

function buildAdminStatic(distPath: string): MiddlewareHandler {
  const absDist = resolve(distPath);
  const indexPath = resolve(absDist, "index.html");
  return async (c, next) => {
    if (c.req.method !== "GET" && c.req.method !== "HEAD") return next();
    const url = new URL(c.req.url);
    const path = url.pathname;
    if (!path.startsWith("/admin")) return next();
    // /admin and /admin/ both serve the SPA shell.
    const sub = path === "/admin" || path === "/admin/" ? "/index.html" : path.slice("/admin".length);
    const target = resolve(absDist, "." + sub);
    if (!target.startsWith(absDist)) {
      return c.notFound();
    }
    try {
      const stats = await stat(target);
      if (stats.isFile()) {
        const data = await readFile(target);
        return c.body(data, 200, { "content-type": contentType(target) });
      }
    } catch {
      // fall through to SPA fallback
    }
    // SPA history fallback: any unknown path under /admin/* serves
    // index.html. Asset paths with extensions still 404 (= we only
    // fall back for "looks like a route", not for missing image refs).
    if (extname(target) === "" || extname(target) === ".html") {
      try {
        const data = await readFile(indexPath);
        return c.html(data.toString());
      } catch {
        return c.notFound();
      }
    }
    return c.notFound();
  };
}

/**
 * Mount the admin web app at `/admin/*` if a build is available. No-op
 * (with a warning) when the dist path is missing — keeps boot working
 * for deployments that don't ship the UI.
 */
export function mountAdminWeb(
  app: Hono,
  distPath: string | null,
  logger: Logger,
): void {
  if (distPath === null) return;
  if (!existsSync(resolve(distPath, "index.html"))) {
    logger.log("warn", "admin web dist path has no index.html; skipping mount", {
      distPath,
    });
    return;
  }
  app.use("*", buildAdminStatic(distPath));
  logger.log("info", "admin web mounted at /admin/*", { distPath });
}
