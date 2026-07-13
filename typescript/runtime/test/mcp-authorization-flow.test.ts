// The runtime-hosted OAuth flow, end to end against a fake identity provider: round 1 (discovery +
// dynamic registration + PKCE + the captured authorization URL) and round 2 (the callback's code
// exchange → credential deposit → answering every open authorize escalation waiting on that name).
// The IdP is a live loopback HTTP server (metadata / registration / token endpoints) so the SDK's
// `auth(...)` orchestrator runs for real; only the human-in-a-browser hop is simulated — the test
// reads the authorization URL's parameters and mints the code the way the IdP would. The escalation
// side is stubbed (a lister + answerer): what the flow DOES to escalations is this suite's subject,
// how they persist is the engine's.

import { createHash, randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { ConflictError, NotFoundError } from "../src/lib/errors.js";
import {
  AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS,
  type AuthorizationCallbackOutcome,
  createMcpAuthorizationFlow,
  type McpAuthorizationFlow,
  mcpAuthorizeArgumentOf,
  type OpenEscalationCandidate,
} from "../src/runtime/external/mcp-authorization-flow.js";
import { MCP_AUTHORIZE_REQUEST, type McpOAuthCredential } from "../src/runtime/external/mcp-oauth.js";
import type { Value } from "../src/runtime/value/types.js";

const PUBLIC_URL = "https://runtime.example.test";
const CALLBACK_URL = `${PUBLIC_URL}/oauth/callback`;

// ─── the fake identity provider ───────────────────────────────────────────────────────────────────

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (chunk: string) => {
      raw += chunk;
    });
    request.on("end", () => resolve(raw));
    request.on("error", reject);
  });
}

function respondJson(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

/** The S256 code-challenge transform, applied server-side to verify the exchanged verifier. */
function sha256Base64Url(input: string): string {
  return createHash("sha256").update(input).digest("base64url");
}

let identityProvider: Server;
let identityProviderBase = "";
/** The MCP server URL escalations name — the flow discovers the IdP from it (root fallback). */
let mcpServerUrl = "";
/** Codes this "IdP" has minted, with what the token endpoint must verify them against. */
const issuedCodes = new Map<string, { codeChallenge: string; redirectUri: string; clientId: string }>();
/** Every client registration body the IdP accepted, for asserting the public-client metadata. */
const registeredClients: Array<Record<string, unknown>> = [];
/** Every access token the IdP issued, for asserting the deposit carries the real token. */
const issuedAccessTokens: string[] = [];

beforeAll(async () => {
  identityProvider = createServer((request, response) => {
    void (async () => {
      const url = new URL(request.url ?? "/", "http://127.0.0.1");
      if (request.method === "GET" && url.pathname === "/.well-known/oauth-authorization-server") {
        respondJson(response, 200, {
          issuer: identityProviderBase,
          authorization_endpoint: `${identityProviderBase}/authorize`,
          token_endpoint: `${identityProviderBase}/token`,
          registration_endpoint: `${identityProviderBase}/register`,
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["none"],
        });
        return;
      }
      if (request.method === "POST" && url.pathname === "/register") {
        const requested: Record<string, unknown> = JSON.parse(await readBody(request));
        const clientId = `client-${randomUUID()}`;
        registeredClients.push({ ...requested, client_id: clientId });
        respondJson(response, 201, {
          ...requested,
          client_id: clientId,
          client_id_issued_at: Math.floor(Date.now() / 1000),
        });
        return;
      }
      if (request.method === "POST" && url.pathname === "/token") {
        const parameters = new URLSearchParams(await readBody(request));
        const issued = issuedCodes.get(parameters.get("code") ?? "");
        const verifierMatches =
          issued !== undefined &&
          sha256Base64Url(parameters.get("code_verifier") ?? "") === issued.codeChallenge;
        const requestMatches =
          issued !== undefined &&
          parameters.get("grant_type") === "authorization_code" &&
          parameters.get("redirect_uri") === issued.redirectUri &&
          parameters.get("client_id") === issued.clientId;
        if (!verifierMatches || !requestMatches) {
          respondJson(response, 400, {
            error: "invalid_grant",
            error_description: "the code, verifier, redirect_uri, or client did not match",
          });
          return;
        }
        issuedCodes.delete(parameters.get("code") ?? "");
        const accessToken = `access-${randomUUID()}`;
        issuedAccessTokens.push(accessToken);
        respondJson(response, 200, {
          access_token: accessToken,
          token_type: "bearer",
          expires_in: 3600,
          refresh_token: `refresh-${randomUUID()}`,
        });
        return;
      }
      // Everything else (including protected-resource metadata) is 404: the SDK then falls back to
      // treating the server's own origin as the authorization server, which this fake is.
      respondJson(response, 404, { error: "not_found" });
    })().catch(() => {
      if (!response.headersSent) response.writeHead(500).end();
    });
  });
  await new Promise<void>((resolve) => identityProvider.listen(0, "127.0.0.1", resolve));
  const address = identityProvider.address() as AddressInfo;
  identityProviderBase = `http://127.0.0.1:${address.port}`;
  mcpServerUrl = `${identityProviderBase}/mcp`;
});

afterAll(async () => {
  identityProvider.closeAllConnections();
  await new Promise<void>((resolve) => {
    identityProvider.close(() => resolve());
  });
});

/** Simulate the human's browser hop: the IdP authenticates the user at the authorization URL and
 *  redirects back with a fresh code bound to that URL's PKCE challenge / redirect_uri / client. */
function authorizeAtIdentityProvider(authorizationUrl: string): { code: string; state: string } {
  const url = new URL(authorizationUrl);
  expect(url.origin).toBe(identityProviderBase);
  expect(url.pathname).toBe("/authorize");
  expect(url.searchParams.get("response_type")).toBe("code");
  expect(url.searchParams.get("code_challenge_method")).toBe("S256");
  expect(url.searchParams.get("redirect_uri")).toBe(CALLBACK_URL);
  const code = `code-${randomUUID()}`;
  issuedCodes.set(code, {
    codeChallenge: url.searchParams.get("code_challenge") ?? "",
    redirectUri: url.searchParams.get("redirect_uri") ?? "",
    clientId: url.searchParams.get("client_id") ?? "",
  });
  return { code, state: url.searchParams.get("state") ?? "" };
}

// ─── the flow harness (stubbed escalation side) ───────────────────────────────────────────────────

function authorizeArgument(url: string, name: string): Value {
  return {
    kind: "record",
    fields: {
      url: { kind: "string", value: url },
      name: { kind: "string", value: name },
    },
  };
}

function authorizeEscalation(id: string, url: string, name: string): OpenEscalationCandidate {
  return { id, request: MCP_AUTHORIZE_REQUEST, argument: authorizeArgument(url, name) };
}

interface FlowHarness {
  flow: McpAuthorizationFlow;
  openEscalations: OpenEscalationCandidate[];
  deposits: Array<{ projectId: string; name: string; credential: McpOAuthCredential }>;
  answered: string[];
  warnings: Array<{ message: string; context: Record<string, unknown> }>;
  clock: { now: number };
  /** Ids whose answer call should fail, to exercise the best-effort per-row contract. */
  failingAnswers: Set<string>;
  /** When set, the next deposit throws it — the "database down after the state is burned" case. */
  depositFailure: { error: Error | null };
}

function flowHarness(): FlowHarness {
  const openEscalations: OpenEscalationCandidate[] = [];
  const deposits: Array<{ projectId: string; name: string; credential: McpOAuthCredential }> = [];
  const answered: string[] = [];
  const warnings: Array<{ message: string; context: Record<string, unknown> }> = [];
  const failingAnswers = new Set<string>();
  const depositFailure: { error: Error | null } = { error: null };
  const clock = { now: 1_000_000 };
  const flow = createMcpAuthorizationFlow({
    publicUrl: PUBLIC_URL,
    loadOpenEscalation: async (_projectId, escalationId) =>
      openEscalations.find((escalation) => escalation.id === escalationId),
    listOpenEscalations: async () => openEscalations,
    depositCredential: async (projectId, name, credential) => {
      if (depositFailure.error !== null) {
        throw depositFailure.error;
      }
      deposits.push({ projectId, name, credential });
    },
    answerEscalation: async (_projectId, escalationId) => {
      if (failingAnswers.has(escalationId)) {
        throw new Error(`escalation ${escalationId} already settled`);
      }
      answered.push(escalationId);
    },
    warn: (message, context) => {
      warnings.push({ message, context });
    },
    now: () => clock.now,
  });
  return {
    flow,
    openEscalations,
    deposits,
    answered,
    warnings,
    clock,
    failingAnswers,
    depositFailure,
  };
}

function expectFailed(outcome: AuthorizationCallbackOutcome): string {
  if (outcome.kind !== "failed") {
    throw new Error(`expected a failed outcome, got ${outcome.kind}`);
  }
  return outcome.reason;
}

// ─── mcpAuthorizeArgumentOf ───────────────────────────────────────────────────────────────────────

describe("mcpAuthorizeArgumentOf", () => {
  test("reads { url, name } out of the authorize argument", () => {
    expect(mcpAuthorizeArgumentOf(authorizeArgument("https://mcp.example.test", "github"))).toEqual(
      { url: "https://mcp.example.test", name: "github" },
    );
  });

  test.each<[string, Value | null]>([
    ["a null argument", null],
    ["a non-record argument", { kind: "string", value: "github" }],
    [
      "a record missing the name",
      { kind: "record", fields: { url: { kind: "string", value: "https://x.test" } } },
    ],
    [
      "a record whose url is not a string",
      {
        kind: "record",
        fields: { url: { kind: "integer", value: 1 }, name: { kind: "string", value: "github" } },
      },
    ],
  ])("%s is unreadable (null)", (_label, argument) => {
    expect(mcpAuthorizeArgumentOf(argument)).toBeNull();
  });
});

// ─── round 1: start ───────────────────────────────────────────────────────────────────────────────

describe("start", () => {
  test("an unknown (or already answered) escalation is 404", async () => {
    const { flow } = flowHarness();
    await expect(flow.start("project-1", "missing")).rejects.toThrowError(NotFoundError);
  });

  test("an open escalation of another request is 409 — nothing OAuth-shaped to start", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push({ id: "form-1", request: "app.approve", argument: null });
    await expect(flow.start("project-1", "form-1")).rejects.toThrowError(ConflictError);
  });

  test("an authorize escalation with an unreadable argument is 409", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push({ id: "broken-1", request: MCP_AUTHORIZE_REQUEST, argument: null });
    await expect(flow.start("project-1", "broken-1")).rejects.toThrowError(ConflictError);
  });

  test("registers a public client and returns the IdP authorization URL", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.start("project-1", "esc-1");

    const url = new URL(authorizationUrl);
    expect(url.origin).toBe(identityProviderBase);
    expect(url.searchParams.get("redirect_uri")).toBe(CALLBACK_URL);
    expect(url.searchParams.get("state")).not.toBeNull();
    expect(url.searchParams.get("code_challenge")).not.toBeNull();
    // The registration that produced this client is the helper's public-client shape.
    const registered = registeredClients.at(-1);
    expect(registered?.token_endpoint_auth_method).toBe("none");
    expect(registered?.grant_types).toEqual(["authorization_code", "refresh_token"]);
    expect(registered?.redirect_uris).toEqual([CALLBACK_URL]);
    expect(url.searchParams.get("client_id")).toBe(registered?.client_id);
  }, 20000);
});

// ─── round 2: the callback ────────────────────────────────────────────────────────────────────────

describe("handleCallback", () => {
  test("exchanges the code, deposits the triple, and answers every waiting authorize escalation", async () => {
    const { flow, openEscalations, deposits, answered } = flowHarness();
    openEscalations.push(
      authorizeEscalation("esc-started", mcpServerUrl, "github"),
      // A second ask waiting on the SAME credential is answered by the same completion…
      authorizeEscalation("esc-same-name", mcpServerUrl, "github"),
      // …while a different credential name and a non-authorize escalation are left open.
      authorizeEscalation("esc-other-name", mcpServerUrl, "gitlab"),
      { id: "esc-form", request: "app.approve", argument: null },
    );

    const { authorizationUrl } = await flow.start("project-1", "esc-started");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome).toEqual({ kind: "authorized", name: "github" });
    expect(deposits).toHaveLength(1);
    const deposit = deposits[0];
    expect(deposit?.projectId).toBe("project-1");
    expect(deposit?.name).toBe("github");
    expect(deposit?.credential.resourceUrl).toBe(mcpServerUrl);
    expect(deposit?.credential.tokens.access_token).toBe(issuedAccessTokens.at(-1));
    expect(deposit?.credential.tokens.refresh_token).toBeDefined();
    expect(deposit?.credential.clientInformation.client_id).toBe(
      registeredClients.at(-1)?.client_id,
    );
    expect(answered.sort()).toEqual(["esc-same-name", "esc-started"]);
  }, 20000);

  test("one settled escalation does not fail the page or the other acks — but is logged loudly", async () => {
    const { flow, openEscalations, answered, warnings, failingAnswers } = flowHarness();
    openEscalations.push(
      authorizeEscalation("esc-a", mcpServerUrl, "github"),
      authorizeEscalation("esc-b", mcpServerUrl, "github"),
    );
    failingAnswers.add("esc-a");

    const { authorizationUrl } = await flow.start("project-1", "esc-b");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome.kind).toBe("authorized");
    expect(answered).toEqual(["esc-b"]);
    // The swallow is deliberate, but if the failure was transient the run stays parked behind an
    // "Authorized" page — so the operator must be able to see which escalation went unanswered.
    expect(warnings).toHaveLength(1);
    expect(warnings[0]?.context.escalationId).toBe("esc-a");
    expect(warnings[0]?.context.credentialName).toBe("github");
  }, 20000);

  test("a deposit failure after the state is burned renders the failure card, not a bare 500", async () => {
    const { flow, openEscalations, deposits, answered, depositFailure } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));
    depositFailure.error = new Error("the database is unreachable");

    const { authorizationUrl } = await flow.start("project-1", "esc-1");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const reason = expectFailed(
      await flow.handleCallback({ code, state, error: undefined, errorDescription: undefined }),
    );

    // A value, not a throw — the route renders it as the HTML card with the restart hint.
    expect(reason).toContain("depositing the credential");
    expect(reason).toContain("the database is unreachable");
    expect(deposits).toHaveLength(0);
    expect(answered).toHaveLength(0);
    // The escalation is still open, so pressing Authorize again mints a fresh, working flow.
    depositFailure.error = null;
    const { authorizationUrl: secondUrl } = await flow.start("project-1", "esc-1");
    const second = authorizeAtIdentityProvider(secondUrl);
    const retried = await flow.handleCallback({
      code: second.code,
      state: second.state,
      error: undefined,
      errorDescription: undefined,
    });
    expect(retried.kind).toBe("authorized");
    expect(deposits).toHaveLength(1);
  }, 20000);

  test("restarting a flow supersedes the previous one for the same escalation", async () => {
    const { flow, openEscalations, deposits } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const first = await flow.start("project-1", "esc-1");
    const firstRedirect = authorizeAtIdentityProvider(first.authorizationUrl);
    const second = await flow.start("project-1", "esc-1");
    const secondRedirect = authorizeAtIdentityProvider(second.authorizationUrl);

    // The first state died when the second flow was minted — an abandoned authorization URL must not
    // stay independently redeemable until its TTL.
    const stale = expectFailed(
      await flow.handleCallback({
        code: firstRedirect.code,
        state: firstRedirect.state,
        error: undefined,
        errorDescription: undefined,
      }),
    );
    expect(stale).toContain("unknown, expired, or already used");
    expect(deposits).toHaveLength(0);

    // The superseding flow is the one that redeems.
    const fresh = await flow.handleCallback({
      code: secondRedirect.code,
      state: secondRedirect.state,
      error: undefined,
      errorDescription: undefined,
    });
    expect(fresh.kind).toBe("authorized");
    expect(deposits).toHaveLength(1);
  }, 20000);

  test("an unknown state is refused (the state parameter is the capability)", async () => {
    const { flow } = flowHarness();
    const reason = expectFailed(
      await flow.handleCallback({
        code: "code-x",
        state: "never-minted",
        error: undefined,
        errorDescription: undefined,
      }),
    );
    expect(reason).toContain("unknown, expired, or already used");
  });

  test("a missing state is refused", async () => {
    const { flow } = flowHarness();
    const reason = expectFailed(
      await flow.handleCallback({
        code: "code-x",
        state: undefined,
        error: undefined,
        errorDescription: undefined,
      }),
    );
    expect(reason).toContain("no state");
  });

  test("a state is single-use: the second redemption is refused", async () => {
    const { flow, openEscalations, deposits } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.start("project-1", "esc-1");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const first = await flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });
    expect(first.kind).toBe("authorized");

    const replay = expectFailed(
      await flow.handleCallback({ code, state, error: undefined, errorDescription: undefined }),
    );
    expect(replay).toContain("unknown, expired, or already used");
    expect(deposits).toHaveLength(1);
  }, 20000);

  test("an IdP refusal consumes the flow and reports the reason", async () => {
    const { flow, openEscalations, deposits } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.start("project-1", "esc-1");
    const { state } = authorizeAtIdentityProvider(authorizationUrl);
    const reason = expectFailed(
      await flow.handleCallback({
        code: undefined,
        state,
        error: "access_denied",
        errorDescription: "the user pressed cancel",
      }),
    );
    expect(reason).toContain("access_denied");
    expect(reason).toContain("the user pressed cancel");
    expect(deposits).toHaveLength(0);

    // The refusal consumed the entry: retrying the same state is now unknown.
    const retry = expectFailed(
      await flow.handleCallback({
        code: "code-late",
        state,
        error: undefined,
        errorDescription: undefined,
      }),
    );
    expect(retry).toContain("unknown, expired, or already used");
  }, 20000);

  test("a redirect without a code is refused", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.start("project-1", "esc-1");
    const { state } = authorizeAtIdentityProvider(authorizationUrl);
    const reason = expectFailed(
      await flow.handleCallback({
        code: undefined,
        state,
        error: undefined,
        errorDescription: undefined,
      }),
    );
    expect(reason).toContain("no authorization code");
  }, 20000);

  test("a rejected exchange (a code the IdP never minted) fails as a value, not a throw", async () => {
    const { flow, openEscalations, deposits } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.start("project-1", "esc-1");
    const { state } = authorizeAtIdentityProvider(authorizationUrl);
    const reason = expectFailed(
      await flow.handleCallback({
        code: "forged-code",
        state,
        error: undefined,
        errorDescription: undefined,
      }),
    );
    expect(reason).toContain("token exchange failed");
    expect(deposits).toHaveLength(0);
  }, 20000);

  test("an expired flow is swept: the callback after the TTL is refused", async () => {
    const { flow, openEscalations, clock } = flowHarness();
    openEscalations.push(authorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.start("project-1", "esc-1");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    clock.now += AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS + 1;

    const reason = expectFailed(
      await flow.handleCallback({ code, state, error: undefined, errorDescription: undefined }),
    );
    expect(reason).toContain("unknown, expired, or already used");
  }, 20000);
});
