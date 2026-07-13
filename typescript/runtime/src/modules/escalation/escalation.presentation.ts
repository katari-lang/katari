// The wire presentation of an open escalation, folded into a sum ONCE at the service boundary
// (docs/2026-07-13-oauth-escalation.md §4) — so no rendering surface (console, CLI) ever sniffs request
// names itself; they all dispatch on this sum.

import type { JSONSchema } from "@katari-lang/types";
import { mcpAuthorizeArgumentOf } from "../../runtime/external/mcp-authorization-flow.js";
import { MCP_AUTHORIZE_REQUEST } from "../../runtime/external/mcp-oauth.js";
import type { Value } from "../../runtime/value/types.js";

/** How an escalation asks to be rendered: the ordinary schema-driven answer form, or an OAuth
 *  authorization (the `prelude.mcp.authorize` request — answered by completing the runtime-hosted flow,
 *  not by typing a value). `answerSchema` lives inside the form variant: an oauth escalation has no
 *  schema to interview against. */
export type EscalationPresentation =
  | { kind: "form"; answerSchema: JSONSchema | null }
  | { kind: "oauth"; url: string; name: string };

/** Fold one open escalation into its presentation. An authorize escalation whose argument does not carry
 *  the `{ url, name }` payload (a damaged row — the argument is runtime-synthesized) degrades to the form
 *  variant rather than fabricating an OAuth card with nothing to authorize against. */
export function presentEscalation(
  escalation: { request: string; argument: Value | null },
  answerSchema: JSONSchema | null,
): EscalationPresentation {
  const oauthArgument =
    escalation.request === MCP_AUTHORIZE_REQUEST
      ? mcpAuthorizeArgumentOf(escalation.argument)
      : null;
  return oauthArgument === null
    ? { kind: "form", answerSchema }
    : { kind: "oauth", url: oauthArgument.url, name: oauthArgument.name };
}
