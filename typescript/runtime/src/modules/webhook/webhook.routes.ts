// The public inbound-webhook endpoint: `POST /inbound/:token` — the URLs `webhook.inbound` mints. It
// lives OUTSIDE the bearer-authenticated `/api` surface (an external webhook provider cannot present the
// runtime's key); the unguessable token is the capability, and its durable `capability_routes` row scopes
// it to exactly one endpoint of one project.
//
// The response contract is designed for third-party callers, not the console:
//   200 — the callback's result, RAW as the response body (so a program controls the exact reply — e.g. a
//         provider's URL-verification handshake echoes what the callback returns);
//   400 — the body is not JSON, or it does not conform to the callback's input schema (pre-validated —
//         `reflection.call_error`, the callback never ran, and the endpoint keeps serving);
//   404 — no endpoint serves this token; 410 — the endpoint is winding down (cancelled / settled);
//   500 — a residual internal error. A WELL-FORMED delivery whose callback throws or panics does NOT 500:
//         it proxies UP and cancels the endpoint (per-request resilience is the callback's own handler).

import type { Json } from "@katari-lang/types";
import { Hono } from "hono";
import { facade } from "../../runtime/facade.js";
import type { AppEnv } from "../../types/app-env.js";

export const inboundRoutes = new Hono<AppEnv>().post("/:token", async (c) => {
  const token = c.req.param("token");
  // An empty body is a `null` argument (some providers POST bare notifications); anything else must be JSON.
  const raw = await c.req.text();
  let body: Json = null;
  if (raw !== "") {
    try {
      body = JSON.parse(raw) as Json;
    } catch {
      return c.json({ error: "the request body is not JSON" }, 400);
    }
  }
  const outcome = await facade.deliverWebhook({ token, body });
  switch (outcome.kind) {
    case "unknown":
      return c.json({ error: "no inbound endpoint serves this token" }, 404);
    case "gone":
      return c.json({ error: "this inbound endpoint is no longer serving" }, 410);
    case "result":
      // Serialised by hand: the recursive `Json` type blows up Hono's typed `c.json`, and the raw body
      // (no envelope) is the contract here anyway.
      return c.newResponse(JSON.stringify(outcome.value), 200, {
        "Content-Type": "application/json",
      });
    case "rejected":
      // Rejected at the schema boundary — the callback never ran, so the delivery itself was bad.
      return c.json({ error: outcome.error }, 400);
    case "error":
      return c.json({ error: "the callback failed" }, 500);
  }
});
