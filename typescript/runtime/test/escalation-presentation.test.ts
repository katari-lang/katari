// The wire presentation sum: the ONE place a request name becomes a rendering decision
// (docs/2026-07-13-oauth-escalation.md §4). Every escalation is either a schema-driven `form`
// (the answer schema moved inside this variant) or an `oauth` authorization card carrying the
// `{ name, url }` its flow runs against — `url` is null for a configured credential (no server URL, a
// genuine absence). No surface downstream sniffs `prelude.oauth.authorize` itself.

import { describe, expect, test } from "vitest";
import { presentEscalation } from "../src/modules/escalation/escalation.presentation.js";
import { OAUTH_AUTHORIZE_REQUEST } from "../src/runtime/external/credentials.js";
import type { Value } from "../src/runtime/value/types.js";

const AUTHORIZE_ARGUMENT: Value = {
  kind: "record",
  fields: {
    url: { kind: "string", value: "https://mcp.example.test/mcp" },
    name: { kind: "string", value: "github" },
  },
};

/** A configured-credential authorize argument — a name with no server url. */
const CONFIGURED_AUTHORIZE_ARGUMENT: Value = {
  kind: "record",
  fields: { name: { kind: "string", value: "stripe" } },
};

describe("presentEscalation", () => {
  test("an ordinary request is a form carrying its answer schema", () => {
    const schema = { type: "string" as const };
    expect(
      presentEscalation({ request: "app.approve", argument: null }, schema),
    ).toEqual({ kind: "form", answerSchema: schema });
  });

  test("an ordinary request with no derivable schema is a form with answerSchema null", () => {
    expect(presentEscalation({ request: "app.approve", argument: null }, null)).toEqual({
      kind: "form",
      answerSchema: null,
    });
  });

  test("an mcp authorize request presents as oauth with its { name, url } payload", () => {
    expect(
      presentEscalation({ request: OAUTH_AUTHORIZE_REQUEST, argument: AUTHORIZE_ARGUMENT }, null),
    ).toEqual({ kind: "oauth", name: "github", url: "https://mcp.example.test/mcp" });
  });

  test("a configured authorize request presents as oauth with a null url (a genuine absence)", () => {
    expect(
      presentEscalation(
        { request: OAUTH_AUTHORIZE_REQUEST, argument: CONFIGURED_AUTHORIZE_ARGUMENT },
        null,
      ),
    ).toEqual({ kind: "oauth", name: "stripe", url: null });
  });

  test("an authorize row with an unreadable argument degrades to the form variant", () => {
    // The argument is runtime-synthesized, so this is damage handling: better an inert generic form
    // than an OAuth card whose flow has nothing to authorize against.
    expect(presentEscalation({ request: OAUTH_AUTHORIZE_REQUEST, argument: null }, null)).toEqual({
      kind: "form",
      answerSchema: null,
    });
  });

  test("an ordinary request whose argument merely looks authorize-shaped stays a form", () => {
    expect(
      presentEscalation({ request: "app.approve", argument: AUTHORIZE_ARGUMENT }, null),
    ).toEqual({ kind: "form", answerSchema: null });
  });
});
