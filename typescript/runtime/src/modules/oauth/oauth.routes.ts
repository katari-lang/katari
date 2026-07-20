// The two HTTP faces of the runtime-hosted OAuth flow:
//
//   - `oauthFlowRoutes` (mounted under the bearer-authenticated `/api/v1`): start the flow for one open
//     `prelude.oauth.authorize` escalation and hand back the authorization URL for the caller (console,
//     CLI) to open. 404 when the escalation is not open, 409 when it is not an oauth escalation.
//   - `oauthCallbackRoutes` (mounted PUBLIC at `/oauth`, like `/inbound` and `/mcp`): the identity
//     provider redirects the user's browser here; the minted `state` parameter is the capability that
//     locates the pending flow, so no bearer token is involved. The response is a small self-contained
//     HTML page (no external assets) — the reader is a human in a browser tab, not an API client.

import { Hono } from "hono";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AuthorizationCallbackOutcome } from "../../runtime/external/authorization-flow.js";
import type { AppEnv } from "../../types/app-env.js";
import { escalationParamSchema } from "../escalation/escalation.schema.js";
import { authorizationFlow } from "./oauth.service.js";

/** Escape user-influenced text for the HTML pages: the credential name is project data and the failure
 *  reason can echo identity-provider strings, so neither may reach the page unescaped. */
function escapeHtml(text: string): string {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** The minimal self-contained page the callback answers with — inline style only, because the strict
 *  contract here is "no external assets" (the page must render with no reachable runtime origin). */
function callbackPage(heading: string, escapedBody: string): string {
  return [
    "<!doctype html>",
    '<html lang="en">',
    '<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>Katari OAuth</title>",
    "<style>",
    "body{font-family:system-ui,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0;background:#f4f4f5;color:#18181b}",
    "main{max-width:28rem;margin:1rem;padding:2rem;background:#fff;border-radius:.5rem;box-shadow:0 1px 4px rgba(0,0,0,.08)}",
    "h1{font-size:1.25rem;margin-top:0}p{line-height:1.6;margin-bottom:0}",
    "</style></head>",
    `<body><main><h1>${heading}</h1><p>${escapedBody}</p></main></body></html>`,
  ].join("\n");
}

function renderCallbackOutcome(outcome: AuthorizationCallbackOutcome): {
  status: 200 | 400;
  page: string;
} {
  switch (outcome.kind) {
    case "authorized":
      return {
        status: 200,
        page: callbackPage(
          "Authorized",
          `The credential "${escapeHtml(outcome.name)}" is stored. You can close this tab and ` +
            "return to your app or terminal — the waiting run resumes on its own.",
        ),
      };
    case "failed":
      return {
        status: 400,
        page: callbackPage(
          "Authorization failed",
          `${escapeHtml(outcome.reason)}. You can close this tab and restart the authorization ` +
            "from the escalation.",
        ),
      };
  }
}

// The escalation-driven login: a thin derivation over the proactive flow — the service reads `{ name, url? }`
// off the escalation argument and calls the same `startForCredential`.
export const oauthFlowRoutes = new Hono<AppEnv>().post(
  "/projects/:projectId/escalations/:escalationId/oauth-flow",
  zValidator("param", escalationParamSchema),
  async (c) => {
    const { projectId, escalationId } = c.req.valid("param");
    return c.json(success(await authorizationFlow.startFromEscalation(projectId, escalationId)));
  },
);

export const oauthCallbackRoutes = new Hono<AppEnv>().get("/callback", async (c) => {
  const outcome = await authorizationFlow.handleCallback({
    code: c.req.query("code"),
    state: c.req.query("state"),
    error: c.req.query("error"),
    errorDescription: c.req.query("error_description"),
  });
  const { status, page } = renderCallbackOutcome(outcome);
  return c.html(page, status);
});
