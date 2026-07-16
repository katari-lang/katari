// The runtime-hosted OAuth flow, end to end against a fake identity provider — both acquisition profiles.
//
//   - the `mcp` profile (a server url present): discovery + dynamic registration + PKCE + the captured
//     authorization URL, then the callback's code exchange. The IdP is a live loopback HTTP server
//     (metadata / registration / token endpoints) so the SDK's `auth(...)` orchestrator runs for real.
//   - the `configured` profile (no url): a plain OAuth 2.1 authorization-code + PKCE request against an
//     operator-registered client (endpoints, client id, optional secret, scopes) — no discovery, no
//     registration — then the code exchange at the registered token endpoint (client_secret_basic when the
//     client is confidential, PKCE always).
//
// Only the human-in-a-browser hop is simulated (the test reads the authorization URL's parameters and mints
// the code the way the IdP would). The escalation side is stubbed (a lister + answerer): what the flow DOES
// to escalations — deposit + answer every open authorize row for the (project, name), zero rows fine (a
// proactive login is a pure deposit) — is this suite's subject; how they persist is the engine's.

import { createHash, randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { BadRequestError, ConflictError, NotFoundError } from "../src/lib/errors.js";
import {
  AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS,
  type AuthorizationCallbackOutcome,
  type AuthorizationFlow,
  createAuthorizationFlow,
  oauthAuthorizeArgumentOf,
  type OpenEscalationCandidate,
  type RegisteredClient,
} from "../src/runtime/external/authorization-flow.js";
import {
  OAUTH_AUTHORIZE_REQUEST,
  type StoredCredential,
} from "../src/runtime/external/credentials.js";
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

/** How one token exchange authenticated its client — recorded so a test can assert the profile's client
 *  authentication (a public client puts its id in the body; a confidential one uses HTTP Basic). */
interface TokenExchangeRecord {
  clientAuth: "basic" | "body";
  clientId: string;
  clientSecret: string | null;
  verifierMatched: boolean;
}

let identityProvider: Server;
let identityProviderBase = "";
/** The MCP server URL escalations name — the flow discovers the IdP from it (root fallback). */
let mcpServerUrl = "";
/** Codes this "IdP" has minted, with what the token endpoint must verify them against. */
const issuedCodes = new Map<
  string,
  { codeChallenge: string; redirectUri: string; clientId: string }
>();
/** Every client registration body the IdP accepted, for asserting the public-client metadata. */
const registeredClients: Array<Record<string, unknown>> = [];
/** Every access token the IdP issued, for asserting the deposit carries the real token. */
const issuedAccessTokens: string[] = [];
/** Every token exchange the IdP handled, for asserting the configured profile's client authentication. */
const tokenExchanges: TokenExchangeRecord[] = [];

/** Decode an `Authorization: Basic base64(id:secret)` header into its client credentials, or null. */
function decodeBasicAuth(header: string | undefined): { id: string; secret: string } | null {
  if (header === undefined || !header.startsWith("Basic ")) return null;
  const decoded = Buffer.from(header.slice("Basic ".length), "base64").toString("utf8");
  const separator = decoded.indexOf(":");
  if (separator < 0) return null;
  return { id: decoded.slice(0, separator), secret: decoded.slice(separator + 1) };
}

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
          token_endpoint_auth_methods_supported: ["none", "client_secret_basic"],
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
        // The client authenticates by HTTP Basic (a confidential / configured-secret client) or by its
        // id in the body (a public client — mcp DCR, or a public configured client).
        const basic = decodeBasicAuth(request.headers.authorization);
        const clientAuth: "basic" | "body" = basic !== null ? "basic" : "body";
        const clientId = basic !== null ? basic.id : (parameters.get("client_id") ?? "");
        const issued = issuedCodes.get(parameters.get("code") ?? "");
        const verifierMatched =
          issued !== undefined &&
          sha256Base64Url(parameters.get("code_verifier") ?? "") === issued.codeChallenge;
        tokenExchanges.push({
          clientAuth,
          clientId,
          clientSecret: basic !== null ? basic.secret : null,
          verifierMatched,
        });
        const requestMatches =
          issued !== undefined &&
          parameters.get("grant_type") === "authorization_code" &&
          parameters.get("redirect_uri") === issued.redirectUri &&
          clientId === issued.clientId;
        if (!verifierMatched || !requestMatches) {
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

// ─── the flow harness (stubbed escalation + registry side) ──────────────────────────────────────────

/** An mcp-profile authorize argument (a server url + a name). */
function mcpAuthorizeArgument(url: string, name: string): Value {
  return {
    kind: "record",
    fields: { url: { kind: "string", value: url }, name: { kind: "string", value: name } },
  };
}

/** A configured-profile authorize argument (a name only — no server url). */
function configuredAuthorizeArgument(name: string): Value {
  return { kind: "record", fields: { name: { kind: "string", value: name } } };
}

function mcpAuthorizeEscalation(id: string, url: string, name: string): OpenEscalationCandidate {
  return { id, request: OAUTH_AUTHORIZE_REQUEST, argument: mcpAuthorizeArgument(url, name) };
}

interface FlowHarness {
  flow: AuthorizationFlow;
  openEscalations: OpenEscalationCandidate[];
  clients: Map<string, RegisteredClient>;
  deposits: Array<{ projectId: string; name: string; credential: StoredCredential }>;
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
  const clients = new Map<string, RegisteredClient>();
  const deposits: Array<{ projectId: string; name: string; credential: StoredCredential }> = [];
  const answered: string[] = [];
  const warnings: Array<{ message: string; context: Record<string, unknown> }> = [];
  const failingAnswers = new Set<string>();
  const depositFailure: { error: Error | null } = { error: null };
  const clock = { now: 1_000_000 };
  const flow = createAuthorizationFlow({
    publicUrl: PUBLIC_URL,
    loadOpenEscalation: async (_projectId, escalationId) =>
      openEscalations.find((escalation) => escalation.id === escalationId),
    listOpenEscalations: async () => openEscalations,
    loadClientConfig: async (_projectId, name) => clients.get(name) ?? null,
    depositCredential: async (projectId, name, credential) => {
      if (depositFailure.error !== null) throw depositFailure.error;
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
    clients,
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

/** Register a configured client whose endpoints point at the fake IdP. A `secret` of `null` is a public
 *  client (a genuine absence, PKCE only); `authorizationParameters` are the extra authorize-URL query
 *  parameters the registry row carries (default none). */
function registerClient(
  harness: FlowHarness,
  name: string,
  clientId: string,
  secret: string | null,
  authorizationParameters: Record<string, string> = {},
): void {
  harness.clients.set(name, {
    authorizeEndpoint: `${identityProviderBase}/authorize`,
    tokenEndpoint: `${identityProviderBase}/token`,
    clientId,
    clientSecret: secret,
    scopes: ["read"],
    authorizationParameters,
  });
}

// ─── oauthAuthorizeArgumentOf ───────────────────────────────────────────────────────────────────────

describe("oauthAuthorizeArgumentOf", () => {
  test("reads { url, name } out of an mcp authorize argument", () => {
    expect(
      oauthAuthorizeArgumentOf(mcpAuthorizeArgument("https://mcp.example.test", "github")),
    ).toEqual({ url: "https://mcp.example.test", name: "github" });
  });

  test("a configured argument has a name and a null url (a genuine absence of a server)", () => {
    expect(oauthAuthorizeArgumentOf(configuredAuthorizeArgument("stripe"))).toEqual({
      url: null,
      name: "stripe",
    });
  });

  test.each<[string, Value | null]>([
    ["a null argument", null],
    ["a non-record argument", { kind: "string", value: "github" }],
    ["a record missing the name", { kind: "record", fields: {} }],
    [
      "a record whose name is not a string",
      { kind: "record", fields: { name: { kind: "integer", value: 1 } } },
    ],
  ])("%s is unreadable (null)", (_label, argument) => {
    expect(oauthAuthorizeArgumentOf(argument)).toBeNull();
  });
});

// ─── the escalation-driven login (startFromEscalation) ──────────────────────────────────────────────

describe("startFromEscalation", () => {
  test("an unknown (or already answered) escalation is 404", async () => {
    const { flow } = flowHarness();
    await expect(flow.startFromEscalation("project-1", "missing")).rejects.toThrowError(
      NotFoundError,
    );
  });

  test("an open escalation of another request is 409 — nothing OAuth-shaped to start", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push({ id: "form-1", request: "app.approve", argument: null });
    await expect(flow.startFromEscalation("project-1", "form-1")).rejects.toThrowError(
      ConflictError,
    );
  });

  test("an authorize escalation with an unreadable argument is 409", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push({ id: "broken-1", request: OAUTH_AUTHORIZE_REQUEST, argument: null });
    await expect(flow.startFromEscalation("project-1", "broken-1")).rejects.toThrowError(
      ConflictError,
    );
  });

  test("an mcp escalation registers a public client and returns the IdP authorization URL", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");

    const url = new URL(authorizationUrl);
    expect(url.origin).toBe(identityProviderBase);
    expect(url.searchParams.get("redirect_uri")).toBe(CALLBACK_URL);
    expect(url.searchParams.get("state")).not.toBeNull();
    expect(url.searchParams.get("code_challenge")).not.toBeNull();
    const registered = registeredClients.at(-1);
    expect(registered?.token_endpoint_auth_method).toBe("none");
    expect(registered?.grant_types).toEqual(["authorization_code", "refresh_token"]);
    expect(registered?.redirect_uris).toEqual([CALLBACK_URL]);
    expect(url.searchParams.get("client_id")).toBe(registered?.client_id);
  }, 20000);

  test("a configured escalation (no url) reads the registered client — no discovery, no registration", async () => {
    const harness = flowHarness();
    registerClient(harness, "stripe", "conf-public", null);
    harness.openEscalations.push({
      id: "esc-conf",
      request: OAUTH_AUTHORIZE_REQUEST,
      argument: configuredAuthorizeArgument("stripe"),
    });
    const registrationsBefore = registeredClients.length;

    const { authorizationUrl } = await harness.flow.startFromEscalation("project-1", "esc-conf");

    const url = new URL(authorizationUrl);
    expect(url.pathname).toBe("/authorize");
    expect(url.searchParams.get("client_id")).toBe("conf-public");
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("scope")).toBe("read");
    // A configured flow does NOT dynamically register — it uses the operator's registered client.
    expect(registeredClients.length).toBe(registrationsBefore);
  });
});

// ─── the mcp-profile callback ───────────────────────────────────────────────────────────────────────

describe("handleCallback (mcp profile)", () => {
  test("exchanges the code, deposits the credential, and answers every waiting authorize escalation", async () => {
    const { flow, openEscalations, deposits, answered } = flowHarness();
    openEscalations.push(
      mcpAuthorizeEscalation("esc-started", mcpServerUrl, "github"),
      // A second ask waiting on the SAME credential is answered by the same completion…
      mcpAuthorizeEscalation("esc-same-name", mcpServerUrl, "github"),
      // …while a different credential name and a non-authorize escalation are left open.
      mcpAuthorizeEscalation("esc-other-name", mcpServerUrl, "gitlab"),
      { id: "esc-form", request: "app.approve", argument: null },
    );

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-started");
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
    const credential = deposit?.credential;
    if (credential === undefined || credential.profile !== "mcp") {
      throw new Error("expected an mcp-profile credential deposit");
    }
    expect(credential.resourceUrl).toBe(mcpServerUrl);
    expect(credential.accessToken).toBe(issuedAccessTokens.at(-1));
    expect(credential.refreshToken).toBeDefined();
    // The token endpoint is captured at acquisition (the crux) so the core refreshes without re-discovery.
    expect(credential.tokenEndpoint).toBe(`${identityProviderBase}/token`);
    // The grant's `expires_in: 3600` is stamped against the flow's clock: 1_000_000 + 3600 * 1000.
    expect(credential.expiresAt).toBe(1_000_000 + 3_600_000);
    expect(credential.clientInformation.client_id).toBe(registeredClients.at(-1)?.client_id);
    expect(answered.sort()).toEqual(["esc-same-name", "esc-started"]);
  }, 20000);

  test("one settled escalation does not fail the page or the other acks — but is logged loudly", async () => {
    const { flow, openEscalations, answered, warnings, failingAnswers } = flowHarness();
    openEscalations.push(
      mcpAuthorizeEscalation("esc-a", mcpServerUrl, "github"),
      mcpAuthorizeEscalation("esc-b", mcpServerUrl, "github"),
    );
    failingAnswers.add("esc-a");

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-b");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome.kind).toBe("authorized");
    expect(answered).toEqual(["esc-b"]);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]?.context.escalationId).toBe("esc-a");
    expect(warnings[0]?.context.credentialName).toBe("github");
  }, 20000);

  test("a deposit failure after the state is burned renders the failure card, not a bare 500", async () => {
    const { flow, openEscalations, deposits, answered, depositFailure } = flowHarness();
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));
    depositFailure.error = new Error("the database is unreachable");

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const reason = expectFailed(
      await flow.handleCallback({ code, state, error: undefined, errorDescription: undefined }),
    );

    expect(reason).toContain("depositing the credential");
    expect(reason).toContain("the database is unreachable");
    expect(deposits).toHaveLength(0);
    expect(answered).toHaveLength(0);
    depositFailure.error = null;
    const { authorizationUrl: secondUrl } = await flow.startFromEscalation("project-1", "esc-1");
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
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");
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
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");
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
  }, 20000);

  test("a redirect without a code is refused", async () => {
    const { flow, openEscalations } = flowHarness();
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");
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
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");
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
    openEscalations.push(mcpAuthorizeEscalation("esc-1", mcpServerUrl, "github"));

    const { authorizationUrl } = await flow.startFromEscalation("project-1", "esc-1");
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    clock.now += AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS + 1;

    const reason = expectFailed(
      await flow.handleCallback({ code, state, error: undefined, errorDescription: undefined }),
    );
    expect(reason).toContain("unknown, expired, or already used");
  }, 20000);
});

// ─── the configured profile ─────────────────────────────────────────────────────────────────────────

describe("configured profile", () => {
  test("a public client: authorization-code + PKCE, client id in the token body (no secret)", async () => {
    const harness = flowHarness();
    registerClient(harness, "stripe", "conf-public", null);
    tokenExchanges.length = 0;

    const { authorizationUrl } = await harness.flow.startForCredential(
      "project-1",
      "stripe",
      undefined,
    );
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await harness.flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome).toEqual({ kind: "authorized", name: "stripe" });
    const credential = harness.deposits[0]?.credential;
    if (credential === undefined || credential.profile !== "configured") {
      throw new Error("expected a configured-profile credential deposit");
    }
    // The credential carries the registered token endpoint + the client NAME, so the core refresh reads
    // the registry (a rotated secret takes effect) rather than embedding client material.
    expect(credential.clientName).toBe("stripe");
    expect(credential.tokenEndpoint).toBe(`${identityProviderBase}/token`);
    expect(credential.accessToken).toBe(issuedAccessTokens.at(-1));
    // A public client authenticates with its id in the body (no Basic), and PKCE always verified.
    const exchange = tokenExchanges.at(-1);
    expect(exchange?.clientAuth).toBe("body");
    expect(exchange?.clientId).toBe("conf-public");
    expect(exchange?.verifierMatched).toBe(true);
  }, 20000);

  test("a confidential client: client_secret_basic in the token exchange, PKCE always", async () => {
    const harness = flowHarness();
    registerClient(harness, "salesforce", "conf-secret", "s3cr3t");
    tokenExchanges.length = 0;

    const { authorizationUrl } = await harness.flow.startForCredential(
      "project-1",
      "salesforce",
      undefined,
    );
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await harness.flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome).toEqual({ kind: "authorized", name: "salesforce" });
    // The confidential client authenticated with HTTP Basic (id:secret), and PKCE was still verified.
    const exchange = tokenExchanges.at(-1);
    expect(exchange?.clientAuth).toBe("basic");
    expect(exchange?.clientId).toBe("conf-secret");
    expect(exchange?.clientSecret).toBe("s3cr3t");
    expect(exchange?.verifierMatched).toBe(true);
  }, 20000);

  test("a configured login for an unregistered client is a 400 (no client registered)", async () => {
    const { flow } = flowHarness();
    await expect(flow.startForCredential("project-1", "unknown", undefined)).rejects.toThrowError(
      BadRequestError,
    );
  });

  test("registered extra parameters appear on the authorize URL (the Google refresh-token case)", async () => {
    const harness = flowHarness();
    // Google issues a refresh token only when the authorize request carries these two — pure registry
    // DATA on the row, appended verbatim after the standard parameters.
    registerClient(harness, "google", "conf-google", null, {
      access_type: "offline",
      prompt: "consent",
    });

    const { authorizationUrl } = await harness.flow.startForCredential(
      "project-1",
      "google",
      undefined,
    );

    const url = new URL(authorizationUrl);
    expect(url.searchParams.get("access_type")).toBe("offline");
    expect(url.searchParams.get("prompt")).toBe("consent");
    // The standard parameters are all still present alongside them.
    expect(url.searchParams.get("client_id")).toBe("conf-google");
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    // The full flow still completes with the extra parameters on the URL.
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await harness.flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });
    expect(outcome).toEqual({ kind: "authorized", name: "google" });
  }, 20000);

  test("an extra parameter colliding with a standard one is ignored — the standard value wins", async () => {
    const harness = flowHarness();
    // A row must not be able to override the flow's security material (the callback capability, the PKCE
    // pair) or its protocol identity — each colliding entry is dropped in favor of the standard value.
    registerClient(harness, "hostile", "conf-real", null, {
      redirect_uri: "https://evil.example.test/steal",
      client_id: "conf-forged",
      response_type: "token",
      state: "forged-state",
      code_challenge_method: "plain",
      scope: "everything",
      access_type: "offline",
    });

    const { authorizationUrl } = await harness.flow.startForCredential(
      "project-1",
      "hostile",
      undefined,
    );

    const url = new URL(authorizationUrl);
    expect(url.searchParams.get("redirect_uri")).toBe(CALLBACK_URL);
    expect(url.searchParams.get("client_id")).toBe("conf-real");
    expect(url.searchParams.get("response_type")).toBe("code");
    expect(url.searchParams.get("state")).not.toBe("forged-state");
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("scope")).toBe("read");
    // No duplicate keys smuggled in beside the standard values either.
    expect(url.searchParams.getAll("redirect_uri")).toHaveLength(1);
    expect(url.searchParams.getAll("client_id")).toHaveLength(1);
    // The non-colliding extra still applies.
    expect(url.searchParams.get("access_type")).toBe("offline");
  });

  test("no registered extra parameters leaves the authorize URL with exactly the standard set", async () => {
    const harness = flowHarness();
    registerClient(harness, "plain", "conf-plain", null);

    const { authorizationUrl } = await harness.flow.startForCredential(
      "project-1",
      "plain",
      undefined,
    );

    const keys = [...new URL(authorizationUrl).searchParams.keys()].sort();
    expect(keys).toEqual([
      "client_id",
      "code_challenge",
      "code_challenge_method",
      "redirect_uri",
      "response_type",
      "scope",
      "state",
    ]);
  });
});

// ─── proactive login (startForCredential) ─────────────────────────────────────────────────────────────

describe("proactive login", () => {
  test("with no waiting escalation the flow is a pure deposit (zero answers)", async () => {
    const { flow, deposits, answered } = flowHarness();

    const { authorizationUrl } = await flow.startForCredential("project-1", "github", mcpServerUrl);
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome).toEqual({ kind: "authorized", name: "github" });
    expect(deposits).toHaveLength(1);
    expect(deposits[0]?.name).toBe("github");
    expect(answered).toHaveLength(0);
  }, 20000);

  test("a completed proactive login answers EVERY escalation that opened on the name meanwhile", async () => {
    const { flow, openEscalations, answered } = flowHarness();

    // Start a proactive login BEFORE any run needs the credential…
    const { authorizationUrl } = await flow.startForCredential("project-1", "github", mcpServerUrl);
    // …and two runs park on the same name while the human is authenticating.
    openEscalations.push(
      mcpAuthorizeEscalation("esc-run-a", mcpServerUrl, "github"),
      mcpAuthorizeEscalation("esc-run-b", mcpServerUrl, "github"),
      mcpAuthorizeEscalation("esc-other", mcpServerUrl, "gitlab"),
    );
    const { code, state } = authorizeAtIdentityProvider(authorizationUrl);
    const outcome = await flow.handleCallback({
      code,
      state,
      error: undefined,
      errorDescription: undefined,
    });

    expect(outcome.kind).toBe("authorized");
    // Every open ask on the name is answered by the single completion; the other name is left open.
    expect(answered.sort()).toEqual(["esc-run-a", "esc-run-b"]);
  }, 20000);

  test("restarting a login for the same (project, name) supersedes the previous flow", async () => {
    const { flow, deposits } = flowHarness();

    const first = await flow.startForCredential("project-1", "github", mcpServerUrl);
    const firstRedirect = authorizeAtIdentityProvider(first.authorizationUrl);
    const second = await flow.startForCredential("project-1", "github", mcpServerUrl);
    const secondRedirect = authorizeAtIdentityProvider(second.authorizationUrl);

    // The first state died when the second flow was minted for the same (project, name).
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

    const fresh = await flow.handleCallback({
      code: secondRedirect.code,
      state: secondRedirect.state,
      error: undefined,
      errorDescription: undefined,
    });
    expect(fresh.kind).toBe("authorized");
    expect(deposits).toHaveLength(1);
  }, 20000);

  test("a login for one name does NOT supersede a concurrent login for a different name", async () => {
    const { flow, deposits } = flowHarness();

    const github = await flow.startForCredential("project-1", "github", mcpServerUrl);
    const gitlab = await flow.startForCredential("project-1", "gitlab", mcpServerUrl);
    const githubRedirect = authorizeAtIdentityProvider(github.authorizationUrl);
    const gitlabRedirect = authorizeAtIdentityProvider(gitlab.authorizationUrl);

    // Both flows are independently redeemable — the per-(project, name) key isolates them.
    const first = await flow.handleCallback({
      code: githubRedirect.code,
      state: githubRedirect.state,
      error: undefined,
      errorDescription: undefined,
    });
    const second = await flow.handleCallback({
      code: gitlabRedirect.code,
      state: gitlabRedirect.state,
      error: undefined,
      errorDescription: undefined,
    });
    expect(first).toEqual({ kind: "authorized", name: "github" });
    expect(second).toEqual({ kind: "authorized", name: "gitlab" });
    expect(deposits.map((deposit) => deposit.name).sort()).toEqual(["github", "gitlab"]);
  }, 20000);
});
