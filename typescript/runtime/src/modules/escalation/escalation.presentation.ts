// The wire presentation of an open escalation, folded into a sum ONCE at the service boundary
// (docs/2026-07-14-credentials-core.md §4) — so no rendering surface (console, CLI) ever sniffs request
// names itself; they all dispatch on this sum.

import type { JSONSchema } from "@katari-lang/types";
import { oauthAuthorizeArgumentOf } from "../../runtime/external/authorization-flow.js";
import { OAUTH_AUTHORIZE_REQUEST } from "../../runtime/external/credentials.js";
import type { Value } from "../../runtime/value/types.js";

/** How an escalation asks to be rendered: the ordinary schema-driven answer form, or an OAuth
 *  authorization (the `prelude.oauth.authorize` request — answered by completing the runtime-hosted flow,
 *  not by typing a value). `answerSchema` lives inside the form variant: an oauth escalation has no
 *  schema to interview against. The oauth variant's `url` is `null` for a `configured`-profile credential
 *  (an `oauth.token` acquisition), which authenticates against an operator-registered client and so has no
 *  server URL to show — a genuine absence, not a missing field; only an mcp credential names a server. */
export type EscalationPresentation =
  | { kind: "form"; answerSchema: JSONSchema | null }
  | { kind: "oauth"; name: string; url: string | null };

/** Fold one open escalation into its presentation. An authorize escalation whose argument does not carry a
 *  readable credential name (a damaged row — the argument is runtime-synthesized) degrades to the form
 *  variant rather than fabricating an OAuth card with nothing to authorize against. */
export function presentEscalation(
  escalation: { request: string; argument: Value | null },
  answerSchema: JSONSchema | null,
): EscalationPresentation {
  const oauthArgument =
    escalation.request === OAUTH_AUTHORIZE_REQUEST
      ? oauthAuthorizeArgumentOf(escalation.argument)
      : null;
  return oauthArgument === null
    ? { kind: "form", answerSchema }
    : { kind: "oauth", name: oauthArgument.name, url: oauthArgument.url };
}
