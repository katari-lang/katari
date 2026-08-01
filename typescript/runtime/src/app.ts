import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { cors } from "hono/cors";
import { secureHeaders } from "hono/secure-headers";
import { config } from "./config/index.js";
import { success } from "./lib/response.js";
import { mountAdminWeb } from "./middleware/admin-web.js";
import { bearerAuth } from "./middleware/auth.js";
import { decompressRequest } from "./middleware/decompress.js";
import { errorHandler } from "./middleware/error-handler.js";
import { notFound } from "./middleware/not-found.js";
import { RequestLimiter, rateLimit } from "./middleware/rate-limit.js";
import { requestContext } from "./middleware/request-context.js";
import { mcpServeRoutes } from "./modules/mcp/mcp.routes.js";
import { oauthCallbackRoutes } from "./modules/oauth/oauth.routes.js";
import { inboundRoutes } from "./modules/webhook/webhook.routes.js";
import { apiRoutes } from "./routes.js";
import type { AppEnv } from "./types/app-env.js";

/**
 * The console's Content-Security-Policy. The console is served from the SAME origin as the API and holds the
 * bearer token in `localStorage`, so any script execution on this origin is a credential theft — the policy
 * is what keeps an injected URL or a future console bug from being one.
 *
 * `script-src 'self'` is strict: the console's one inline script (the pre-paint theme switch) was moved to
 * `/theme-init.js` so no `'unsafe-inline'` or hash is needed. `style-src` does allow inline, because React's
 * `style={{...}}` attributes are inline styles and there is no way around that short of rewriting them.
 * `connect-src 'self'` is what actually blunts an exfiltration attempt: a script that does run cannot post
 * the token anywhere off-origin.
 *
 * The Google Fonts origins are the one third-party exception. Self-hosting the fonts would remove it and is
 * worth doing; until then they are named explicitly rather than covered by a wildcard.
 */
const CONTENT_SECURITY_POLICY = {
  defaultSrc: ["'self'"],
  scriptSrc: ["'self'"],
  styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
  fontSrc: ["'self'", "https://fonts.gstatic.com", "data:"],
  imgSrc: ["'self'", "data:", "blob:"],
  connectSrc: ["'self'"],
  objectSrc: ["'none'"],
  baseUri: ["'self'"],
  frameAncestors: ["'none'"],
  formAction: ["'self'"],
};

/**
 * Application factory. Builds a fully wired Hono app: global middleware, the
 * error/404 boundaries, and the versioned API. Returning the chained instance
 * preserves route types so consumers can use the typed RPC client (`hc`).
 */
export function createApp() {
  const app = new Hono<AppEnv>();

  // Global middleware (order matters: context first so logging/ids are set).
  app.use("*", requestContext);
  app.use("*", secureHeaders({ contentSecurityPolicy: CONTENT_SECURITY_POLICY }));
  // `X-Total-Count` (the paged-list total) must be exposed, or a cross-origin console cannot read it off
  // the response — same-origin (the baked-in console) can already, but a separately-hosted one needs this.
  app.use("*", cors({ origin: config.corsOrigin, exposeHeaders: ["X-Total-Count"] }));

  // One limiter shared by the two things worth counting: requests to the unauthenticated capability
  // surfaces, and failed authentication. Both are attempts that cost the runtime a database round trip and
  // cost the caller nothing, which is the asymmetry a limiter exists to remove.
  const limiter = new RequestLimiter(config.limits.rateLimitPerMinute);

  // Bearer auth on every request (KATARI_API_KEY is required at boot). It exempts /api/v1/health and the
  // console's static assets — see `auth.ts`.
  app.use("*", bearerAuth(config.apiKey, limiter));

  // Boundaries.
  app.onError(errorHandler);
  app.notFound(notFound);

  // Body-size caps. Every surface that accepts a body has one: an unbounded read is a trivial
  // memory-exhaustion vector, and because one process hosts every project, exhausting it is an availability
  // problem for all of them rather than just for the caller.
  //
  // Three tiers, because the surfaces differ in what a legitimate body looks like:
  //   - the public capability endpoints (`/inbound`, `/mcp`) — 1 MiB is ample for a webhook delivery or an
  //     MCP JSON-RPC message, and these accept UNAUTHENTICATED bodies, so they get the tightest cap;
  //   - file uploads — deliberately generous, since uploading a real file is the point;
  //   - everything else under `/api` — a deploy buffers its body roughly three times over (raw text, the
  //     screening parse, the validator's), so the cap here is about that multiple, not about the body alone.
  const capabilityBodyLimit = bodyLimit({
    maxSize: 1024 * 1024,
    onError: (c) => c.json({ error: "the request body is too large" }, 413),
  });
  const uploadBodyLimit = bodyLimit({
    maxSize: config.limits.maxUploadBytes,
    onError: (c) => c.json({ error: "the uploaded file is too large" }, 413),
  });
  const apiBodyLimit = bodyLimit({
    maxSize: config.limits.maxRequestBytes,
    onError: (c) => c.json({ error: "the request body is too large" }, 413),
  });
  app.use("/inbound/*", capabilityBodyLimit);
  app.use("/mcp/*", capabilityBodyLimit);
  // The upload rules are registered before the general one so the more specific cap wins on those paths.
  app.use("/api/v1/projects/:projectId/files", uploadBodyLimit);
  app.use("/api/v1/projects/:projectId/ffi/:delegation/blobs", uploadBodyLimit);
  app.use("/api/*", apiBodyLimit);
  // …and then what those bytes expand to, for a caller that compressed them. The cap is the same
  // number: no request body exceeds it, whichever form it arrived in.
  //
  // Mounted on the authenticated subtree rather than on `/api/*`: every endpoint under `/api/v1` but
  // the public health probe lives beneath `/projects`, and expanding a body is work a caller should
  // have to authenticate to ask for — a few compressed kilobytes name as much memory as the cap allows.
  app.use("/api/v1/projects/*", decompressRequest({ maxSize: config.limits.maxRequestBytes }));

  // Rate-limit the surfaces that carry no bearer token at all.
  app.use("/inbound/*", rateLimit(limiter));
  app.use("/mcp/*", rateLimit(limiter));
  app.use("/oauth/*", rateLimit(limiter));

  // The public inbound-webhook endpoints (`webhook.inbound`'s minted URLs). Outside `/api`, so
  // `bearerAuth` passes them through — the unguessable token is the capability (see `webhook.routes.ts`).
  app.route("/inbound", inboundRoutes);

  // The public MCP serve endpoints (`mcp.serve`'s minted URLs) — the same capability-URL contract, the
  // token scoping one stateless MCP server to one live call (see `mcp.routes.ts`).
  app.route("/mcp", mcpServeRoutes);

  // The public OAuth redirect callback (`GET /oauth/callback`) — the identity provider sends the user's
  // browser here, which cannot carry a bearer token; the flow's minted `state` parameter is the
  // capability (see `oauth.routes.ts`).
  app.route("/oauth", oauthCallbackRoutes);

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
